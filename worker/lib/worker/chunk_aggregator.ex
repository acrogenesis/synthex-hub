defmodule Worker.ChunkAggregator do
  @moduledoc """
  Tracks per-chunk completion outside of Broadway's batcher because
  chunks have variable sizes (the last chunk of a master submission
  may be smaller than `chunk_size`). Each chunk is registered with
  `total` candidates expected; once that many results arrive, we
  submit the assembled chunk back to the hub with bounded retries.

  Why a sibling GenServer instead of a Broadway batcher:
    * Broadway batchers flush on `batch_size` or `batch_timeout`,
      both global; we'd either flush partial chunks early (wasting
      compute) or wait the full timeout on every last chunk.
    * Aggregator state per chunk is tiny (count + a list of result
      maps), so a single GenServer scales for thousands of in-flight
      chunks without ETS.

  Crash semantics: if this process dies mid-chunk, in-flight chunks
  go unsubmitted. Oban Lifeline rescues them on the server after
  the lease expires, so another worker re-runs them. The local
  compute that was lost is the cost of the crash; correctness is
  preserved.
  """
  use GenServer
  require Logger

  @max_submit_attempts 5

  # ── Public API ──────────────────────────────────────────────

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Called by the producer right before emitting a chunk's candidate
  messages. `total` is the expected number of `add_result/3` calls
  for this `chunk_id`.
  """
  def register_chunk(chunk_id, total, chunk_meta) do
    GenServer.cast(__MODULE__, {:register, chunk_id, total, chunk_meta})
  end

  @doc """
  Called by Broadway processors after each candidate is scored
  (or failed). When the cumulative count reaches `total`, the chunk
  is submitted to the hub.
  """
  def add_result(chunk_id, result) do
    GenServer.cast(__MODULE__, {:result, chunk_id, result})
  end

  def stats, do: GenServer.call(__MODULE__, :stats)

  # ── Implementation ──────────────────────────────────────────

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    {:ok, %{chunks: %{}, submitting: %{}}}
  end

  @impl true
  def handle_cast({:register, chunk_id, total, meta}, state) do
    chunk_state = %{
      total: total,
      results: [],
      meta: meta,
      registered_at: System.monotonic_time(:millisecond)
    }

    {:noreply, %{state | chunks: Map.put(state.chunks, chunk_id, chunk_state)}}
  end

  def handle_cast({:result, chunk_id, result}, state) do
    case Map.get(state.chunks, chunk_id) do
      nil ->
        Logger.warning("[Aggregator] result for unknown chunk_id=#{chunk_id}; dropping")
        {:noreply, state}

      %{results: results, total: total} = chunk_state ->
        new_results = [result | results]

        if length(new_results) >= total do
          finish_chunk(chunk_id, chunk_state, new_results, state)
        else
          updated = %{chunk_state | results: new_results}
          {:noreply, %{state | chunks: Map.put(state.chunks, chunk_id, updated)}}
        end
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    in_progress =
      state.chunks
      |> Enum.map(fn {id, %{total: total, results: r}} ->
        {id, %{total: total, received: length(r)}}
      end)
      |> Enum.into(%{})

    {:reply, %{in_progress: in_progress, submitting: map_size(state.submitting)}, state}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    case Map.pop(state.submitting, ref) do
      {nil, _} ->
        {:noreply, state}

      {chunk_id, submitting} ->
        Process.demonitor(ref, [:flush])
        Logger.debug("[Aggregator] submission task done for chunk_id=#{chunk_id}")
        {:noreply, %{state | submitting: submitting}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.submitting, ref) do
      {nil, _} ->
        {:noreply, state}

      {chunk_id, submitting} ->
        Logger.warning(
          "[Aggregator] submission task for #{chunk_id} died: #{inspect(reason)}; " <>
            "Lifeline will rescue on the server"
        )

        {:noreply, %{state | submitting: submitting}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Submission ─────────────────────────────────────────────

  defp finish_chunk(chunk_id, chunk_state, new_results, state) do
    elapsed = System.monotonic_time(:millisecond) - chunk_state.registered_at

    sorted = Enum.sort_by(new_results, &(&1["idx"] || 0))

    :telemetry.execute(
      [:synthex_hub, :worker, :chunk, :completed],
      %{candidates: chunk_state.total, duration_ms: elapsed},
      %{chunk_id: chunk_id}
    )

    Logger.info(
      "[Aggregator] chunk #{chunk_id} complete (#{chunk_state.total} candidates in #{elapsed}ms); submitting"
    )

    task =
      Task.Supervisor.async_nolink(
        Worker.SubmitTaskSupervisor,
        fn -> submit_with_retries(chunk_id, sorted, @max_submit_attempts) end
      )

    submitting = Map.put(state.submitting, task.ref, chunk_id)
    chunks = Map.delete(state.chunks, chunk_id)
    {:noreply, %{state | chunks: chunks, submitting: submitting}}
  end

  defp submit_with_retries(chunk_id, results, attempts_left) do
    payload = %{
      chunk_id: chunk_id,
      worker_id: Application.get_env(:worker, :worker_id),
      results: results
    }

    case Worker.HttpClient.post("/worker/jobs/submit", payload) do
      {:ok, %{status: 200}} ->
        :telemetry.execute([:synthex_hub, :worker, :chunk, :submitted], %{count: 1}, %{
          chunk_id: chunk_id
        })

        :ok

      {:ok, %{status: 404}} ->
        Logger.warning("[Aggregator] hub returned 404 for #{chunk_id}; chunk likely already rescued, dropping")
        :dropped

      other when attempts_left > 1 ->
        backoff = (@max_submit_attempts - attempts_left + 1) * 1_000 + :rand.uniform(1_000)

        Logger.warning(
          "[Aggregator] submit #{chunk_id} failed (#{inspect(other)}); retrying in #{backoff}ms (#{attempts_left - 1} left)"
        )

        Process.sleep(backoff)
        submit_with_retries(chunk_id, results, attempts_left - 1)

      other ->
        Logger.error(
          "[Aggregator] submit #{chunk_id} permanently failed after #{@max_submit_attempts} attempts: #{inspect(other)}"
        )

        :telemetry.execute([:synthex_hub, :worker, :chunk, :submit_failed], %{count: 1}, %{
          chunk_id: chunk_id
        })

        :failed
    end
  end
end
