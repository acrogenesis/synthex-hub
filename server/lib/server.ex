defmodule Server do
  @moduledoc """
  Synthex Hub server — Oban-backed CSHRL job queue.

  Master clients submit batches; HTTP workers pull chunks, run them
  in their own Python ports, and submit results.

  See `Server.Queue` for the orchestration logic.
  """

  defdelegate submit_batch(payload, opts \\ []), to: Server.Queue
  defdelegate get_batch(batch_id), to: Server.Queue
  defdelegate status(), to: Server.Queue
end
