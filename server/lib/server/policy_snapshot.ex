defmodule Server.PolicySnapshot do
  @moduledoc """
  Latest published policy state for a single environment.

  Masters POST to `/api/master/policy-snapshots` whenever the
  CEGAR loop accepts a new bit; this row is UPSERTed on
  `env_name` so the hub always serves the freshest snapshot.

  Public landing-page consumers fetch it through
  `/api/public-status/policies/:env_name`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:env_name, :string, autogenerate: false}
  schema "policy_snapshots" do
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
    |> validate_required([:env_name, :bit_predicates])
  end
end
