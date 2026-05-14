defmodule Server.Experiments do
  @moduledoc """
  Data-access layer for `Server.Experiment` rows.

  Everything the master-loop Oban workers and the public landing page
  need to read or write about an experiment lives here. Pulled out
  into its own module to keep `Server.Queue` focused on the
  batch/chunk lifecycle.

  Two consumers:

    * The `Server.Workers.Experiment*` Oban workers, which checkpoint
      after every accepted bit via `update_state/2` and `mark_*` —
      a crashed/retried worker resumes from the persisted state.

    * Read APIs: the router (POST submission, GET status) and the
      landing page (rolling summary, incidents banner).
  """

  import Ecto.Query
  alias Server.{AggregateBroker, Experiment, PolicyVersion, Repo, SystemEvent}

  # Heartbeat dead → master Oban job has crashed/disappeared.
  # Surfaces as `stalled` on the dashboard.
  @stalled_threshold_seconds 300

  # Heartbeat fresh AND there's an in-flight wave AND no chunks have
  # completed in this long → workers stopped pulling work even though
  # the master wants more. Surfaces as `idle` on the dashboard, the
  # honest "something is wrong, please look" signal. Distinct from
  # `slow` (work is flowing, just very slowly relative to bit size).
  @idle_threshold_seconds 5 * 60

  # First few minutes after a wave is dispatched there will legitimately
  # be no chunk completions yet — workers need to fetch their first
  # chunk over HTTP, finish the rollouts, and post the result.
  # Don't flag `idle` until we're past this grace period.
  @boot_grace_seconds 5 * 60

  # Heartbeat fresh AND chunks ARE flowing but the swarm is so far
  # below the workload's bit granularity that no bit will be accepted
  # for ages. Surfaces as `slow` on the dashboard with an ETA, not
  # as a red alarm. Replaces the older `no_progress` flag which fired
  # purely on wall-clock and was wildly misleading on Ant-scale runs
  # where a single bit legitimately takes days to complete.
  @slow_after_seconds 60 * 60

  # ── Submission ──────────────────────────────────────────────

  @doc """
  Create a new experiment and enqueue its bootstrap job. Rejects if
  there's already a pending/running row for the same env (one
  experiment at a time per env — operators can launch a second
  Ant run only after the first finishes or fails). The unique
  index `experiments_one_active_per_env` enforces this at the
  database level so a racing submit can't slip through.

  Returns `{:ok, experiment}` or `{:error, reason}`.
  """
  def create(attrs, opts \\ []) do
    submitter = Keyword.get(opts, :submitter)

    attrs = normalize_create_attrs(attrs, submitter)

    case validate_create_attrs(attrs) do
      :ok ->
        Repo.transaction(fn ->
          changeset = Experiment.changeset(%Experiment{}, attrs)

          case Repo.insert(changeset) do
            {:ok, experiment} ->
              case Server.Workers.ExperimentBootstrap.new(%{"experiment_id" => experiment.id})
                   |> Oban.insert() do
                {:ok, _job} ->
                  log_event!("info", "master",
                    "experiment submitted: #{experiment.env_name} (#{experiment.id})",
                    env_name: experiment.env_name,
                    experiment_id: experiment.id
                  )

                  experiment

                {:error, reason} ->
                  Repo.rollback({:enqueue_failed, reason})
              end

            {:error, %Ecto.Changeset{errors: errors}} ->
              if active_conflict?(errors) do
                Repo.rollback(:already_running)
              else
                Repo.rollback({:invalid, errors})
              end
          end
        end)
        |> case do
          {:ok, experiment} -> {:ok, experiment}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Did the insert fail because of the partial unique index on
  # active (pending/running) experiments per env? Errors come back
  # as `{message, opts}` tuples from `unique_constraint/3`.
  defp active_conflict?(errors) do
    case Keyword.get(errors, :env_name) do
      {_msg, opts} ->
        Keyword.get(opts, :constraint_name) == "experiments_one_active_per_env" or
          Keyword.get(opts, :constraint) == :unique

      _ ->
        false
    end
  end

  defp normalize_create_attrs(attrs, submitter) do
    %{
      "env_key" => to_string(Map.get(attrs, "env_key") || Map.get(attrs, :env_key) || ""),
      "env_name" => to_string(Map.get(attrs, "env_name") || Map.get(attrs, :env_name) || ""),
      "config" => Map.get(attrs, "config") || Map.get(attrs, :config) || %{},
      "submitter" => submitter,
      "status" => "pending"
    }
  end

  defp validate_create_attrs(%{"env_key" => env_key, "env_name" => env_name})
       when env_key == "" or env_name == "" do
    {:error, :missing_env}
  end

  defp validate_create_attrs(%{"env_key" => env_key}) do
    # Round-trip via Atom.to_string/1 rather than to_existing_atom —
    # safer on a cold BEAM where Synthex.Gym.Mujoco's `:ant` etc.
    # haven't been added to the atom table yet by any caller.
    Code.ensure_loaded(Synthex.Gym.Mujoco)

    Synthex.Gym.Mujoco.known_envs()
    |> Enum.find(fn atom -> Atom.to_string(atom) == env_key end)
    |> case do
      nil -> {:error, {:unknown_env, env_key}}
      _atom -> :ok
    end
  end

  # ── CRUD ────────────────────────────────────────────────────

  @doc "Fetch one experiment by UUID."
  def get(id) when is_binary(id) do
    case Repo.get(Experiment, id) do
      nil -> {:error, :not_found}
      exp -> {:ok, exp}
    end
  end

  @doc """
  Update an experiment's state. Used by workers to checkpoint
  after every accepted bit and after every iter advance.
  """
  def update_state(%Experiment{} = exp, attrs) do
    exp
    |> Experiment.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Bump the cached `best_reward`/`accepted_count` atomically. Called
  after each accepted bit. Avoids a read-modify-write race with
  concurrent reads from the public dashboard.
  """
  def record_acceptance(%Experiment{id: id}, reward) do
    sql = """
    UPDATE experiments
    SET best_reward = GREATEST(COALESCE(best_reward, $1::float8), $1::float8),
        accepted_count = accepted_count + 1,
        updated_at = now()
    WHERE id = $2
    """

    Repo.query!(sql, [reward * 1.0, Ecto.UUID.dump!(id)])
    :ok
  end

  @doc """
  Transition an experiment to "running" with baseline reward set.
  Called by `ExperimentBootstrap` once initial validation succeeds.
  """
  def mark_running(%Experiment{} = exp, baseline_reward) do
    update_state(exp, %{
      "status" => "running",
      "started_at" => exp.started_at || DateTime.utc_now(),
      "baseline_reward" => baseline_reward
    })
  end

  @doc "Transition an experiment to completed."
  def mark_completed(%Experiment{} = exp) do
    update_state(exp, %{
      "status" => "completed",
      "completed_at" => DateTime.utc_now()
    })
  end

  @doc "Transition an experiment to failed with an error message."
  def mark_failed(%Experiment{} = exp, error_message) do
    update_state(exp, %{
      "status" => "failed",
      "completed_at" => DateTime.utc_now(),
      "error" => error_message
    })
  end

  @doc "Transition an experiment to cancelled (operator-initiated)."
  def mark_cancelled(%Experiment{} = exp, reason \\ nil) do
    update_state(exp, %{
      "status" => "cancelled",
      "completed_at" => DateTime.utc_now(),
      "error" => reason
    })
  end

  @doc "List experiments newest first."
  def list(limit \\ 50) do
    from(e in Experiment,
      order_by: [desc: e.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  # ── Public dashboard ────────────────────────────────────────

  @doc """
  Per-environment summary for the public landing page.

  Reads directly from the `experiments` table — no more
  reverse-engineering experiment shape from per-bit Batch rows
  (which always lagged reality and routinely showed the wrong
  liveness state). Each row carries the canonical CEGAR
  progress, current best reward, and health.

  Returns `[%{env_name, status, active, latest, ...}, ...]`.
  """
  def summary do
    experiments = Repo.all(from e in Experiment, order_by: [desc: e.inserted_at])

    by_env = Enum.group_by(experiments, & &1.env_name)

    Enum.map(by_env, fn {env_name, exps} ->
      active = Enum.find(exps, &(&1.status in ["pending", "running"]))
      completed = Enum.filter(exps, &(&1.status == "completed"))
      latest_completed = List.first(completed)

      best_completed =
        completed
        |> Enum.map(& &1.best_reward)
        |> Enum.reject(&is_nil/1)
        |> case do
          [] -> nil
          xs -> Enum.max(xs)
        end

      %{
        env_name: env_name,
        status: cond do
          active -> active.status
          latest_completed -> "completed"
          true -> "history"
        end,
        active: render_active(active),
        latest: render_latest(latest_completed),
        best_reward: best_completed,
        completed_count: length(completed),
        total_count: length(exps)
      }
    end)
    |> Enum.sort_by(& &1.env_name)
  end

  defp render_active(nil), do: nil

  defp render_active(%Experiment{} = exp) do
    config = exp.config || %{}
    max_iters = get_int(config, "max_iters", 5)
    cegar_rounds = get_int(config, "cegar_rounds", 3)
    bits_per_dim = get_int(config, "bits_per_dim", 3)

    n_bits =
      try do
        env_atom = Server.Workers.ExperimentBootstrap.decode_env_key(exp.env_key)
        cfg = Synthex.Gym.Mujoco.env_config(env_atom)
        bits_per_dim * cfg.n_action_dims
      rescue
        _ -> nil
      end

    total_iters = cegar_rounds * max_iters
    done_iters = max(0, (exp.current_cegar_iter - 1) * max_iters + (exp.current_iter - 1))
    progress = if total_iters > 0, do: done_iters / total_iters, else: 0.0

    flow = AggregateBroker.experiment_flow(exp.id)
    {health, polled_ago} = compute_health(exp, flow)

    %{
      experiment_id: exp.id,
      status: exp.status,
      cegar_iter: exp.current_cegar_iter,
      total_cegar_iters: cegar_rounds,
      iter: exp.current_iter,
      total_iters: max_iters,
      bits_done: length(exp.bit_progress || []),
      n_bits: n_bits,
      accepted_count: exp.accepted_count,
      best_reward: exp.best_reward,
      baseline_reward: exp.baseline_reward,
      progress: progress,
      started_at: exp.started_at || exp.inserted_at,
      elapsed_seconds: elapsed_seconds(exp.started_at || exp.inserted_at),
      health: health,
      heartbeat_seconds_ago: polled_ago,
      # Chunk-flow telemetry — the swarm's collective throughput on
      # this experiment, summed across in-flight bits. Surfaces on
      # the dashboard as "~N chunks/min · K pending · ETA D days"
      # so an operator can see at a glance whether `slow` reflects
      # an undersized swarm (workload >> capacity) or a real outage.
      chunks_per_min: flow && flow.chunks_per_min,
      chunks_done: flow && flow.chunks_done,
      chunks_total: flow && flow.chunks_total,
      chunks_pending: flow && flow.chunks_pending,
      n_active_bits: flow && flow.n_active_bits,
      eta_first_bit_seconds: eta_first_bit_seconds(flow),
      # Streaming CEGAR §Layer 3 surface: monotonically-increasing
      # commit counter + the last few commits so the dashboard can
      # show "v=12 — bit 3 +2.1 @ 14s ago" style live progress.
      policy_version: exp.policy_version || 0,
      latest_commits: render_commits(latest_commits(exp.id, 5))
    }
  end

  # Projected wall-clock time until the next bit is accepted, at the
  # current swarm throughput. Returns nil when we lack a reliable
  # rate (between waves; just after a commit; no in-flight batches).
  #
  # With Jacobi parallel-bit dispatch, all bits in a wave progress at
  # roughly equal rates because `claim_chunk` fair-shares between
  # batches; so first-commit time ≈ wave-completion time. That keeps
  # the projection simple: pending_chunks / chunks_per_min.
  defp eta_first_bit_seconds(nil), do: nil

  defp eta_first_bit_seconds(%{chunks_per_min: rate, chunks_pending: pending})
       when is_integer(rate) and rate > 0 and is_integer(pending) and pending > 0 do
    div(pending * 60, rate)
  end

  defp eta_first_bit_seconds(_), do: nil

  defp render_latest(nil), do: nil

  defp render_latest(%Experiment{} = exp) do
    delta =
      cond do
        is_number(exp.best_reward) and is_number(exp.baseline_reward) ->
          exp.best_reward - exp.baseline_reward

        true ->
          nil
      end

    %{
      experiment_id: exp.id,
      best_reward: exp.best_reward,
      baseline_reward: exp.baseline_reward,
      delta: delta,
      accepted_count: exp.accepted_count,
      completed_at: exp.completed_at
    }
  end

  # Liveness for an experiment, in four mutually-exclusive states:
  #
  #   * `stalled`  — the master Oban job hasn't checkpointed for
  #                  `@stalled_threshold_seconds`. The controller
  #                  itself has crashed/disappeared; Lifeline will
  #                  rescue it. Red.
  #
  #   * `idle`     — master heartbeat is fresh AND there's an
  #                  in-flight wave AND no chunks have completed in
  #                  the last `@idle_threshold_seconds`. The
  #                  controller is alive but workers stopped
  #                  pulling/finishing work — most often a worker
  #                  outage or a backed-up `chunks` queue. Orange.
  #
  #   * `slow`     — master alive, chunks ARE flowing, but the
  #                  experiment has been running for
  #                  `@slow_after_seconds` without accepting a bit.
  #                  Workload bigger than the swarm can crunch in a
  #                  reasonable time. Honest yellow signal, with an
  #                  ETA so the operator can decide whether to grow
  #                  the swarm or shrink the workload. NOT an error.
  #
  #   * `healthy`  — anything else: chunks moving, or bits being
  #                  committed at a reasonable cadence, or the run
  #                  is still inside its boot grace.
  #
  # The flow stats come from `Server.AggregateBroker` which refreshes
  # once per second; `nil` flow means the broker hasn't observed an
  # in-flight batch for this experiment yet (just-submitted or
  # between waves while collect_states/build_features runs).
  defp compute_health(%Experiment{status: "pending"} = exp, _flow) do
    age = elapsed_seconds(exp.inserted_at) || 0

    if age >= @stalled_threshold_seconds,
      do: {"idle", nil},
      else: {"healthy", nil}
  end

  defp compute_health(%Experiment{status: "running", updated_at: updated_at} = exp, flow)
       when not is_nil(updated_at) do
    secs = DateTime.diff(DateTime.utc_now(), updated_at, :second)
    elapsed = elapsed_seconds(exp.started_at || exp.inserted_at) || 0
    bits_done = length(exp.bit_progress || [])

    health =
      cond do
        secs > @stalled_threshold_seconds ->
          "stalled"

        elapsed > @boot_grace_seconds and chunks_stuck?(flow) ->
          "idle"

        bits_done == 0 and elapsed > @slow_after_seconds and chunks_flowing?(flow) ->
          "slow"

        true ->
          "healthy"
      end

    {health, secs}
  end

  defp compute_health(_exp, _flow), do: {"unknown", nil}

  # Is the swarm actively making chunk-level progress right now?
  # Two signals must agree: (a) AggregateBroker has observed >0
  # chunks/min over the rolling window, OR (b) `last_result_at`
  # bumped within the idle threshold. Either is enough — the rolling
  # rate can read 0 transiently between chunk arrivals on a sparse
  # swarm, and `last_result_at` covers that case directly.
  defp chunks_flowing?(nil), do: false

  defp chunks_flowing?(%{chunks_per_min: rate, last_progress_at: last})
       when is_integer(rate) and rate > 0,
       do: not stale_progress?(last)

  defp chunks_flowing?(%{last_progress_at: last}), do: not stale_progress?(last)

  # No pending chunks → not "stuck", just between waves.
  # Pending chunks but no recent completions → genuinely stuck.
  defp chunks_stuck?(nil), do: false
  defp chunks_stuck?(%{chunks_pending: pending}) when not is_integer(pending) or pending <= 0,
    do: false

  defp chunks_stuck?(%{last_progress_at: nil, chunks_pending: pending}) when pending > 0, do: true

  defp chunks_stuck?(%{last_progress_at: last}), do: stale_progress?(last)

  defp stale_progress?(nil), do: true

  defp stale_progress?(%DateTime{} = last) do
    DateTime.diff(DateTime.utc_now(), last, :second) > @idle_threshold_seconds
  end

  defp elapsed_seconds(nil), do: nil
  defp elapsed_seconds(%DateTime{} = dt), do: DateTime.diff(DateTime.utc_now(), dt, :second)

  defp get_int(map, key, default) when is_map(map) do
    case Map.get(map, key, default) do
      n when is_integer(n) -> n
      n when is_float(n) -> trunc(n)
      _ -> default
    end
  end

  # ── System events ──────────────────────────────────────────

  @doc """
  Insert a system_event row. Raises on changeset failure — incidents
  must never be silently dropped. Returns the inserted event.
  """
  def log_event!(level, source, message, opts \\ []) do
    attrs = %{
      "level" => level,
      "source" => source,
      "message" => message,
      "env_name" => Keyword.get(opts, :env_name),
      "experiment_id" => Keyword.get(opts, :experiment_id),
      "metadata" => Keyword.get(opts, :metadata, %{})
    }

    %SystemEvent{}
    |> SystemEvent.changeset(attrs)
    |> Repo.insert!()
  end

  @doc """
  Recent system events for the public banner. Filters to
  `level in (warn, error)` over the last `hours` hours.
  """
  def recent_incidents(hours \\ 24, limit \\ 50) do
    cutoff = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    from(e in SystemEvent,
      where: e.level in ["warn", "error"] and e.inserted_at >= ^cutoff,
      order_by: [desc: e.inserted_at],
      limit: ^limit,
      select: %{
        id: e.id,
        level: e.level,
        source: e.source,
        message: e.message,
        env_name: e.env_name,
        experiment_id: e.experiment_id,
        inserted_at: e.inserted_at
      }
    )
    |> Repo.all()
  end

  # ── Streaming CEGAR commit log ────────────────────────────────

  @doc """
  Most-recent commit-gate accepts for an experiment, newest first.
  Used by:

    * `render_active/1` — to surface the last few commits on the
      dashboard card.
    * `Server.AggregateBroker` — to fan-out commit events via SSE.

  The `predicates` blob is NOT returned (it's the full policy state,
  too heavy for a frequent SSE tick). Use `Server.Experiment.get/1`
  + `policy_versions` joins for full audit replay.
  """
  def latest_commits(experiment_id, limit \\ 5) do
    from(v in PolicyVersion,
      where: v.experiment_id == ^experiment_id,
      order_by: [desc: v.version],
      limit: ^limit,
      select: %{
        version: v.version,
        bit_idx: v.bit_idx,
        prev_reward: v.prev_reward,
        new_reward: v.new_reward,
        worker_id: v.worker_id,
        committed_at: v.inserted_at,
        metadata: v.metadata
      }
    )
    |> Repo.all()
  end

  defp render_commits(rows) do
    Enum.map(rows, fn row ->
      delta =
        cond do
          is_number(row.new_reward) and is_number(row.prev_reward) ->
            row.new_reward - row.prev_reward

          true ->
            nil
        end

      %{
        version: row.version,
        bit_idx: row.bit_idx,
        prev_reward: row.prev_reward,
        new_reward: row.new_reward,
        delta: delta,
        committed_at: row.committed_at,
        committed_seconds_ago: elapsed_seconds(row.committed_at),
        worker_id: row.worker_id,
        cegar_iter: Map.get(row.metadata || %{}, "cegar_iter"),
        wave: Map.get(row.metadata || %{}, "wave")
      }
    end)
  end
end
