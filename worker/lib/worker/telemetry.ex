defmodule Worker.Telemetry do
  @moduledoc """
  Attaches lightweight log handlers to Broadway and our own pipeline
  events. Real telemetry sinks (Prometheus, OTel, Datadog) can attach
  their own handlers to these same event names — that's the whole
  point of using `:telemetry` rather than ad-hoc logging.

  Events emitted by us:

    * `[:synthex_hub, :worker, :chunk, :claimed]`
        measurements: `%{candidates: n}`
        metadata:     `%{chunk_id, env_name}`
    * `[:synthex_hub, :worker, :chunk, :completed]`
        measurements: `%{candidates: n, duration_ms: ms}`
        metadata:     `%{chunk_id}`
    * `[:synthex_hub, :worker, :chunk, :submitted]` / `:submit_failed`
    * `[:synthex_hub, :worker, :candidate, :scored]`
        measurements: `%{duration: native_time}`
        metadata:     `%{chunk_id, idx, success}`
    * `[:synthex_hub, :worker, :poll, :empty]` / `:error`

  Broadway emits its own events (see Broadway.Telemetry); we wire a
  couple of useful ones to logs by default.
  """
  require Logger

  @events [
    [:broadway, :processor, :message, :exception],
    [:broadway, :processor, :message, :failure]
  ]

  def attach do
    :telemetry.attach_many(
      "worker-broadway-error-logger",
      @events,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event([:broadway, :processor, :message, :exception], _meas, meta, _) do
    Logger.error(
      "[Broadway] processor exception: #{inspect(meta[:kind])} #{inspect(meta[:reason])}"
    )
  end

  def handle_event([:broadway, :processor, :message, :failure], _meas, meta, _) do
    Logger.warning("[Broadway] message marked failed: #{inspect(meta)}")
  end
end
