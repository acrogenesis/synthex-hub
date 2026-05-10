defmodule Server.BrokerWorker do
  @moduledoc """
  Placeholder Oban worker. Chunks are stored as Oban.Job rows for
  persistence, leases (Lifeline), retries, and pruning -- but they are
  pulled and executed by external HTTP workers, not by Oban itself.
  This `perform/1` should never be invoked because the `:chunks` queue
  runs at concurrency 0; it exists only so Oban.Job rows are well-formed.
  """
  use Oban.Worker, queue: :chunks, max_attempts: 5

  @impl Oban.Worker
  def perform(_job) do
    {:error, :not_executable_in_process}
  end
end
