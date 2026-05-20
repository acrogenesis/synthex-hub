defmodule Server.Repo.Migrations.PolicySnapshotsPerLineage do
  use Ecto.Migration

  @moduledoc """
  Rekeys `policy_snapshots` to the env_policy lineage.

  Before this migration:
    PK = env_name (string)
    → every (env_name, config_sig) lineage shared one row, so a
      commit on the tridiag-HalfCheetah lineage would clobber the
      4-class-HalfCheetah snapshot the moment it landed. Both
      cards on the dashboard rendered the same blob.

  After:
    PK = env_policy_id (uuid, FK → env_policies)
    → one snapshot per lineage. The dashboard fetches by lineage
      and each card shows its own "CURRENT POLICY".

  ## Backfill

  Each existing policy_snapshots row is attributed to the
  env_policy with the same `env_name` and the highest
  `best_reward` — i.e. the lineage that almost certainly produced
  it (the one with the most progress). If two lineages tied on
  best_reward, the highest policy_version wins; ties beyond that
  resolve by `inserted_at` DESC (most recently committed wins).

  ## Reversibility

  Down is intentionally not provided. Reverting would require
  collapsing per-lineage snapshots back into one-per-env, which
  is the bug this migration is fixing.
  """

  def up do
    alter table(:policy_snapshots) do
      add :env_policy_id, references(:env_policies, type: :uuid, on_delete: :delete_all)
    end

    create index(:policy_snapshots, [:env_policy_id])

    flush()

    backfill_env_policy_ids()

    execute("DELETE FROM policy_snapshots WHERE env_policy_id IS NULL")

    execute("ALTER TABLE policy_snapshots ALTER COLUMN env_policy_id SET NOT NULL")

    # Swap the primary key. Two-step: drop the existing PK constraint
    # (it's on env_name), then add the new one on env_policy_id.
    execute("ALTER TABLE policy_snapshots DROP CONSTRAINT policy_snapshots_pkey")
    execute("ALTER TABLE policy_snapshots ADD PRIMARY KEY (env_policy_id)")

    drop index(:policy_snapshots, [:env_policy_id])
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "PolicySnapshotsPerLineage is irreversible. Reverting would re-introduce " <>
          "the cross-lineage clobbering bug it exists to fix."
  end

  defp backfill_env_policy_ids do
    repo = repo()

    %Postgrex.Result{rows: rows} =
      repo.query!("SELECT env_name FROM policy_snapshots")

    Enum.each(rows, fn [env_name] ->
      case lookup_winner(repo, env_name) do
        nil ->
          # No env_policy exists for this env. The post-flush
          # `DELETE WHERE env_policy_id IS NULL` will discard the
          # snapshot — there's no lineage to attribute it to and
          # it'll be re-published as soon as that env gets a
          # commit again.
          :ok

        env_policy_id ->
          repo.query!(
            """
            UPDATE policy_snapshots
            SET env_policy_id = $1
            WHERE env_name = $2
            """,
            [env_policy_id, env_name]
          )
      end
    end)
  end

  defp lookup_winner(repo, env_name) do
    %Postgrex.Result{rows: rows} =
      repo.query!(
        """
        SELECT id
        FROM env_policies
        WHERE env_name = $1
        ORDER BY COALESCE(best_reward, -1e18) DESC,
                 policy_version DESC,
                 inserted_at DESC
        LIMIT 1
        """,
        [env_name]
      )

    case rows do
      [[id]] -> id
      _ -> nil
    end
  end
end
