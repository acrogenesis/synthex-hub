defmodule Server.CommitGate do
  @moduledoc """
  The atomic commit gate for the versioned streaming-CEGAR controller
  (`docs/streaming-cegar.md` §Layer 3 / "Step 1" of the deployment
  plan).

  This module is the **only** path that mutates an experiment's
  global policy. Every accepted improvement goes through
  `attempt_commit/1`. The gate enforces three invariants atomically:

    1. **Version-fresh evaluation**: the candidate must have been
       evaluated against the predicates of the current
       `policy_version`. If a concurrent commit bumped the version
       between dispatch and result, the result is *stale* and
       silently discarded.

    2. **Monotone policy improvement**: the candidate's mean reward
       must exceed the experiment's running best
       (`exp.best_reward`) by at least `acceptance_epsilon`. Under
       version-reject (1), the candidate was evaluated against the
       *current* policy's seeds, so this comparison is on the same
       seed set as the running best — strict policy-level
       monotonicity follows by construction. We do not consult
       `best_reward_per_bit` for acceptance; per-bit best is a
       passive aggregate updated on commit for the dashboard.

    3. **Atomic bump + audit**: on success the predicates,
       `policy_version`, `best_reward`, `best_reward_per_bit`, and
       `accepted_count` are updated, and a `policy_versions` row is
       inserted, in a single transaction. Either everything commits
       or nothing does — the audit log is always in lockstep with
       the experiment row.

  ## Why this design

  CSHRLSynthesis §10 (`refine-commutes`) tells us observation order
  is irrelevant to the version space; HybridSynthesis §11.1 tells us
  bits are independent 2-action subproblems. Together: a streaming
  swarm submitting `(bit, candidate, evaluated_at_version)` tuples
  in any order, with arbitrary duplication, converges to the same
  version space as a serial optimizer **provided** the commit gate
  validates evaluations against the version they were produced for.
  Option (c) from the design doc — "version-reject" — discards stale
  evaluations with zero side effect, which is the simplest correct
  realization.

  The `FOR UPDATE` row lock makes the commit sequence serializable
  per experiment: two concurrent successful commits for the same
  bit can't both bump the version; one wins, the other re-reads and
  becomes stale.
  """

  import Ecto.Query

  alias Server.{Experiment, PolicyVersion, Repo}

  @typedoc """
  Reasons the gate can reject a commit. None are errors — they're
  expected outcomes the controller handles routinely.
  """
  @type rejection ::
          :stale
          | :no_improvement
          | :experiment_not_running

  @typedoc """
  A successful commit returns the new version and the bumped
  experiment so the caller can advance its in-memory baseline
  without re-reading.
  """
  @type commit_ok :: {:committed, pos_integer(), Experiment.t()}

  @doc """
  Attempt to commit a single bit's improvement.

  ## Arguments (keyword list)

    * `:experiment_id`       — the experiment receiving the commit.
    * `:bit_idx`             — which bit slot the candidate replaces.
    * `:candidate_term`      — the predicate, in `PrettyPrint.to_json_term/1`
                               form (already serialized).
    * `:reward`              — the candidate's mean reward as measured
                               against `evaluated_at_version`'s
                               predicates.
    * `:evaluated_at_version` — the `policy_version` the worker saw
                               when it produced this candidate. The
                               gate compares against the current
                               version under `FOR UPDATE`.
    * `:acceptance_epsilon`  — optional. Minimum margin by which the
                               candidate must beat the experiment's
                               running best reward (default `0.0`)
                               to count as strict monotone progress.
                               Set higher to filter rollout noise.
    * `:worker_id`           — optional. Foreign key into `workers`
                               recorded on the audit row.
    * `:metadata`            — optional. Forensic blob stored in the
                               audit row; the gate doesn't read it.

  ## Returns

    * `{:committed, new_version, %Experiment{}}` — predicates updated,
      version bumped, audit row inserted.
    * `{:rejected, :stale}` — evaluated-at version is older than the
      current. The result is silently discarded.
    * `{:rejected, :no_improvement}` — reward did not exceed the
      current best-for-bit by `acceptance_epsilon`.
    * `{:rejected, :experiment_not_running}` — the experiment moved
      to `completed`/`failed`/`cancelled` while the candidate was in
      flight. The controller will treat this as a terminal signal.
  """
  @spec attempt_commit(keyword()) ::
          {:committed, pos_integer(), Experiment.t()}
          | {:rejected, rejection()}
          | {:error, term()}
  def attempt_commit(opts) do
    experiment_id = Keyword.fetch!(opts, :experiment_id)
    bit_idx = Keyword.fetch!(opts, :bit_idx)
    candidate_term = Keyword.fetch!(opts, :candidate_term)
    reward = Keyword.fetch!(opts, :reward)
    evaluated_at_version = Keyword.fetch!(opts, :evaluated_at_version)
    epsilon = Keyword.get(opts, :acceptance_epsilon, 0.0)
    worker_id = Keyword.get(opts, :worker_id)
    metadata = Keyword.get(opts, :metadata, %{})

    Repo.transaction(fn ->
      case lock_experiment(experiment_id) do
        nil ->
          Repo.rollback({:rejected, :experiment_not_running})

        %Experiment{status: status} when status != "running" ->
          Repo.rollback({:rejected, :experiment_not_running})

        %Experiment{} = exp ->
          do_commit(exp,
            bit_idx: bit_idx,
            candidate_term: candidate_term,
            reward: reward,
            evaluated_at_version: evaluated_at_version,
            acceptance_epsilon: epsilon,
            worker_id: worker_id,
            metadata: metadata
          )
      end
    end)
    |> case do
      {:ok, {:committed, _, _} = ok} -> ok
      {:error, {:rejected, _} = rej} -> rej
      {:error, other} -> {:error, other}
    end
  end

  # ── Internals ───────────────────────────────────────────────────

  defp lock_experiment(experiment_id) do
    from(e in Experiment,
      where: e.id == ^experiment_id,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  defp do_commit(%Experiment{} = exp, opts) do
    bit_idx = Keyword.fetch!(opts, :bit_idx)
    candidate_term = Keyword.fetch!(opts, :candidate_term)
    reward = Keyword.fetch!(opts, :reward) * 1.0
    evaluated_at_version = Keyword.fetch!(opts, :evaluated_at_version)
    epsilon = Keyword.fetch!(opts, :acceptance_epsilon)
    worker_id = Keyword.get(opts, :worker_id)
    metadata = Keyword.fetch!(opts, :metadata)

    cond do
      evaluated_at_version != exp.policy_version ->
        Repo.rollback({:rejected, :stale})

      not improves_policy?(exp.best_reward, reward, epsilon) ->
        Repo.rollback({:rejected, :no_improvement})

      true ->
        new_version = exp.policy_version + 1
        new_predicates = replace_pred(exp.predicates, bit_idx, candidate_term)
        new_best_per_bit = put_best(exp.best_reward_per_bit, bit_idx, reward)
        prev_reward = exp.best_reward

        {:ok, updated} =
          exp
          |> Ecto.Changeset.change(
            predicates: new_predicates,
            policy_version: new_version,
            best_reward_per_bit: new_best_per_bit,
            best_reward: reward,
            accepted_count: exp.accepted_count + 1
          )
          |> Repo.update()

        {:ok, _audit} =
          %PolicyVersion{}
          |> PolicyVersion.changeset(%{
            "experiment_id" => exp.id,
            "version" => new_version,
            "predicates" => new_predicates,
            "bit_idx" => bit_idx,
            "prev_reward" => prev_reward,
            "new_reward" => reward,
            "worker_id" => worker_id,
            "metadata" => metadata
          })
          |> Repo.insert()

        {:committed, new_version, updated}
    end
  end

  # First commit on a fresh experiment (no recorded best yet): trivially
  # an improvement. Subsequent commits must beat the current best by
  # epsilon to qualify as strict monotone progress.
  defp improves_policy?(nil, _reward, _epsilon), do: true
  defp improves_policy?(best, reward, epsilon), do: reward > best + epsilon

  # Per-bit best is stored as a JSONB map keyed by stringified bit
  # index. Postgres returns string keys regardless of how we wrote
  # them. The gate writes this on commit as a passive aggregate; it
  # is *not* consulted for the acceptance decision.
  defp put_best(nil, bit_idx, reward),
    do: %{Integer.to_string(bit_idx) => reward}

  defp put_best(best_per_bit, bit_idx, reward) when is_map(best_per_bit) do
    Map.put(best_per_bit, Integer.to_string(bit_idx), reward)
  end

  # `predicates` is `%{"preds" => [encoded_term, ...]}`. Replacing
  # one slot preserves the encoding contract round-tripped through
  # `Synthex.Core.PrettyPrint.to_json_term/1` /
  # `from_json_term/1`.
  defp replace_pred(%{"preds" => list} = predicates, bit_idx, encoded)
       when is_list(list) and bit_idx < length(list) do
    Map.put(predicates, "preds", List.replace_at(list, bit_idx, encoded))
  end

  defp replace_pred(predicates, _bit_idx, _encoded) do
    raise ArgumentError,
          "Server.CommitGate.replace_pred/3: bit_idx out of range " <>
            "for #{inspect(predicates)}"
  end
end
