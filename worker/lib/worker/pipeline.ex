defmodule Worker.Pipeline do
  @moduledoc """
  Broadway pipeline that turns the worker into a streaming
  candidate-evaluator.

  Topology:

      Worker.Pipeline.Producer  (one GenStage producer)
        │  emits one Broadway.Message per candidate, tagged with
        │  chunk_id, total, and the chunk-level params
        │
        ▼
      processors :default  (concurrency = pool_size, max_demand = 1)
        │  each call:
        │    1. Worker.PortPool.with_port/2  → checkout a Python port
        │    2. Worker.PythonPort.score/3    → score one candidate
        │    3. Worker.ChunkAggregator.add_result/2 with the result
        │  port is auto-returned (with_port wraps in try/after)
        │
        ▼
      (no batchers)
        Submission to the hub is performed by ChunkAggregator once
        all of a chunk's candidates have been scored. This avoids
        Broadway's fixed batch_size/batch_timeout, which doesn't fit
        variable-sized chunks.

  Why `max_demand: 1`: each candidate is heavy (a full Gymnasium
  rollout), so we want demand-pull granularity at message level. With
  a higher max_demand a single processor would buffer multiple
  messages while holding a port, blocking the rest of the pool.
  """
  use Broadway
  require Logger

  def start_link(_opts) do
    pool_size = Application.get_env(:worker, :pool_size, 1)

    producer_opts =
      [module: {Worker.Pipeline.Producer, []}, concurrency: 1]
      |> maybe_put_rate_limiting()

    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: producer_opts,
      processors: [
        default: [concurrency: pool_size, max_demand: 1, min_demand: 0]
      ]
      # No batchers — see moduledoc.
    )
  end

  defp maybe_put_rate_limiting(opts) do
    case Application.get_env(:worker, :rate_limit) do
      %{allowed: a, interval: i} ->
        Keyword.put(opts, :rate_limiting, allowed_messages: a, interval: i)

      _ ->
        opts
    end
  end

  # ── Broadway callbacks ──────────────────────────────────────

  @impl Broadway
  def handle_message(_processor, %Broadway.Message{} = message, _context) do
    %{candidate: candidate, idx: idx} = message.data

    chunk_id = message.metadata.chunk_id
    base_params = message.metadata.base_params
    timeout = score_timeout()

    started = System.monotonic_time()

    result =
      try do
        Worker.PortPool.with_port(timeout, fn port ->
          payload = build_payload(base_params, candidate)

          case Worker.PythonPort.score(port, payload, timeout) do
            {:ok, [first | _]} ->
              first |> Map.put("idx", idx)

            {:ok, []} ->
              %{"idx" => idx, "error" => "empty result from oracle"}

            {:error, reason} ->
              %{"idx" => idx, "error" => inspect(reason)}
          end
        end)
      rescue
        e -> %{"idx" => idx, "error" => "#{inspect(e.__struct__)}: #{Exception.message(e)}"}
      catch
        :exit, reason -> %{"idx" => idx, "error" => "exit: #{inspect(reason)}"}
      end

    duration = System.monotonic_time() - started

    :telemetry.execute(
      [:synthex_hub, :worker, :candidate, :scored],
      %{duration: duration},
      %{chunk_id: chunk_id, idx: idx, success: not Map.has_key?(result, "error")}
    )

    Worker.ChunkAggregator.add_result(chunk_id, result)
    Broadway.Message.put_data(message, result)
  end

  @impl Broadway
  def handle_failed(messages, _context) do
    # Broadway only calls this when handle_message itself raises beyond
    # our rescue/catch. Guard the invariant: aggregator must still see
    # a result for every message of the chunk, otherwise the chunk
    # would never complete.
    Enum.each(messages, fn message ->
      idx = message.data[:idx] || -1
      chunk_id = message.metadata[:chunk_id]
      reason = inspect(message.status)

      if chunk_id do
        Worker.ChunkAggregator.add_result(chunk_id, %{
          "idx" => idx,
          "error" => "broadway_failed: #{reason}"
        })
      end
    end)

    messages
  end

  defp build_payload(base_params, candidate) do
    base_params
    |> Map.put_new("cmd", "score_bit")
    |> Map.put("candidates", [candidate])
  end

  defp score_timeout do
    Application.get_env(:worker, :request_timeout_ms, 30_000) * 5
  end
end
