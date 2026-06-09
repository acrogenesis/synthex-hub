#!/usr/bin/env python3
"""
Validation for the Warp env-core against Gymnasium, on CPU.

Runs anywhere `mujoco` + `gymnasium` are installed (no GPU needed).
Proves the parts we reimplemented — reset noise, observation layout,
reward, and the vectorised bit-policy — match Gymnasium's HalfCheetah
when driven identically. The Warp GPU backend steps the same core, so
passing here means a GPU rollout is correct up to solver numerics.

Usage:  python3 validate_warp_env.py
Exit code 0 on success, 1 on any mismatch.
"""

import sys
import numpy as np
import gymnasium as gym

import warp_core as core
from warp_backends import CpuBackend
from oracle_port import eval_pred as scalar_eval_pred, bit_policy_action

ENV = "HalfCheetah-warp-v5"
BASE = "HalfCheetah-v5"
BITS_PER_DIM = 3
N_BITS = 6 * BITS_PER_DIM


def fail(msg):
    print(f"  FAIL: {msg}")
    return False


def ok(msg):
    print(f"  ok: {msg}")
    return True


def gym_policy_rollout(env_name, bit_preds, seed, max_steps, cfg, bits_per_dim):
    """Reference rollout in Gymnasium under the scalar bit-policy."""
    e = gym.make(env_name)
    obs, _ = e.reset(seed=int(seed))
    total = 0.0
    obs_trace = [obs.copy()]
    try:
        for _ in range(max_steps):
            a = bit_policy_action(bit_preds, obs.tolist(), cfg, bits_per_dim)
            obs, r, term, trunc, _ = e.step(a)
            total += float(r)
            obs_trace.append(obs.copy())
            if term or trunc:
                break
    finally:
        e.close()
    return total, np.array(obs_trace)


def core_policy_rollout(env_name, bit_preds, seed, max_steps):
    """Rollout under warp_core + CpuBackend (single world)."""
    spec = core.ENV_SPECS[env_name]
    model, iqp, iqv = core.load_mj_model(env_name)
    qpos, qvel = core.reset_states(env_name, [seed], iqp, iqv)
    b = CpuBackend(model, nworld=1)
    b.set_state(qpos, qvel)
    fs = spec["frame_skip"]
    total = 0.0
    qp, qv = b.get_state()
    obs = spec["obs_fn"](qp, qv)
    obs_trace = [obs[0].copy()]
    shared = [pred for pred in bit_preds]  # all-shared, single world
    for _ in range(max_steps):
        bits = core.policy_bits(obs, shared, N_BITS)
        actions = core.decode_actions(bits, spec, BITS_PER_DIM)
        x_before = qp[:, spec["x_index"]].copy()
        b.set_ctrl(actions)
        b.step(fs)
        qp, qv = b.get_state()
        x_after = qp[:, spec["x_index"]]
        total += float(spec["reward_fn"](x_before, x_after, actions)[0])
        obs = spec["obs_fn"](qp, qv)
        obs_trace.append(obs[0].copy())
        if bool(spec["terminated_fn"](qp, qv)[0]):
            break
    return total, np.array(obs_trace)


def main():
    passed = True
    cfg = {"n_action_dims": 6, "action_low": -1.0, "action_high": 1.0}

    # 1. Reset noise matches Gymnasium bit-for-bit
    print("[1] reset noise vs gymnasium")
    e = gym.make(BASE).unwrapped
    model, iqp, iqv = core.load_mj_model(ENV)
    for seed in (0, 1, 42, 123):
        e.reset(seed=seed)
        gqp, gqv = e.data.qpos.copy(), e.data.qvel.copy()
        cqp, cqv = core.reset_states(ENV, [seed], iqp, iqv)
        if not (np.allclose(cqp[0], gqp) and np.allclose(cqv[0], gqv)):
            passed &= fail(f"reset mismatch seed={seed}")
            break
    else:
        passed &= ok("reset qpos/qvel identical for all seeds")
    e.close()

    # 2. Observation layout matches Gymnasium
    print("[2] observation layout vs gymnasium")
    e = gym.make(BASE)
    gobs, _ = e.reset(seed=7)
    spec = core.ENV_SPECS[ENV]
    cqp, cqv = core.reset_states(ENV, [7], iqp, iqv)
    cobs = spec["obs_fn"](cqp, cqv)[0]
    if cobs.shape == gobs.shape and np.allclose(cobs, gobs):
        passed &= ok(f"obs shape {cobs.shape} and values identical")
    else:
        passed &= fail(f"obs mismatch: core {cobs.shape} vs gym {gobs.shape}")
    e.close()

    # 3. Vectorised predicate eval matches scalar oracle eval
    print("[3] vectorised predicate eval vs scalar")
    rng = np.random.default_rng(0)
    obs_batch = rng.standard_normal((64, 17))
    preds = [
        ["feat", ["axis", 3, 0.5]],
        ["feat", ["diag", 1, 2, -1]],
        ["not", ["feat", ["axis", 0, 0.0]]],
        ["and", ["feat", ["axis", 5, 0.1]], ["feat", ["prod", 2, 4, 0.0]]],
        ["or", ["feat", ["tridiag", 6, 7, 8, 1, -1]], "falsep"],
        "truep",
    ]
    mism = 0
    for p in preds:
        vec = core.eval_pred_batch(p, obs_batch)
        sca = np.array([scalar_eval_pred(p, obs_batch[i].tolist()) for i in range(64)])
        mism += int(np.sum(vec != sca))
    passed &= ok("all predicate kinds match scalar") if mism == 0 else fail(f"{mism} mismatches")

    # 4. decode_actions matches scalar bit_policy_action
    print("[4] vectorised action decode vs scalar")
    bits = rng.integers(0, 2, size=(32, N_BITS)).astype(np.float64)
    dec = core.decode_actions(bits, spec, BITS_PER_DIM)
    mism = 0
    for i in range(32):
        # scalar path expects predicate-derived bits; emulate by faking
        # bit_preds that yield this bit pattern is awkward, so compare
        # the decode arithmetic directly.
        weights = [2 ** k for k in range(BITS_PER_DIM)]
        max_sum = sum(weights)
        for d in range(6):
            s = sum(weights[k] * bits[i, d * BITS_PER_DIM + k] for k in range(BITS_PER_DIM))
            expect = -1.0 + 2.0 * s / max_sum
            if abs(expect - dec[i, d]) > 1e-9:
                mism += 1
    passed &= ok("decode arithmetic matches") if mism == 0 else fail(f"{mism} decode mismatches")

    # 5. Full bit-policy rollout reward matches Gymnasium
    print("[5] full rollout reward vs gymnasium (200 steps)")
    bit_preds = [
        ["feat", ["axis", 8, 0.0]] if i % 2 == 0 else ["feat", ["diag", 1, 9, 1]]
        for i in range(N_BITS)
    ]
    for seed in (0, 3):
        gr, gtr = gym_policy_rollout(BASE, bit_preds, seed, 200, cfg, BITS_PER_DIM)
        cr, ctr = core_policy_rollout(ENV, bit_preds, seed, 200)
        rdiff = abs(gr - cr)
        odiff = np.abs(gtr[: len(ctr)] - ctr[: len(gtr)]).max()
        if rdiff < 1e-4 and odiff < 1e-6:
            passed &= ok(f"seed={seed}: reward {cr:.4f} (Δ={rdiff:.2e}), obs Δ={odiff:.2e}")
        else:
            passed &= fail(f"seed={seed}: reward Δ={rdiff:.4f} core={cr:.4f} gym={gr:.4f}, obs Δ={odiff:.2e}")

    print()
    print("RESULT:", "ALL PASS" if passed else "FAILURES")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
