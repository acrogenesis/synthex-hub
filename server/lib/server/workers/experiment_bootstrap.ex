defmodule Server.Workers.ExperimentBootstrap do
  @moduledoc """
  First job in an experiment's lifecycle. Runs exactly once.

  Responsibilities:

    1. Read the experiment row.
    2. Initialize the predicate vector (`List.duplicate(:falsep, n_bits)`).
    3. Compute the baseline reward via a validation pass through
       `Synthex.Hub.Client` pointing at localhost.
    4. Persist `predicates`, `baseline_reward`, `current_cegar_iter=1`,
       `current_iter=1`, and flip `status → running`.
    5. Enqueue the first `ExperimentCegarIter` job.

  If steps 1-4 succeed but step 5 fails, Oban retries with the row
  already initialized — the next attempt re-enters this worker,
  sees `status == "running"`, and just re-enqueues the iter job.
  That's safe because `ExperimentCegarIter` is itself idempotent
  on the experiment row.

  ## Why retries

  `Oban.Worker` with `max_attempts: 3` and exponential backoff. The
  scoring leg (`Synthex.Hub.Client`) is allowed to take hours, so the
  worker's own runtime is unbounded but cheap — almost all wall
  time is spent inside one HTTP poll loop.
  """

  use Oban.Worker, queue: :master, max_attempts: 3
  require Logger

  alias Server.{Experiments, Experiment}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"experiment_id" => id}}) do
    case Experiments.get(id) do
      {:error, :not_found} ->
        Logger.warning("[Bootstrap] experiment #{id} not found; discarding")
        {:discard, "experiment not found"}

      {:ok, %Experiment{status: status}} when status in ["completed", "failed", "cancelled"] ->
        Logger.info("[Bootstrap] experiment #{id} already #{status}; nothing to do")
        :ok

      {:ok, %Experiment{status: "running"} = exp} ->
        # Re-entry after a partial success in a previous attempt:
        # the row was initialized, but enqueueing the first iter
        # failed. Just enqueue and exit.
        Logger.info("[Bootstrap] experiment #{id} already running; (re-)enqueueing first iter")
        enqueue_first_iter(exp.id)

      {:ok, %Experiment{status: "pending"} = exp} ->
        bootstrap(exp)
    end
  end

  defp bootstrap(%Experiment{} = exp) do
    Logger.info("[Bootstrap] starting #{exp.env_name} (#{exp.id})")

    env_key = decode_env_key(exp.env_key)
    ctx = build_context(env_key, exp.config, exp.id)

    initial_preds = Synthex.Gym.Mujoco.initial_predicates(ctx)
    val_seeds = Synthex.Gym.Mujoco.validation_seeds()

    # Baseline = validation reward of the falsep predicates. Establishes
    # the starting point against which every accepted bit's improvement
    # is measured. Surfaced on the landing page as the dashed line on
    # the reward sparkline.
    {total_reward, _survived} = Synthex.Gym.Mujoco.validate(initial_preds, val_seeds, ctx)
    baseline_avg = total_reward / length(val_seeds)

    Logger.info("[Bootstrap] #{exp.env_name} baseline = #{Float.round(baseline_avg, 2)}/ep")

    {:ok, _exp} =
      Experiments.update_state(exp, %{
        "status" => "running",
        "started_at" => DateTime.utc_now(),
        "predicates" => %{"preds" => Enum.map(initial_preds, &Synthex.Core.PrettyPrint.to_json_term/1)},
        "current_cegar_iter" => 1,
        "current_iter" => 1,
        "bit_shuffle" => [],
        "bit_progress" => [],
        "baseline_reward" => baseline_avg,
        "best_reward" => baseline_avg
      })

    Experiments.log_event!(
      "info",
      "master",
      "bootstrap complete: #{exp.env_name} baseline=#{Float.round(baseline_avg, 2)}",
      env_name: exp.env_name,
      experiment_id: exp.id,
      metadata: %{"baseline_reward" => baseline_avg}
    )

    enqueue_first_iter(exp.id)
  end

  defp enqueue_first_iter(experiment_id) do
    case Server.Workers.ExperimentCegarIter.new(%{"experiment_id" => experiment_id})
         |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Helpers shared with ExperimentCegarIter ─────────────────

  @doc """
  Build a Synthex.Gym.Mujoco context from an experiment config,
  pointing the scorer at the local hub. The scorer goes through
  `Synthex.Hub.Scorer` so all of `collect_states`/`score_bit`
  still hit the same Postgres-backed batch queue — we're just
  the master, not a special-snowflake in-process driver.

  `experiment_id` is included in the batch-name prefix so workers
  and operators can correlate Batch rows back to their experiment.
  """
  def build_context(env_key, config, experiment_id) when is_atom(env_key) do
    opts = config_to_opts(config)
    scorer = build_local_scorer(env_key, experiment_id, config)
    Synthex.Gym.Mujoco.init_context(env_key, Keyword.put(opts, :scorer, scorer))
  end

  defp build_local_scorer(env_key, experiment_id, config) do
    base_url = Application.get_env(:server, :local_hub_url, "http://localhost:4000/api")
    token = Application.get_env(:server, :api_token)

    chunk_size = get_int(config, "chunk_size", 100)
    collect_chunk_size = get_int(config, "collect_states_chunk_size", 4)
    state_stride = get_int(config, "state_stride", 10)
    poll_interval_ms = get_int(config, "poll_interval_ms", 5_000)

    Synthex.Hub.Scorer.new(
      env_key: env_key,
      url: base_url,
      token: token,
      chunk_size: chunk_size,
      collect_states_chunk_size: collect_chunk_size,
      state_stride: state_stride,
      poll_interval_ms: poll_interval_ms,
      batch_name_prefix: "exp-#{experiment_id_short(experiment_id)}",
      experiment_id: experiment_id
    )
  end

  defp experiment_id_short(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp experiment_id_short(_), do: "unknown"

  defp config_to_opts(%{} = config) do
    [
      bits_per_dim: get_int(config, "bits_per_dim", 3),
      depth: get_int(config, "depth", 1),
      max_coeff: get_int(config, "max_coeff", 5),
      tridiag_max_coeff: get_int(config, "tridiag_max_coeff", 2),
      tridiag_dims: tridiag_range(Map.get(config, "tridiag_dims")),
      n_episodes: get_int(config, "n_episodes", 30),
      top_k: get_int(config, "top_k", 20),
      max_iters: get_int(config, "max_iters", 5),
      cegar_rounds: get_int(config, "cegar_rounds", 3),
      max_steps: get_int(config, "max_steps", 1000),
      feature_types: feature_types(Map.get(config, "feature_types"))
    ]
  end

  defp tridiag_range(nil), do: nil
  defp tridiag_range([lo, hi]) when is_integer(lo) and is_integer(hi), do: lo..hi
  defp tridiag_range(%{"lo" => lo, "hi" => hi}), do: lo..hi
  defp tridiag_range(_), do: nil

  defp feature_types(nil), do: nil

  # Feature class names are a closed set; whitelist them so we don't
  # depend on Synthex.Gym.Oracle's atoms being in the BEAM atom
  # table when an Oban job first runs.
  @feature_atoms %{
    "axis" => :axis,
    "diag" => :diag,
    "sq_diag" => :sq_diag,
    "prod" => :prod,
    "tridiag" => :tridiag
  }

  defp feature_types(list) when is_list(list) do
    Enum.map(list, fn
      s when is_binary(s) ->
        Map.get(@feature_atoms, s) ||
          raise ArgumentError, "unknown feature type: #{inspect(s)}"

      a when is_atom(a) ->
        a
    end)
  end

  defp get_int(map, key, default) do
    case Map.get(map, key, default) do
      n when is_integer(n) -> n
      n when is_float(n) -> trunc(n)
      _ -> default
    end
  end

  @doc """
  Atom-safe env_key decoder. We round-trip every atom in
  `Synthex.Gym.Mujoco.known_envs/0` through `Atom.to_string/1`
  and pick the match — avoiding `String.to_existing_atom/1`,
  which races with module loading on the very first Oban job
  after a release boot.
  """
  def decode_env_key(env_key) when is_binary(env_key) do
    Code.ensure_loaded(Synthex.Gym.Mujoco)

    Enum.find(Synthex.Gym.Mujoco.known_envs(), fn atom ->
      Atom.to_string(atom) == env_key
    end) || raise ArgumentError, "unknown env_key: #{inspect(env_key)}"
  end
end
