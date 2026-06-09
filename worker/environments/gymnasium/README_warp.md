# MuJoCo-Warp worker (GPU adapter)

This directory contains a GPU-batched physics adapter for the Synthex
swarm, alongside the original CPU oracle (`oracle_port.py`).

| file | role |
|------|------|
| `oracle_port.py` | original CPU oracle: `gym.make()` + Python step loop, one rollout at a time. The `mujoco` adapter. |
| `warp_core.py` | backend-agnostic env core for the `*-warp-v5` envs: seeded reset, observation, reward, termination, and the vectorised bit-policy. No physics. |
| `warp_backends.py` | two stepping backends behind one interface — `CpuBackend` (plain `mujoco`, runs anywhere) and `WarpBackend` (`mujoco_warp`, batched on an NVIDIA GPU). |
| `oracle_warp_port.py` | the `mujoco_warp` adapter: same stdin/stdout JSON protocol as `oracle_port.py`, but a whole chunk's `(candidate, seed)` rollouts become one batch of `nworld` worlds. Delegates non-warp envs to `oracle_port`, so a GPU worker is a strict superset. |
| `validate_warp_env.py` | CPU validation: proves the env core matches Gymnasium bit-for-bit. |
| `test_warp_oracle_parity.py` | CPU validation: proves the batched oracle matches `oracle_port` bit-for-bit. |

## Design

These are **distinct environments** (`HalfCheetah-warp-v5`, …), not a
re-implementation of the Gymnasium lineages. The reward *structure* is
faithful — in fact the reset RNG, observation, reward, and policy are
reproduced bit-for-bit on CPU — but Warp and Gymnasium lineages keep
separate `env_name`s and separate policy lineages on the hub. No
attempt is made to unify or compare them.

Execution model: physics stepping runs batched on the GPU
(`mujoco_warp`, the expensive contact-solving part); the binary
bit-policy stays a cheap vectorised-numpy step on the host (predicate
evaluation is trivial vs. contact solving). One GPU world per rollout.

## Validate on any machine (no GPU)

```bash
cd worker/environments/gymnasium
python3 validate_warp_env.py          # env core vs Gymnasium
python3 test_warp_oracle_parity.py    # batched oracle vs oracle_port
```

Both should print `PASS` / `ALL PASS`. These use the CPU backend, so
they need only `mujoco`, `gymnasium`, `numpy`.

## Run a GPU (Warp) worker

Requires an NVIDIA GPU + CUDA. Install the GPU deps on top of the
worker's usual Python env:

```bash
pip install mujoco gymnasium numpy
pip install warp-lang mujoco-warp        # CUDA-capable GPU required
```

Sanity-check the GPU is visible to Warp and that a batched step runs:

```bash
python3 - <<'PY'
import warp as wp; wp.init()
print("CUDA devices:", [d for d in wp.get_devices() if d.is_cuda])
from warp_backends import warp_available
print("warp_available:", warp_available())
PY
```

Then point the worker at the Warp oracle and advertise the capability.
The capability list is **preference-ordered**: `mujoco_warp` first means
"prefer Warp chunks, fall back to plain MuJoCo when none are queued".

```bash
export ORACLE_SCRIPT="$PWD/oracle_warp_port.py"
export WORKER_CAPABILITIES="mujoco_warp,mujoco"   # prefer warp, fall back
export ORACLE_BACKEND="warp"                       # auto|cpu|warp (default auto)
export ORACLE_WARP_GRAPH="1"                        # CUDA-graph capture (default on)
export WORKER_NAME="your-gpu-box"
export API_TOKEN="…"
export SERVER_URL="https://synthex.fit/api"

# from worker/ :
mix run --no-halt        # or your usual worker start command / Docker entrypoint
```

If you want a GPU box that ONLY ever runs Warp work (never falls back
to CPU MuJoCo), advertise `WORKER_CAPABILITIES="mujoco_warp"` instead.

## Submit a Warp experiment

A Warp experiment is just a normal experiment with a distinct
`env_name` and an `adapter` tag in its config:

```json
{
  "env_name": "HalfCheetah-warp-v5",
  "env_key": "half_cheetah",
  "adapter": "mujoco_warp",
  "...": "the rest of the usual HalfCheetah config"
}
```

The hub stamps `adapter: "mujoco_warp"` onto every chunk of that
experiment, and `claim_chunk` routes those chunks only to workers whose
capabilities include `mujoco_warp`, preferring them on GPU workers.

## Adding more Warp environments

Add an entry to `ENV_SPECS` in `warp_core.py` (base Gymnasium env id,
`frame_skip`, action bounds, `obs_fn`, `reward_fn`, `terminated_fn`,
`success_threshold`, `reset_noise_scale`), then re-run
`validate_warp_env.py` against the new env to confirm the reward/obs
math matches Gymnasium before trusting GPU results. Envs with
early-termination (Ant/Hopper/Walker/Humanoid) need a real
`terminated_fn`; HalfCheetah/Swimmer never terminate.
```
