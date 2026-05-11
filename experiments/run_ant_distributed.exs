# Ant — distributed CSHRL synthesis.
#
# Run as the master driver. Friends donate compute by running the
# one-liner installer (which spins up workers anonymously):
#
#     curl -fsSL https://synthex.fit/install | sh
#
# Then, on YOUR machine:
#
#     export SYNTHEX_HUB_TOKEN=<your hub master token>
#     cd /path/to/synthex-hub
#     mix run experiments/run_ant_distributed.exs
#
# Master prerequisites:
#   * Elixir 1.18+
#
# Notably, NO Python on the master. Every oracle call (collect_states,
# score_bit, validate) is dispatched to the hub's worker swarm. The
# only thing this script does locally is the CEGAR loop in pure Elixir.

Mix.install([
  {:synthex,
   git: "https://github.com/doctorcorral/synthex.git",
   ref: System.get_env("SYNTHEX_GIT_REF", "main")},
  {:synthex_hub_client,
   git: "https://github.com/doctorcorral/synthex-hub.git",
   subdir: "client",
   ref: System.get_env("SYNTHEX_HUB_GIT_REF", "main")}
])

# Pre-flight: how big is the cluster right now?
client = Synthex.Hub.Client.new()

case Synthex.Hub.Client.public_status(client) do
  {:ok, %{"active_workers" => 0}} ->
    IO.puts("\n  WARNING: 0 active workers connected at #{client.base_url}")
    IO.puts("  Tell collaborators: curl -fsSL https://synthex.fit/install | sh")
    IO.puts("  (continuing — chunks will queue and run when workers come online)\n")

  {:ok, %{"active_workers" => n, "total_cores" => c}} ->
    IO.puts("\n  Cluster: #{n} worker(s), #{c} core(s) ready.\n")

  {:error, reason} ->
    IO.puts("\n  Could not reach hub: #{inspect(reason)}\n")
end

scorer =
  Synthex.Hub.Scorer.new(
    env_key: :ant,
    chunk_size: 100,
    poll_interval_ms: 5_000
  )

# Publish a fresh policy snapshot to the hub on every accepted
# CEGAR bit, so visitors to synthex.fit can click the Ant card
# and read the current Python pseudocode. Snapshot push failures
# are logged but never crash the master.
:ok = Synthex.Hub.Telemetry.attach_snapshot_publisher(client, handler_id: "ant-snapshot-push")

Synthex.Gym.Mujoco.solve(:ant,
  scorer: scorer,
  bits_per_dim: 3,
  depth: 1,
  max_coeff: 5,

  # All five feature classes including tridiag.
  feature_types: [:axis, :diag, :sq_diag, :prod, :tridiag],
  # Ant has 105 obs dims; full tridiag would be ~10M features. Cap
  # the coefficient bound and restrict to qpos+qvel (first 27 dims)
  # to keep this tractable on a 32-core swarm.
  tridiag_max_coeff: 2,
  tridiag_dims: 0..26,
  n_episodes: 30,
  top_k: 24,
  max_iters: 5,
  cegar_rounds: 3,
  max_steps: 1000
)
