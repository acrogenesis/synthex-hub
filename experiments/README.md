# Distributed experiments

Each `.exs` file in this directory is a self-contained master driver:
a thin CSHRL synthesis coordinator that submits **every** Python /
Gymnasium / MuJoCo call to the hub running at `synthex.fit` (or
wherever `SYNTHEX_HUB_URL` points). They use `Mix.install` so you don't
need to set up an Elixir project — just have Elixir 1.18+ on the PATH.

> **Master is Python-free.** Both `score_bit` and `collect_states` are
> distributed; the master only runs the CEGAR loop in pure Elixir. You
> can drive a Humanoid synthesis from a small laptop or even a free Fly
> machine. All the MuJoCo work happens on the worker swarm.

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
  {:synthex,
   git: "https://github.com/doctorcorral/synthex.git",
   ref: System.get_env("SYNTHEX_GIT_REF", "main")},
  {:synthex_hub_client,
   git: "https://github.com/doctorcorral/synthex-hub.git",
   subdir: "client",
   ref: System.get_env("SYNTHEX_HUB_GIT_REF", "main")}
])

scorer = Synthex.Hub.Scorer.new(env_key: :YOUR_ENV)

Synthex.Gym.Mujoco.solve(:YOUR_ENV,
  scorer: scorer,
  ...
)
```

Both deps are pulled from public GitHub, so collaborators don't need a
local checkout of either project to run an experiment — just the
`.exs` file.

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
clone `synthex` and run an experiment from
[doctorcorral/synthex/experiments](https://github.com/doctorcorral/synthex/tree/main/experiments)
directly — it defaults to `Synthex.Scoring.LocalPython` which forks
`python3` for each oracle call. For HalfCheetah, this finishes in
minutes on a laptop. For Ant or Humanoid it doesn't finish at all,
which is exactly why the hub exists.

## Local development against an unpublished synthex branch

Set `SYNTHEX_PATH` to a checkout and the client + experiments will
prefer that path over the public git tag:

```sh
export SYNTHEX_PATH=/abs/path/to/synthex   # picked up by client/mix.exs
mix run experiments/run_ant_distributed.exs
```

(This only works for `mix run` against `client/`. The Mix.install
scripts always use git refs; pin a specific commit via
`SYNTHEX_GIT_REF=<sha>`.)
