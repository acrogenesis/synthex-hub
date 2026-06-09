defmodule Server.Repo.Migrations.AddWorkerCapabilities do
  use Ecto.Migration

  @moduledoc """
  Adds an ordered `capabilities` array to `workers`.

  ## What it's for

  Capability-aware chunk routing. Each chunk now carries an
  `adapter` tag in its Oban args (defaulting to `"mujoco"`), and a
  worker only claims chunks whose adapter it can actually run.
  This is the prerequisite for heterogeneous workers — e.g. a
  CUDA-equipped box running a `mujoco_warp` oracle alongside the
  CPU `mujoco` swarm.

  ## Why an ORDERED array, not a set

  The order encodes *preference*. A GPU worker advertises
  `{mujoco_warp, mujoco}` meaning "prefer Warp work, fall back to
  plain MuJoCo when no Warp chunks are available." `claim_chunk`
  uses `array_position(capabilities, adapter)` as a soft sort key
  so the worker drains its preferred adapter first but never sits
  idle when only lower-preference work exists. A CPU worker
  advertises just `{mujoco}` and is hard-filtered away from Warp
  chunks it can't execute.

  ## Default

  `'{mujoco}'` for every existing and future row that doesn't
  specify otherwise — so the entire current swarm keeps behaving
  exactly as before this migration (it only ever sees, and only
  ever could run, `mujoco` chunks). The routing change is a no-op
  until a worker registers with a richer capability list AND a
  batch is tagged with a non-default adapter.
  """

  def up do
    alter table(:workers) do
      add :capabilities, {:array, :string}, null: false, default: ["mujoco"]
    end
  end

  def down do
    alter table(:workers) do
      remove :capabilities
    end
  end
end
