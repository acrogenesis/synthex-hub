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
  {:synthex,            path: Path.expand("../../synthex", __DIR__)},
  {:synthex_hub_client, path: Path.expand("../client",     __DIR__)}
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

  * `cmd: "score_bit"` requests are POSTed to `/api/master/batches`,
    chunked across whoever's connected, and polled until done. The
    master gets back `{:ok, %{"scores" => [...], "baseline_reward" => f}}`.
  * Every other command (`collect_states`, `validate`, ...) falls
    through to a local Python scorer (default
    `Synthex.Scoring.LocalPython`) so the master still needs
    `gymnasium` + the relevant physics backend installed locally.

This split is intentional: only `score_bit` is large enough to
benefit from distribution. Trajectory collection and validation are
fast and serial.

## Auth

  * **Worker** routes (where chunks are pulled and results are
    submitted) are anonymous — collaborators run
    `curl -fsSL https://synthex.fit/install | sh` with no token.
  * **Master** routes (which this library hits) are gated by a
    Bearer token. Set `SYNTHEX_HUB_TOKEN`.

## Configuration

| Env var              | Default                       | Notes                                |
|----------------------|-------------------------------|--------------------------------------|
| `SYNTHEX_HUB_URL`    | `https://synthex.fit/api`     | Trailing `/` is fine either way.     |
| `SYNTHEX_HUB_TOKEN`  | _(none)_                      | Required for `Hub.Client.score_bit`. |
| `SYNTHEX_PATH`       | `../../synthex`               | Path to synthex checkout, used by    |
|                      |                               | this lib's `mix.exs` deps. Override  |
|                      |                               | if your layout is different.         |
