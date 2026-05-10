defmodule Server.Repo.Migrations.CreateBatches do
  use Ecto.Migration

  def change do
    create table(:batches, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string
      add :env_name, :string, null: false
      add :cmd, :string, null: false, default: "score_bit"
      add :payload, :map, null: false, default: %{}
      add :total_chunks, :integer, null: false, default: 0
      add :completed_chunks, :integer, null: false, default: 0
      add :status, :string, null: false, default: "pending"
      add :results, {:array, :map}, default: []
      add :submitter, :string

      timestamps(type: :utc_datetime_usec)
      add :completed_at, :utc_datetime_usec
      add :ttl_at, :utc_datetime_usec
    end

    create index(:batches, [:status])
    create index(:batches, [:inserted_at])
    create index(:batches, [:ttl_at])
  end
end
