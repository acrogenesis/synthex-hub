defmodule Server.Experiment do
  @moduledoc """
  A CEGAR synthesis run. The unit of "experiment" on Synthex Hub.

  One row per submission. The master loop that drives it is an
  Oban job (`Server.Workers.ExperimentBootstrap` →
  `Server.Workers.ExperimentCegarIter` ×N → `Server.Workers.ExperimentComplete`)
  that reads and writes this row after every accepted bit, so a
  crashed/retried worker resumes from exactly where it left off
  rather than wasting compute redoing accepted bits.

  ## State machine

      pending  ──bootstrap──→ running ──last_iter_done──→ completed
         ↓                       ↓
       (fail / cancel)         (fail / cancel)
         ↓                       ↓
       cancelled               failed
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  schema "experiments" do
    field :env_name, :string
    field :env_key, :string
    field :submitter, :string

    field :config, :map, default: %{}
    field :status, :string, default: "pending"

    field :predicates, :map, default: %{"preds" => []}
    field :current_cegar_iter, :integer, default: 0
    field :current_iter, :integer, default: 0
    field :bit_shuffle, {:array, :integer}, default: []
    field :bit_progress, {:array, :integer}, default: []

    field :baseline_reward, :float
    field :best_reward, :float
    field :accepted_count, :integer, default: 0

    # Streaming-CEGAR §Layer 3 commit gate. `policy_version` is the
    # monotonically increasing counter the gate enforces; every
    # accepted commit bumps it by 1 (see `Server.CommitGate`).
    # `best_reward_per_bit` is the per-bit pool snapshot the gate
    # consults to decide if a new candidate beats the current best
    # for its bit. Keyed by stringified bit index; `nil` when a bit
    # has never been scored at the current version.
    field :policy_version, :integer, default: 0
    field :best_reward_per_bit, :map, default: %{}

    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :error, :string

    timestamps(type: :utc_datetime_usec)
  end

  @castable ~w(env_name env_key submitter config status predicates
               current_cegar_iter current_iter bit_shuffle bit_progress
               baseline_reward best_reward accepted_count
               policy_version best_reward_per_bit
               started_at completed_at error)a

  def changeset(experiment, attrs) do
    experiment
    |> cast(attrs, @castable)
    |> validate_required([:env_name, :env_key])
    |> validate_inclusion(:status, ~w(pending running completed failed cancelled))
    # Matches the partial unique index in the migration. Lets the
    # changeset surface a clean :env_name error when an operator
    # double-submits for an env that already has a pending/running
    # row.
    |> unique_constraint(:env_name, name: :experiments_one_active_per_env)
  end
end
