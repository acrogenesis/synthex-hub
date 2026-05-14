defmodule Server.AggregateBroker do
  @moduledoc """
  Caches per-active-experiment streaming aggregates for the SSE
  feed at `/api/public-status/stream/aggregates`.

  Layer 1c of `docs/streaming-cegar.md`. Sister of
  `Server.MetricsBroker`: same lifecycle (one tick per second, ETS
  cache for read-concurrent SSE clients), but the cached payload is
  per-experiment rather than global.

  ## What's in a snapshot

      %{
        experiments: [
          %{
            experiment_id: "…",
            env_name: "Ant-v5",
            active_bit: %{
              batch_id: "…",
              target_bit: 5,
              cmd: "score_bit",
              n_results: 318,
              mean: -2980.1,
              stddev: 145.2,
              best_reward: -2820.4,
              baseline_reward: -3002.2,
              completed_chunks: 32,
              total_chunks: 60,
              progress: 0.533,
              results_per_min: 47        # rolling 60-s window
            }
          }
        ],
        ts: "2026-05-14T03:04:05Z"
      }

  ## Why a broker

  Each SSE client polling once/second would otherwise hit Postgres
  every second per viewer; one broker per node keeps DB load O(1)
  in viewer count. The rolling per-batch rate also has to live
  somewhere — we keep a `:queue` of `{ts_ms, n_results}` samples per
  in-flight batch, trimmed to the last `@window_secs` seconds.
  """

  use GenServer
  require Logger

  import Ecto.Query

  alias Server.{Batch, Experiment, Experiments, Repo}

  @table :server_aggregate_cache
  @refresh_ms 1_000
  @window_secs 60

  # ── public API ──────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Latest cached snapshot (nil before first refresh)."
  def latest do
    case :ets.whereis(@table) do
      :undefined ->
        nil

      _ ->
        case :ets.lookup(@table, :snapshot) do
          [{:snapshot, snap}] -> snap
          [] -> nil
        end
    end
  end

  # ── GenServer ───────────────────────────────────────────────────

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    Process.send_after(self(), :refresh, 100)
    {:ok, %{rings: %{}}}
  end

  @impl true
  def handle_info(:refresh, state) do
    new_state =
      try do
        do_refresh(state)
      rescue
        err ->
          Logger.warning(
            "[AggregateBroker] refresh failed: #{Exception.message(err)}\n" <>
              Exception.format_stacktrace(__STACKTRACE__)
          )

          state
      end

    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, new_state}
  end

  # ── internals ───────────────────────────────────────────────────

  defp do_refresh(state) do
    now_ms = System.system_time(:millisecond)
    rows = fetch_active_rows()

    {experiment_payloads, new_rings} =
      Enum.map_reduce(rows, state.rings, fn row, rings_acc ->
        {payload, updated_rings} = render_row(row, rings_acc, now_ms)
        {payload, updated_rings}
      end)

    # Drop rings for batches we no longer track — keeps memory bounded
    # to the active set, not all-time.
    active_batch_ids =
      rows
      |> Enum.map(& &1.batch_id)
      |> MapSet.new()

    pruned_rings =
      new_rings
      |> Enum.filter(fn {batch_id, _ring} -> MapSet.member?(active_batch_ids, batch_id) end)
      |> Map.new()

    snapshot = %{
      experiments: experiment_payloads,
      ts: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :ets.insert(@table, {:snapshot, snapshot})
    %{state | rings: pruned_rings}
  end

  # The in-flight batch for each running experiment is the most recent
  # not-yet-completed `score_bit` (or `collect_states`) row pointing
  # at that experiment. If there isn't one, the experiment doesn't
  # appear in the snapshot — the dashboard already shows experiment
  # status via the existing `/api/public-status/experiments` route.
  defp fetch_active_rows do
    sub =
      from(b in Batch,
        where: not is_nil(b.experiment_id) and b.status in ["pending", "running"],
        select: %{
          experiment_id: b.experiment_id,
          batch_id: b.id,
          inserted_at: b.inserted_at
        }
      )

    latest_per_exp =
      from(s in subquery(sub),
        group_by: s.experiment_id,
        select: %{experiment_id: s.experiment_id, latest_inserted_at: max(s.inserted_at)}
      )

    from(b in Batch,
      join: l in subquery(latest_per_exp),
      on:
        l.experiment_id == b.experiment_id and
          l.latest_inserted_at == b.inserted_at,
      join: e in Experiment,
      on: e.id == b.experiment_id,
      where: b.status in ["pending", "running"] and e.status == "running",
      select: %{
        experiment_id: b.experiment_id,
        env_name: e.env_name,
        batch_id: b.id,
        cmd: b.cmd,
        payload: b.payload,
        n_results: b.n_results,
        sum_reward: b.sum_reward,
        sum_sq_reward: b.sum_sq_reward,
        best_reward: b.best_reward,
        baseline_reward: b.baseline_reward,
        completed_chunks: b.completed_chunks,
        total_chunks: b.total_chunks,
        policy_version: e.policy_version
      }
    )
    |> Repo.all()
  end

  defp render_row(row, rings, now_ms) do
    n = row.n_results || 0
    sum = row.sum_reward || 0.0
    sum_sq = row.sum_sq_reward || 0.0

    mean = if n > 0, do: sum / n, else: nil

    # Variance: E[X²] - (E[X])². Guard against tiny negatives from
    # floating-point round-off (mathematically variance ≥ 0).
    stddev =
      if n > 1 and not is_nil(mean) do
        var = sum_sq / n - mean * mean
        if var > 0, do: :math.sqrt(var), else: 0.0
      end

    progress =
      cond do
        is_integer(row.total_chunks) and row.total_chunks > 0 ->
          (row.completed_chunks || 0) / row.total_chunks

        true ->
          0.0
      end

    {rate, new_rings} = update_ring_and_rate(rings, row.batch_id, n, now_ms)

    target_bit =
      case row.payload do
        %{"target_bit" => b} when is_integer(b) -> b
        _ -> nil
      end

    # Streaming-CEGAR §Layer 3 surface: piggyback the most recent
    # commits on each active-experiment frame so the dashboard
    # can light up a "v=N — bit 3 +2.1" strip without opening a
    # second SSE stream. Two reads per refresh per active row;
    # `latest_commits/2` is indexed on (experiment_id, version).
    commits = Experiments.latest_commits(row.experiment_id, 5)

    payload = %{
      experiment_id: row.experiment_id,
      env_name: row.env_name,
      active_bit: %{
        batch_id: row.batch_id,
        target_bit: target_bit,
        cmd: row.cmd,
        n_results: n,
        mean: mean,
        stddev: stddev,
        best_reward: row.best_reward,
        baseline_reward: row.baseline_reward,
        completed_chunks: row.completed_chunks || 0,
        total_chunks: row.total_chunks || 0,
        progress: progress,
        results_per_min: rate
      },
      policy_version: row.policy_version,
      latest_commits:
        Enum.map(commits, fn c ->
          %{
            version: c.version,
            bit_idx: c.bit_idx,
            prev_reward: c.prev_reward,
            new_reward: c.new_reward,
            delta:
              if(is_number(c.new_reward) and is_number(c.prev_reward),
                do: c.new_reward - c.prev_reward,
                else: nil
              ),
            committed_at: c.committed_at
          }
        end)
    }

    {payload, new_rings}
  end

  # Rolling 60-s window: push the current `n_results` sample, trim
  # anything older than the window, derive the rate from (newest -
  # oldest) over elapsed time. Same shape as `MetricsBroker`'s
  # rate-per-minute, just keyed by batch_id.
  defp update_ring_and_rate(rings, batch_id, n_results, now_ms) do
    ring =
      rings
      |> Map.get(batch_id, :queue.new())
      |> push_ring(now_ms, n_results)
      |> trim_ring(now_ms)

    rate = rate_per_minute(ring, now_ms, n_results)

    {rate, Map.put(rings, batch_id, ring)}
  end

  defp push_ring(ring, ts, n), do: :queue.in({ts, n}, ring)

  defp trim_ring(ring, now_ms) do
    cutoff = now_ms - @window_secs * 1000

    case :queue.peek(ring) do
      {:value, {ts, _}} when ts < cutoff ->
        {{:value, _}, rest} = :queue.out(ring)
        trim_ring(rest, now_ms)

      _ ->
        ring
    end
  end

  defp rate_per_minute(ring, now_ms, latest_total) do
    case :queue.peek(ring) do
      {:value, {oldest_ts, oldest_total}} when oldest_ts < now_ms ->
        elapsed_s = (now_ms - oldest_ts) / 1000

        if elapsed_s > 0 do
          delta = latest_total - oldest_total
          round(delta * 60 / elapsed_s)
        else
          0
        end

      _ ->
        0
    end
  end
end
