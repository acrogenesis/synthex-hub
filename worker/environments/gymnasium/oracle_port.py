#!/usr/bin/env python3
"""
Persistent Python oracle for the Synthex Hub worker.

Reads one JSON job per line on stdin, writes one JSON response per
line on stdout. ALWAYS produces a response containing the original
`job_id`, even on errors, so the Elixir port never hangs waiting.

Supported commands:
  - score_bit      (default; binary-weighted continuous control)

Future commands map onto the same protocol; just add a dispatch case.
"""

import json
import logging
import os
import sys
import traceback

import numpy as np
import gymnasium as gym

LOG_PATH = os.environ.get("ORACLE_LOG", "/tmp/synthex_hub_worker.log")
logging.basicConfig(
    filename=LOG_PATH,
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("oracle")
log.info("oracle_port starting (pid=%d)", os.getpid())

ENV_CONFIGS = {
    "InvertedPendulum-v5": {
        "n_action_dims": 1, "action_low": -3.0, "action_high": 3.0,
        "max_steps": 1000, "success_threshold": 950,
    },
    "Swimmer-v5": {
        "n_action_dims": 2, "action_low": -1.0, "action_high": 1.0,
        "max_steps": 1000, "success_threshold": 50,
    },
    "Hopper-v5": {
        "n_action_dims": 3, "action_low": -1.0, "action_high": 1.0,
        "max_steps": 1000, "success_threshold": 500,
        "env_kwargs": {"healthy_reward": 0.0},
    },
    "HalfCheetah-v5": {
        "n_action_dims": 6, "action_low": -1.0, "action_high": 1.0,
        "max_steps": 1000, "success_threshold": 1000,
    },
    "Walker2d-v5": {
        "n_action_dims": 6, "action_low": -1.0, "action_high": 1.0,
        "max_steps": 1000, "success_threshold": 500,
    },
    "Ant-v5": {
        "n_action_dims": 8, "action_low": -1.0, "action_high": 1.0,
        "max_steps": 1000, "success_threshold": 1000,
    },
    "Humanoid-v5": {
        "n_action_dims": 17, "action_low": -0.4, "action_high": 0.4,
        "max_steps": 1000, "success_threshold": 1000,
    },
}


# ── Predicate evaluation ────────────────────────────────────────────


def eval_feature(feat, state):
    kind = feat[0]
    if kind == "axis":
        return state[feat[1]] < feat[2]
    if kind == "diag":
        return feat[3] * state[feat[1]] + state[feat[2]] < 0
    if kind == "sq_diag":
        return feat[3] * state[feat[1]] ** 2 + state[feat[2]] < 0
    if kind == "prod":
        return state[feat[1]] * state[feat[2]] < feat[3]
    if kind == "tridiag":
        return (
            feat[4] * state[feat[1]]
            + feat[5] * state[feat[2]]
            + state[feat[3]]
            < 0
        )
    return False


def eval_pred(pred, state):
    if pred is None or pred == "truep":
        return True
    if pred == "falsep":
        return False
    kind = pred[0]
    if kind == "feat":
        return eval_feature(pred[1], state)
    if kind == "not":
        return not eval_pred(pred[1], state)
    if kind == "and":
        return eval_pred(pred[1], state) and eval_pred(pred[2], state)
    if kind == "or":
        return eval_pred(pred[1], state) or eval_pred(pred[2], state)
    return False


# ── score_bit command ───────────────────────────────────────────────


def bit_policy_action(bit_preds, obs, cfg, bits_per_dim):
    bits = [1 if eval_pred(p, obs) else 0 for p in bit_preds]
    weights = [2 ** i for i in range(bits_per_dim)]
    max_sum = sum(weights)
    n = cfg["n_action_dims"]
    lo, hi = cfg["action_low"], cfg["action_high"]
    actions = np.zeros(n)
    for d in range(n):
        s = sum(weights[i] * bits[d * bits_per_dim + i] for i in range(bits_per_dim))
        actions[d] = lo + (hi - lo) * s / max_sum
    return actions


def score_bit_candidate(env_name, candidate, bit_preds, target_bit, seeds, max_steps, bits_per_dim):
    cfg = ENV_CONFIGS[env_name]
    test_preds = list(bit_preds)
    test_preds[target_bit] = candidate
    total = 0.0
    successes = 0
    env_kwargs = cfg.get("env_kwargs", {})

    for seed in seeds:
        env = gym.make(env_name, **env_kwargs)
        try:
            obs, _ = env.reset(seed=int(seed))
            ep_r = 0.0
            for _ in range(max_steps):
                action = bit_policy_action(test_preds, obs.tolist(), cfg, bits_per_dim)
                obs, r, term, trunc, _ = env.step(action)
                ep_r += float(r)
                if term or trunc:
                    break
            total += ep_r
            if ep_r > cfg["success_threshold"]:
                successes += 1
        finally:
            env.close()

    return {"reward": total, "landings": successes}


# ── dispatch ────────────────────────────────────────────────────────


def handle_score_bit(job):
    env_name = job["env_name"]
    if env_name not in ENV_CONFIGS:
        raise ValueError(f"unknown env_name: {env_name}; known={list(ENV_CONFIGS)}")

    candidates = job["candidates"]
    bit_preds = job["bit_predicates"]
    target_bit = int(job["target_bit"])
    seeds = job.get("seeds", [0])
    max_steps = int(job.get("max_steps", 1000))
    bits_per_dim = int(job.get("bits_per_dim", 3))

    results = []
    for i, cand in enumerate(candidates):
        try:
            r = score_bit_candidate(
                env_name, cand, bit_preds, target_bit, seeds, max_steps, bits_per_dim
            )
            r["idx"] = i
        except Exception as e:
            log.exception("candidate %d failed", i)
            r = {"idx": i, "error": f"{type(e).__name__}: {e}"}
        results.append(r)
    return results


COMMANDS = {
    "score_bit": handle_score_bit,
}


def handle(job):
    cmd = job.get("cmd", "score_bit")
    handler = COMMANDS.get(cmd)
    if handler is None:
        raise ValueError(f"unknown cmd: {cmd}; known={list(COMMANDS)}")
    return handler(job)


def reply(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        job_id = None
        try:
            job = json.loads(line)
            job_id = job.get("job_id")
            results = handle(job)
            reply({"job_id": job_id, "results": results})
        except Exception as e:
            tb = traceback.format_exc()
            log.error("job %s failed: %s\n%s", job_id, e, tb)
            reply(
                {
                    "job_id": job_id,
                    "error": f"{type(e).__name__}: {e}",
                }
            )

    log.info("oracle_port stdin closed; exiting")


if __name__ == "__main__":
    main()
