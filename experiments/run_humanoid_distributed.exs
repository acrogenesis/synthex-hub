# Humanoid — distributed CSHRL synthesis.
#
# This is the stretch goal: 17 action dims × 3 bits/dim = 51 predicates
# per CEGAR iteration, each enumerated against ~10–100k atomic features.
# A single laptop won't finish; a 32-core swarm of friends might.
#
# Prereqs and launch: see run_ant_distributed.exs.

Mix.install([
  {:synthex,
   git: "https://github.com/doctorcorral/synthex.git",
   ref: System.get_env("SYNTHEX_GIT_REF", "main")},
  {:synthex_hub_client,
   git: "https://github.com/doctorcorral/synthex-hub.git",
   subdir: "client",
   ref: System.get_env("SYNTHEX_HUB_GIT_REF", "main")}
])

client = Synthex.Hub.Client.new()

case Synthex.Hub.Client.public_status(client) do
  {:ok, %{"active_workers" => 0}} ->
    IO.puts("\n  WARNING: 0 active workers connected at #{client.base_url}")
    IO.puts("  Humanoid will queue chunks until workers come online.\n")

  {:ok, %{"active_workers" => n, "total_cores" => c}} ->
    IO.puts("\n  Cluster: #{n} worker(s), #{c} core(s) ready.")

    if c < 16 do
      IO.puts("  Heads-up: Humanoid is heavy. <16 cores will take >24h per CEGAR round.\n")
    else
      IO.puts("")
    end

  {:error, reason} ->
    IO.puts("\n  Could not reach hub: #{inspect(reason)}\n")
end

scorer =
  Synthex.Hub.Scorer.new(
    env_key: :humanoid,
    chunk_size: 50,
    poll_interval_ms: 10_000
  )

Synthex.Gym.Mujoco.solve(:humanoid,
  scorer: scorer,
  bits_per_dim: 3,
  depth: 1,
  max_coeff: 5,

  # Humanoid has 348 obs dims. axis + diag alone are already ~120k
  # features; adding sq_diag + prod brings it to ~250k. Tridiag at
  # full strength would be ~4 BILLION — utterly intractable. We
  # restrict it to the first 23 dims (qpos minus root excludes 22,
  # plus 1 buffer) which roughly corresponds to joint positions,
  # the most physically meaningful for tridiagonal "linkage" patterns.
  feature_types: [:axis, :diag, :sq_diag, :prod, :tridiag],
  tridiag_max_coeff: 2,
  tridiag_dims: 0..22,
  n_episodes: 30,
  top_k: 24,
  max_iters: 4,
  cegar_rounds: 3,
  max_steps: 1000
)
