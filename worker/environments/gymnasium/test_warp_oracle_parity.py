import os
os.environ["ORACLE_BACKEND"] = "cpu"
import numpy as np
import oracle_warp_port as warp
import oracle_port as orig

BITS_PER_DIM = 3
N_BITS = 6 * BITS_PER_DIM

bit_preds = [
    (["feat", ["axis", 8, 0.0]] if i % 3 == 0 else
     ["feat", ["diag", 1, 9, 1]] if i % 3 == 1 else "truep")
    for i in range(N_BITS)
]
candidates = [
    ["feat", ["axis", 0, 0.0]],
    ["not", ["feat", ["axis", 3, 0.2]]],
    "falsep",
]
target_bit = 2
seeds = [0, 1, 2]
max_steps = 150

warp_job = {
    "cmd": "score_bit", "env_name": "HalfCheetah-warp-v5",
    "candidates": candidates, "bit_predicates": bit_preds,
    "target_bit": target_bit, "seeds": seeds,
    "max_steps": max_steps, "bits_per_dim": BITS_PER_DIM,
}
orig_job = dict(warp_job, env_name="HalfCheetah-v5")

wr = warp.handle_score_bit(warp_job)
orr = orig.handle_score_bit(orig_job)

print("score_bit: candidate | warp_reward | orig_reward | diff | warp_land | orig_land")
allok = True
for w, o in zip(wr, orr):
    d = abs(w["reward"] - o["reward"])
    allok &= d < 1e-6 and w["landings"] == o["landings"]
    print(f"  {w['idx']} | {w['reward']:.5f} | {o['reward']:.5f} | {d:.2e} | {w['landings']} | {o['landings']}")
print("score_bit MATCH:", allok)

# collect_states
cs_job = {
    "cmd": "collect_states", "env_name": "HalfCheetah-warp-v5",
    "candidates": seeds, "bit_predicates": bit_preds,
    "max_steps": max_steps, "bits_per_dim": BITS_PER_DIM, "state_stride": 10,
}
cs_orig = dict(cs_job, env_name="HalfCheetah-v5")
cw = warp.handle_collect_states(cs_job)
co = orig.handle_collect_states(cs_orig)
print("\ncollect_states: seed | warp_r | orig_r | diff | warp_nstates | orig_nstates | states_match")
csok = True
for w, o in zip(cw, co):
    d = abs(w["reward"] - o["reward"])
    sm = np.allclose(np.array(w["states"]), np.array(o["states"]), atol=1e-6) if len(w["states"]) == len(o["states"]) else False
    csok &= d < 1e-6 and sm
    print(f"  {w['seed']} | {w['reward']:.5f} | {o['reward']:.5f} | {d:.2e} | {len(w['states'])} | {len(o['states'])} | {sm}")
print("collect_states MATCH:", csok)

print("\nOVERALL:", "PASS" if (allok and csok) else "FAIL")
