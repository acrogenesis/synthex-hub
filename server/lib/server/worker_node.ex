defmodule Server.WorkerNode do
  @moduledoc """
  A registered compute node. Updates `last_heartbeat_at` periodically;
  workers whose heartbeat is older than the configured timeout are
  marked `inactive` and any chunks they hold are eligible for Oban
  Lifeline rescue.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "workers" do
    field :name, :string
    field :hostname, :string
    field :pool_size, :integer, default: 1
    field :version, :string
    field :metadata, :map, default: %{}
    field :registered_at, :utc_datetime_usec
    field :last_heartbeat_at, :utc_datetime_usec
    field :jobs_completed, :integer, default: 0
    field :candidates_evaluated, :integer, default: 0
    field :status, :string, default: "active"
  end

  def changeset(worker, attrs) do
    worker
    |> cast(attrs, [
      :id,
      :name,
      :hostname,
      :pool_size,
      :version,
      :metadata,
      :registered_at,
      :last_heartbeat_at,
      :jobs_completed,
      :candidates_evaluated,
      :status
    ])
    |> validate_required([:id, :registered_at, :last_heartbeat_at])
    |> validate_inclusion(:status, ~w(active inactive draining))
  end
end
