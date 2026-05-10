defmodule Server.Jobs.ReapWorkers do
  @moduledoc """
  Periodic Oban cron job: marks workers whose heartbeat has expired as
  inactive. Their in-flight chunks remain `executing` in Oban; the
  Lifeline plugin handles rescuing those independently.
  """
  use Oban.Worker, queue: :system, max_attempts: 1

  @impl Oban.Worker
  def perform(_job) do
    timeout = Application.get_env(:server, :worker_heartbeat_timeout_secs, 120)
    Server.Queue.mark_inactive_workers(timeout)
    :ok
  end
end
