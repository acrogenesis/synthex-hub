defmodule Server.Jobs.OrphanReaper do
  @moduledoc """
  Safety-net Oban cron that catches anything the new Oban-master
  refactor missed:

    * `experiments` rows stuck `pending` or `running` whose last
      heartbeat (`updated_at`) is older than the orphan threshold AND
      have no live master job (queue=:master, state in available/
      scheduled/executing/retryable).

      → mark experiment `failed`, surface `error` system_event.

    * Active `batches` rows whose owning experiment is `failed`/
      `cancelled` AND whose chunks are still in `available`/`executing`.

      → cancel the outstanding Oban chunk jobs, mark batch
      `cancelled`, surface `warn` system_event.

  Runs every 2 minutes (configured in `config.exs`). Defense-in-depth:
  with masters running as supervised Oban jobs, this should usually
  be a no-op. When it isn't, the landing page banner immediately
  shows what was cleaned up.
  """

  use Oban.Worker, queue: :system, max_attempts: 3
  require Logger
  import Ecto.Query

  alias Server.{Experiment, Experiments, Repo, Batch}

  # An experiment with no progress for this long, AND no live Oban
  # master job, is considered abandoned. Generous: a legitimate
  # `score_bit` poll keeps `updated_at` fresh via every checkpointed
  # bit, so 30 minutes of zero accepted bits + zero polls is way
  # past suspicious.
  @stalled_seconds 30 * 60

  @impl Oban.Worker
  def perform(_job) do
    reap_stalled_experiments()
    cancel_orphan_batches()
    :ok
  end

  defp reap_stalled_experiments do
    cutoff = DateTime.add(DateTime.utc_now(), -@stalled_seconds, :second)

    stalled =
      from(e in Experiment,
        where: e.status in ["pending", "running"] and e.updated_at < ^cutoff
      )
      |> Repo.all()

    Enum.each(stalled, fn exp ->
      if alive?(exp.id) do
        :ok
      else
        Logger.warning(
          "[Reaper] stalled experiment #{exp.id} (#{exp.env_name}); last updated_at=#{exp.updated_at}; marking failed"
        )

        {:ok, _} =
          Experiments.mark_failed(
            exp,
            "no progress for #{div(@stalled_seconds, 60)}min and no live Oban master job"
          )

        Experiments.log_event!(
          "error",
          "reaper",
          "stalled experiment reaped: #{exp.env_name} " <>
            "(last update #{exp.updated_at}); marking failed",
          env_name: exp.env_name,
          experiment_id: exp.id,
          metadata: %{"last_updated_at" => exp.updated_at}
        )
      end
    end)
  end

  defp alive?(experiment_id) do
    from(j in Oban.Job,
      where:
        j.queue == "master" and
          j.state in ["available", "scheduled", "executing", "retryable"] and
          fragment("? ->> 'experiment_id' = ?", j.args, ^experiment_id)
    )
    |> Repo.exists?()
  end

  defp cancel_orphan_batches do
    # Batches whose owning experiment is no longer running but which
    # still have active Oban chunks. We don't delete anything; we
    # cancel the chunks (so workers won't pick them up) and mark
    # the batch row cancelled.
    orphans =
      from(b in Batch,
        join: e in Experiment,
        on: e.id == b.experiment_id,
        where: e.status in ["failed", "cancelled"] and b.status in ["pending", "running"],
        select: %{batch_id: b.id, env_name: b.env_name, experiment_status: e.status}
      )
      |> Repo.all()

    Enum.each(orphans, fn %{batch_id: batch_id, env_name: env_name, experiment_status: estatus} ->
      cancelled_jobs = cancel_chunks(batch_id)

      from(b in Batch, where: b.id == ^batch_id)
      |> Repo.update_all(
        set: [status: "cancelled", completed_at: DateTime.utc_now()]
      )

      Logger.warning(
        "[Reaper] cancelled #{cancelled_jobs} orphan chunks for batch #{batch_id} " <>
          "(experiment status=#{estatus})"
      )

      Experiments.log_event!(
        "warn",
        "reaper",
        "cancelled #{cancelled_jobs} orphan chunks for #{env_name} batch #{batch_id}",
        env_name: env_name,
        metadata: %{
          "batch_id" => batch_id,
          "experiment_status" => estatus,
          "cancelled_jobs" => cancelled_jobs
        }
      )
    end)
  end

  defp cancel_chunks(batch_id) do
    {count, _} =
      from(j in Oban.Job,
        where:
          j.queue == "chunks" and
            j.state in ["available", "scheduled", "executing", "retryable"] and
            fragment("? ->> 'batch_id' = ?", j.args, ^batch_id)
      )
      |> Repo.update_all(set: [state: "cancelled", cancelled_at: DateTime.utc_now()])

    count
  end
end
