defmodule Server.Repo.Migrations.CreatePolicySnapshots do
  @moduledoc """
  Per-environment policy snapshots published by masters as they run.

  One row per env (UPSERT on `env_name`); always holds the *latest*
  state of the bit-predicate program for that environment. Powers
  the public "click an experiment card to see its current policy"
  affordance on the synthex.fit landing page.

  We deliberately keep this as overwrite-only (no history) for
  three reasons:
    * The interesting story per env is the *current* policy, not
      every intermediate.
    * The full evolution is implicit in the chronological
      `batches.payload.bit_predicates` per batch — anyone who needs
      a timeline can reconstruct it from there.
    * Storage stays bounded by env count, not by run length.
  """
  use Ecto.Migration

  def change do
    create table(:policy_snapshots, primary_key: false) do
      add :env_name, :string, primary_key: true

      add :bit_predicates, :map, null: false, default: %{}
      add :policy_code, :text
      add :code_language, :string, default: "python"

      add :n_bits, :integer
      add :target_bit, :integer
      add :cegar_iter, :integer
      add :iter, :integer
      add :best_reward, :float
      add :baseline_reward, :float

      add :batch_id, :string
      add :submitter, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:policy_snapshots, [:updated_at])
  end
end
