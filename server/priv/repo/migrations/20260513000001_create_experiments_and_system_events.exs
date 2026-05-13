defmodule Server.Repo.Migrations.CreateExperimentsAndSystemEvents do
  use Ecto.Migration

  def change do
    # `experiments` is the new top-level abstraction: one row per
    # CEGAR run. The previous model treated each `score_bit` HTTP
    # submission as the unit, which meant the master loop (the
    # actual experiment) lived only as a process on someone's
    # laptop. Now the master loop is an Oban job that owns this
    # row and checkpoints to it after every accepted bit.
    create table(:experiments, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :env_name, :string, null: false
      add :env_key, :string, null: false
      add :submitter, :string

      # JSON-encoded synthesis opts (bits_per_dim, depth, max_coeff,
      # feature_types, tridiag_dims, n_episodes, top_k, max_iters,
      # cegar_rounds, max_steps, ...). Pass-through to
      # `Synthex.Gym.Mujoco.init_context/2`.
      add :config, :map, null: false, default: %{}

      # State machine. `Oban.Plugins.Pruner` is configured for jobs,
      # not experiments — experiments stay forever as a history.
      #   pending   — row inserted, bootstrap not yet started
      #   running   — bootstrap done, CEGAR iters enqueued
      #   completed — all iters done, final validation recorded
      #   failed    — an Oban job exhausted its retries; see `error`
      #   cancelled — operator pause/cancel via API
      add :status, :string, null: false, default: "pending"

      # CEGAR state. `predicates` is the running policy: a list of
      # JSON-encoded predicate terms (one per bit). On every
      # accepted improvement the worker upserts this; on retry it
      # reads it back. The chunked CEGAR scheduler also persists:
      #
      #   * `current_cegar_iter` — which outer loop iteration (1-N)
      #   * `current_iter`       — which inner iteration within the
      #                            CEGAR round (1-max_iters)
      #   * `bit_shuffle`        — bit ordering for the current iter
      #                            (deterministic; reused on retry)
      #   * `bit_progress`       — bits already processed this iter
      #                            (skip on retry, no compute wasted)
      add :predicates, :map, null: false, default: %{"preds" => []}
      add :current_cegar_iter, :integer, null: false, default: 0
      add :current_iter, :integer, null: false, default: 0
      add :bit_shuffle, {:array, :integer}, default: []
      add :bit_progress, {:array, :integer}, default: []

      # Reward summary. Set by bootstrap then updated by each
      # accepted bit's reward.
      add :baseline_reward, :float
      add :best_reward, :float
      add :accepted_count, :integer, null: false, default: 0

      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:experiments, [:env_name])
    create index(:experiments, [:status])
    # Prevent two concurrent runs for the same env. Submission
    # rejects with 409 if there's already a pending/running row
    # for the env. Completed/failed/cancelled don't count.
    create unique_index(:experiments, [:env_name],
             where: "status IN ('pending','running')",
             name: :experiments_one_active_per_env
           )

    # `system_events` is the surfaced incident log: anything that
    # would otherwise silently go wrong gets a row here. The
    # landing page renders the last 24h as a banner so a stalled
    # / failed experiment is immediately visible.
    create table(:system_events) do
      add :level, :string, null: false           # "info" | "warn" | "error"
      add :source, :string, null: false          # "oban" | "reaper" | "master" | ...
      add :message, :text, null: false
      add :env_name, :string                     # nullable — global events too
      add :experiment_id, references(:experiments, type: :uuid, on_delete: :nilify_all)
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:system_events, [:inserted_at])
    create index(:system_events, [:level])
    create index(:system_events, [:env_name])
    create index(:system_events, [:experiment_id])

    # Link experiments to the Batch rows they spawn so we can show
    # progress and clean up orphans. NULL `experiment_id` retains
    # the legacy "submitted by a laptop master" case for backward
    # compatibility while we migrate.
    alter table(:batches) do
      add :experiment_id, references(:experiments, type: :uuid, on_delete: :nilify_all)
    end

    create index(:batches, [:experiment_id])
  end
end
