defmodule Server.PolicySnapshot do
  @moduledoc """
  Latest published policy state for a single lineage
  (`env_policy_id`).

  ## Identity

  One row per `env_policies` row. The primary key is
  `env_policy_id` (uuid) — NOT `env_name`. Before the lineage
  refactor, the PK was `env_name`, which meant two
  `(env_name, config_sig)` lineages running in parallel would
  clobber each other's snapshots: whichever committed last
  overwrote the other and both dashboard cards rendered the
  same blob.

  `env_name` is retained as an informational field for
  rendering (it's cached on the snapshot so the dashboard
  can label policies without joining through env_policies for
  every poll), but it is not unique.

  ## Lifecycle

  Masters call `Server.Queue.upsert_policy_snapshot/2` whenever
  the CEGAR loop accepts a new bit on a lineage. The hub serves
  the freshest snapshot through
  `/api/public-status/policies/:env_policy_id`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:env_policy_id, Ecto.UUID, autogenerate: false}
  @foreign_key_type Ecto.UUID
  schema "policy_snapshots" do
    field :env_name, :string

    field :bit_predicates, :map, default: %{}
    field :policy_code, :string
    field :code_language, :string, default: "python"

    field :n_bits, :integer
    field :target_bit, :integer
    field :cegar_iter, :integer
    field :iter, :integer
    field :best_reward, :float
    field :baseline_reward, :float

    field :batch_id, :string
    field :submitter, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :env_policy_id,
      :env_name,
      :bit_predicates,
      :policy_code,
      :code_language,
      :n_bits,
      :target_bit,
      :cegar_iter,
      :iter,
      :best_reward,
      :baseline_reward,
      :batch_id,
      :submitter
    ])
    |> validate_required([:env_policy_id, :env_name, :bit_predicates])
  end
end
