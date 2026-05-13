defmodule Server.SystemEvent do
  @moduledoc """
  Surfaced incident / status event. Anything that would otherwise
  silently go wrong on Synthex Hub gets a row here, and the
  landing page renders the last 24h's events as a banner so the
  swarm's actual health is visible at a glance.

  ## Sources

    * `"oban"`   — an Oban job exhausted its retries; recorded by
                   `Server.ObanFailureHandler`
    * `"master"` — a Server.Workers.Experiment* worker explicitly
                   flagged something the human running the swarm
                   should see (e.g. a config validation failure
                   at bootstrap, an unexpectedly empty feature set)
    * `"reaper"` — `Server.OrphanReaper` cleaned up a batch whose
                   master had gone silent (defense-in-depth; with
                   the Oban-master refactor, this should be empty)

  ## Levels

  `"info" | "warn" | "error"`. The landing page only banners
  `"warn"` and `"error"`; `"info"` is purely historical.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "system_events" do
    field :level, :string
    field :source, :string
    field :message, :string
    field :env_name, :string
    field :experiment_id, Ecto.UUID
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @castable ~w(level source message env_name experiment_id metadata)a

  def changeset(event, attrs) do
    event
    |> cast(attrs, @castable)
    |> validate_required([:level, :source, :message])
    |> validate_inclusion(:level, ~w(info warn error))
  end
end
