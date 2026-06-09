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

    # Ordered list of physics adapters this worker can run, most
    # preferred first. `["mujoco"]` is the CPU swarm default; a
    # CUDA box runs e.g. `["mujoco_warp", "mujoco"]`. Drives the
    # hard filter + soft preference in `Server.Queue.claim_chunk/1`.
    field :capabilities, {:array, :string}, default: ["mujoco"]
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
      :status,
      :capabilities
    ])
    |> validate_required([:id, :registered_at, :last_heartbeat_at])
    |> validate_inclusion(:status, ~w(active inactive draining))
    |> normalize_capabilities()
  end

  # A worker that registers without (or with an empty) capabilities
  # list is a legacy/CPU worker — it can only run mujoco. Never
  # store an empty list, or claim_chunk's `= ANY(capabilities)`
  # filter would match nothing and the worker would silently
  # starve.
  defp normalize_capabilities(changeset) do
    case get_field(changeset, :capabilities) do
      caps when is_list(caps) and caps != [] -> changeset
      _ -> put_change(changeset, :capabilities, ["mujoco"])
    end
  end
end
