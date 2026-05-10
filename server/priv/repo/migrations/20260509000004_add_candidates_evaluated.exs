defmodule Server.Repo.Migrations.AddCandidatesEvaluated do
  @moduledoc """
  Workers track an exact running total of candidates they've scored.
  `jobs_completed` was previously incremented once per chunk; this
  separates the two so the landing-page counter at synthex.fit shows
  candidate-level work, not chunk-level work.
  """
  use Ecto.Migration

  def change do
    alter table(:workers) do
      add :candidates_evaluated, :bigint, default: 0, null: false
    end
  end
end
