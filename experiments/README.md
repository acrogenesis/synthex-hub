# Distributed experiments

Each `.exs` file in this directory is a self-contained master driver:
a CSHRL synthesis loop that submits its heavy candidate-scoring work to
the hub running at `synthex.fit` (or wherever `SYNTHEX_HUB_URL`
points). They use `Mix.install` so you don't need to set up an Elixir
project — just have Elixir 1.18+ on the PATH.

## Layout

```
synthex-hub/
├── server/        ← the Phoenix-ish hub at synthex.fit
├── worker/        ← the Elixir + Python image friends run
├── client/        ← Elixir lib used by everything in this dir
└── experiments/   ← you are here
    ├── run_ant_distributed.exs
    └── run_humanoid_distributed.exs
```

The dependency graph is:

```
synthex (pure, no HTTP) ──── used by ──── client
                                            │
synthex (pure, no HTTP) ──── used by ──── experiments
                                            │
                                            └── runs against ──→ server (Fly.io)
                                                                   ↑
                                                                worker (collaborators)
```

`synthex` itself never speaks HTTP. The hub-side scorer
(`Synthex.Hub.Scorer`) is implemented in `../client` and plugs into
`Synthex.Gym.Mujoco.solve/2` via the `scorer:` opt.

## Running an experiment

```sh
# 1. (Once) set the master token. Workers don't need this.
export SYNTHEX_HUB_TOKEN=<your-master-token>

# 2. (Optional) point at a non-default hub.
export SYNTHEX_HUB_URL=https://synthex.fit/api

# 3. Drive synthesis from your laptop.
cd /path/to/synthex-hub
mix run experiments/run_ant_distributed.exs
```

Each script is small enough to read top-to-bottom (~50 lines). Edit
it directly to tweak hyper-parameters — there is no separate config
file.

## Adding a new experiment

```elixir
Mix.install([
  {:synthex,            path: Path.expand("../../synthex", __DIR__)},
  {:synthex_hub_client, path: Path.expand("../client",     __DIR__)}
])

scorer = Synthex.Hub.Scorer.new(env_key: :YOUR_ENV)

Synthex.Gym.Mujoco.solve(:YOUR_ENV,
  scorer: scorer,
  ...
)
```

Three things to check off before running:

  1. The env key (`:ant`, `:humanoid`, etc) is registered in
     `synthex/lib/synthex/gym/mujoco.ex`'s `@env_configs`.
  2. The hub's worker oracle
     (`worker/environments/gymnasium/oracle_port.py`) has the env's
     gym name in its `ENV_CONFIGS` dict, with the right action shape
     and success threshold.
  3. Workers are connected. Hit `https://synthex.fit/` in a browser
     or check `Synthex.Hub.Client.public_status(...)` first.

## Local sanity check (no hub)

To make sure your master logic is correct before involving the hub,
just run the equivalent script in `synthex/experiments/` directly — it
defaults to `Synthex.Scoring.LocalPython` which forks `python3` for
each oracle call. For HalfCheetah, this finishes in minutes on a
laptop. For Ant or Humanoid it doesn't finish at all, which is exactly
why the hub exists.
