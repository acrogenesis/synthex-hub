defmodule Server.Jobs.AnalyzeObanJobs do
  @moduledoc """
  Periodic `ANALYZE oban_jobs` to keep the planner's row estimates
  honest for `Server.Queue.claim_chunk/1`.

  ## Why this exists

  `claim_chunk/1` computes a per-batch fair-share window over the
  `state = 'available' AND queue = 'chunks'` rows, then self-joins
  `oban_jobs` to take `FOR UPDATE` on the winning row (a window
  function and `FOR UPDATE` can't live in the same query level, so
  the self-join is structural). The planner's choice between
  materializing the windowed subquery ONCE vs. re-evaluating it per
  outer row hinges entirely on its estimate of how many `available`
  chunks exist.

  That estimate goes badly stale: the table is dominated by a huge,
  slow-moving population of `cancelled`/`completed` rows, while the
  `available` count swings from ~0 to 80k+ whenever a master
  dispatches a large wave (e.g. Ant's collect_states). Autoanalyze
  triggers on a fraction of TOTAL row churn, so it lags these swings
  by far too long. When the planner thinks there's 1 available row
  but there are 80k, it picks a nested loop that re-runs the window
  per row — O(N²) — and `claim_chunk` effectively hangs, starving
  the whole swarm even though chunks are plentiful.

  A cheap (~1–2s) targeted ANALYZE every few minutes keeps the
  estimate fresh enough that the planner always materializes the
  subquery once. This is belt-and-suspenders alongside Postgres
  autoanalyze, sized for our bursty available-count pattern.
  """
  use Oban.Worker, queue: :system, max_attempts: 1

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    Server.Repo.query!("ANALYZE oban_jobs", [], timeout: 120_000)
    :ok
  rescue
    err ->
      # Never let a stats-refresh failure crash the cron pipeline;
      # a missed cycle just means the next one catches up.
      Logger.warning("[AnalyzeObanJobs] ANALYZE failed: #{Exception.message(err)}")
      :ok
  end
end
