# Experiments

A Synthex Hub experiment is a CEGAR synthesis run. It lives on the hub
server as an `experiments` row, owned by an Oban-supervised master
loop that checkpoints to Postgres after every accepted bit. Your
laptop only submits the experiment; the hub does everything else.

```
synthex-hub/
├── server/                ← the hub at synthex.fit (Oban-master runs here)
├── worker/                ← the Elixir + Python image friends run
├── client/                ← Elixir lib for talking to the hub
└── experiments/           ← you are here
    ├── configs/           ← JSON config templates per env
    │   ├── ant.json
    │   ├── humanoid.json
    │   └── half_cheetah.json
    └── submit.sh          ← one-line submission CLI
```

## Submitting an experiment

```sh
# 1. (Once) set the master token. Workers don't need this.
export SYNTHEX_HUB_TOKEN=<your-master-token>

# 2. Submit. Returns the experiment id.
experiments/submit.sh experiments/configs/ant.json
```

That's it. The hub:

  1. Validates the config and inserts an `experiments` row.
  2. Enqueues a `Server.Workers.ExperimentBootstrap` Oban job.
  3. The bootstrap job computes baseline reward and enqueues the
     first `ExperimentCegarIter`.
  4. Each iter job runs every bit in shuffled order, persisting
     `predicates` + `bit_progress` after every accepted bit. On
     crash, the retry resumes from `bit_progress` — no work lost.
  5. When all `cegar_rounds × max_iters` iters finish, the run
     completes and emits a `system_event`.

Monitor at <https://synthex.fit>. Each env card shows the current
CEGAR coordinate (round/iter), bits accepted, running best reward,
and Oban-master health (red banner if the master heartbeats
stop). The incident banner surfaces any `level=warn|error`
`system_event` from the last 24h.

## Cancelling

```sh
curl -X POST -H "Authorization: Bearer $SYNTHEX_HUB_TOKEN" \
     https://synthex.fit/api/master/experiments/<id>/cancel
```

The `OrphanReaper` cron will cancel any in-flight chunks for the
experiment within 2 minutes.

## Config schema

Top-level:

```json
{
  "env_key":  "ant",          // atom name in Synthex.Gym.Mujoco.@env_configs
  "env_name": "Ant-v5",       // display label; cosmetic
  "config":   { ... }         // pass-through to Synthex.Gym.Mujoco.init_context/2
}
```

Inside `config`, every option understood by `Synthex.Gym.Mujoco.init_context/2`
is accepted (all optional, with sensible defaults):

| key                          | default | notes                                                        |
| ---------------------------- | ------- | ------------------------------------------------------------ |
| `bits_per_dim`               | 3       | 1–3 typically; 3 ⇒ 8 levels per action dim                   |
| `depth`                      | 1       | 0: atoms only, 1: + best-K and/or                            |
| `max_coeff`                  | 5       | coefficient bound for diag/sq_diag features                  |
| `feature_types`              | all     | list of `axis`, `diag`, `sq_diag`, `prod`, `tridiag`         |
| `tridiag_max_coeff`          | 2       | tighter bound for the cubic class                            |
| `tridiag_dims`               | `null`  | `[lo, hi]` to restrict tridiag to dims `lo..hi`              |
| `n_episodes`                 | 30      | scoring episodes per candidate                               |
| `top_k`                      | 20      | depth-1 fan-out                                              |
| `max_iters`                  | 5       | inner iterations per CEGAR round                             |
| `cegar_rounds`               | 3       | outer rounds; each re-collects states                        |
| `max_steps`                  | 1000    | per-episode step cap                                         |
| `chunk_size`                 | 100     | candidates per HTTP chunk to workers                         |
| `collect_states_chunk_size`  | 4       | seeds per `collect_states` chunk                             |
| `state_stride`               | 10      | subsample factor on per-step state trajectories              |
| `poll_interval_ms`           | 5000    | hub-internal master poll interval                            |

## Adding a new env

Three things to check off:

  1. The env key (`:my_env`) is registered in
     [`synthex/lib/synthex/gym/mujoco.ex`](https://github.com/doctorcorral/synthex/blob/main/lib/synthex/gym/mujoco.ex)'s
     `@env_configs`.
  2. The hub's worker oracle
     ([`worker/environments/gymnasium/oracle_port.py`](../worker/environments/gymnasium/oracle_port.py))
     has the env's gym name in its `ENV_CONFIGS` dict, with the right
     action shape and success threshold.
  3. Add an `experiments/configs/my_env.json` template.

Workers don't need to be redeployed unless you changed the oracle.

## Why the master runs server-side now

Previously each experiment was a `.exs` script using `Mix.install` to
pull `synthex` and `synthex_hub_client`, then calling
`Synthex.Gym.Mujoco.solve/2` against the hub. Several real failure
modes followed:

  * Laptop closed lid mid-CEGAR → master process dies → batches
    orphaned → workers spin compute on a loop nobody is reading from.
  * Master crashes were silent. The landing page reported "healthy"
    because workers were still processing chunks even though no one
    was going to consume the results.
  * Resume meant restarting from scratch — accepted bits got
    re-validated, days of compute lost.

The Oban-master refactor fixes all three: experiments are supervised
processes on the hub, checkpoints land in Postgres after every
accepted bit, and any Oban job that exhausts its retries writes an
`error` `system_event` that the landing page banners immediately.
