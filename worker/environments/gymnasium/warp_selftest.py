#!/usr/bin/env python3
"""One-shot GPU self-test, run by the installer inside the worker
container right after it starts.

Confirms the worker will ACTUALLY use the GPU for real chunks instead
of silently falling back to CPU. It runs the exact same make_backend()
decision the oracle uses, at a representative batch size (so it
reproduces large-nworld failures like CUDA-graph capture or OOM), then
steps once to prove end-to-end execution on the chosen backend.

Prints a single-line verdict and exits:
    0  -> GPU (Warp) active
    1  -> CPU fallback (reason printed above by make_backend)
    2  -> setup/import error

Usage:  python3 warp_selftest.py [ENV_NAME] [NWORLD]
"""

import sys

import numpy as np

ENV = sys.argv[1] if len(sys.argv) > 1 else "HalfCheetah-warp-v5"
NWORLD = int(sys.argv[2]) if len(sys.argv) > 2 else 4096

try:
    import warp_core as core
    from warp_backends import make_backend, warp_available
except Exception as e:  # noqa: BLE001
    print(f"SELFTEST: FAIL - import error: {e}", flush=True)
    sys.exit(2)

print(
    f"SELFTEST: env={ENV} nworld={NWORLD} warp_available={warp_available()}",
    flush=True,
)

try:
    model, iqp, iqv = core.load_mj_model(ENV)
except Exception as e:  # noqa: BLE001
    print(f"SELFTEST: FAIL - could not load model {ENV}: {e}", flush=True)
    sys.exit(2)

# make_backend prints the canonical [warp-backend] verdict (and, on a
# build failure, the full traceback) to stderr itself.
b = make_backend(model, NWORLD, prefer="auto")

if b.name != "warp":
    print(
        "SELFTEST: FAIL - worker is on the CPU fallback (see the "
        "[warp-backend] line above for the reason). Real chunks will run "
        "~50x slower.",
        flush=True,
    )
    sys.exit(1)

# Prove it actually steps end-to-end on the GPU at this batch size.
try:
    spec = core.ENV_SPECS[ENV]
    qpos = np.tile(iqp, (NWORLD, 1))
    qvel = np.tile(iqv, (NWORLD, 1))
    b.set_state(qpos, qvel)
    b.set_ctrl(np.zeros((NWORLD, spec["n_action_dims"])))
    b.step(spec["frame_skip"])
    b.get_state()
except Exception as e:  # noqa: BLE001
    import traceback

    print(traceback.format_exc(), file=sys.stderr, flush=True)
    print(
        f"SELFTEST: FAIL - Warp backend built but stepping {NWORLD} worlds "
        f"raised {type(e).__name__}: {e}",
        flush=True,
    )
    sys.exit(1)

print(
    f"SELFTEST: PASS - GPU (Warp) active on {b.device}; stepped {NWORLD} "
    f"worlds of {ENV} OK.",
    flush=True,
)
sys.exit(0)
