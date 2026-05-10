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
#   * Python 3 with `gymnasium`, `mujoco` installed locally — needed
#     for the small `collect_states` and `validate` calls that run
#     in-process (only the heavy `score_bit` work is farmed out).

Mix.install([
  {:synthex,            path: Path.expand("../../synthex", __DIR__)},
  {:synthex_hub_client, path: Path.expand("../client",     __DIR__)}
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
