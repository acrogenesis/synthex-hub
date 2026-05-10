defmodule Server.Repo.Migrations.CreateWorkers do
  use Ecto.Migration

  def change do
    create table(:workers, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string
      add :hostname, :string
      add :pool_size, :integer, default: 1
      add :version, :string
      add :metadata, :map, default: %{}
      add :registered_at, :utc_datetime_usec, null: false
      add :last_heartbeat_at, :utc_datetime_usec, null: false
      add :jobs_completed, :integer, default: 0
      add :status, :string, default: "active"
    end

    create index(:workers, [:status])
    create index(:workers, [:last_heartbeat_at])
  end
end
