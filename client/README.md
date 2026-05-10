# synthex_hub_client

Master-side client for [Synthex Hub](https://synthex.fit). Two pieces:

  * **`Synthex.Hub.Client`** — thin HTTP wrapper. Submit a batch,
    poll until it's done, return aggregated results.

  * **`Synthex.Hub.Scorer`** — a `Synthex.Scoring` implementation.
    Drops straight into `Synthex.Gym.Mujoco.solve/2` via the
    `scorer:` option to make synthesis distributed.

This library lives in the [synthex-hub](../) repository alongside the
`server/`, `worker/`, and `experiments/` directories. It's a separate
mix project so that `synthex` itself can stay HTTP-free — the
dependency direction is `synthex ← synthex_hub_client`, never the
other way around.

## Quick start

```elixir
# inside an experiment .exs file
Mix.install([
  {:synthex,
   git: "https://github.com/doctorcorral/synthex.git",
   ref: System.get_env("SYNTHEX_GIT_REF", "main")},
  {:synthex_hub_client,
   git: "https://github.com/doctorcorral/synthex-hub.git",
   subdir: "client",
   ref: System.get_env("SYNTHEX_HUB_GIT_REF", "main")}
])

scorer =
  Synthex.Hub.Scorer.new(
    env_key: :ant,
    url:     System.get_env("SYNTHEX_HUB_URL", "https://synthex.fit/api"),
    token:   System.fetch_env!("SYNTHEX_HUB_TOKEN")
  )

Synthex.Gym.Mujoco.solve(:ant,
  scorer: scorer,
  feature_types: [:axis, :diag, :sq_diag, :prod, :tridiag],
  tridiag_max_coeff: 2,
  tridiag_dims: 0..26,
  bits_per_dim: 3,
  depth: 1,
  max_coeff: 5,
  n_episodes: 30,
  top_k: 24,
  max_iters: 5,
  cegar_rounds: 3
)
```

See [`../experiments/`](../experiments) for ready-to-run scripts.

## What the scorer does

`Synthex.Hub.Scorer.new/1` returns a 1-arg function — a value of
type `Synthex.Scoring.t()`. Internally:

  * `cmd: "score_bit"` — chunked across the worker swarm, K candidates
    per chunk × N seeds per candidate. Master gets back
    `{:ok, %{"scores" => [...], "baseline_reward" => f}}`.
  * `cmd: "collect_states"` — chunked across the worker swarm, one
    rollout episode per seed. Master gets back
    `{:ok, %{"states" => [[float]], "n_landings" => i, "n_episodes" => i}}`.
  * Anything else hits a `:fallback` function. The default fallback
    raises a clear error — the master is intentionally Python-free.
    Override with `:fallback` if you want local execution for some
    custom command.

The master never invokes Python. You can drive synthesis from a tiny
laptop or a free-tier cloud VM; all the simulation work runs on
collaborators' machines.

## Auth

  * **Worker** routes (where chunks are pulled and results are
    submitted) are anonymous — collaborators run
    `curl -fsSL https://synthex.fit/install | sh` with no token.
  * **Master** routes (which this library hits) are gated by a
    Bearer token. Set `SYNTHEX_HUB_TOKEN`.

## Configuration

| Env var              | Default                                          | Notes                                                                                |
|----------------------|--------------------------------------------------|--------------------------------------------------------------------------------------|
| `SYNTHEX_HUB_URL`    | `https://synthex.fit/api`                        | Trailing `/` is fine either way.                                                     |
| `SYNTHEX_HUB_TOKEN`  | _(none)_                                         | Required for `Hub.Client.score_bit` and `collect_states`.                            |
| `SYNTHEX_GIT_REF`    | `main`                                           | Pins the synthex revision used by `mix.exs`. Set to a commit SHA or tag for repro.   |
| `SYNTHEX_PATH`       | _(unset → falls back to git)_                    | If set to an abs path, `mix.exs` uses a local checkout instead of pulling from git.  |
