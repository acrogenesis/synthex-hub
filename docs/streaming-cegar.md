# Streaming CEGAR Architecture

**Status**: Design — pending implementation in three sequenced layers.
**Owners**: server (Synthex Hub), Synthex (CEGAR engine), workers (rollout
adapters).
**Theoretical grounding**: `CSHRLSynthesis` §10 (Online Synthesis,
`refine-commutes`, `replay-redundant`) and `HybridSynthesis` §11.1
(Binary-Weighted Decomposition — per-bit independence).

## Problem statement

The current Oban-master CEGAR loop is correct but serial. For each
CEGAR iter, the master enters a `Enum.reduce(bit_shuffle, …)` loop that
optimizes one bit at a time. Each `optimize_bit` call issues a single
Synthex batch and *blocks* until that batch fully drains. Workers see
work only inside that window; the dashboard sees an event only when
the bit is accepted (potentially hours later).

The user-visible symptom: with a 1–6 core swarm, the dashboard reports
`bits=0/N accepted=0` for many hours, with no incremental evidence of
progress. The fundamental mismatch is that the implementation is
serial coordinate descent on an inherently parallel and streaming
problem family.

## Goals

1. **Continuous feed**: workers contribute every few seconds, not
   every few hours.
2. **Stable monotonicity**: every committed change strictly improves
   the policy (or at worst leaves it unchanged on the relevant bit).
   Failure of a committed contribution must not regress prior state.
3. **Algorithmic fidelity to CSHRL**: stay inside the
   binary-weighted-coordinate-descent framing of HybridSynthesis §11.
   The theory already supports streaming; we implement what the theory
   describes.
4. **Architectural separation**: server coordinates and gates,
   Synthex drives the search math, workers wrap rollouts. No fat
   workers, no fat server.

## Non-goals

- Reducing the search space (`top_k`, `max_coeff`, feature pool size).
  These are the knobs that *let* large swarms unlock harder envs;
  shrinking them is the opposite of the goal.
- Replacing CEGAR/coordinate-descent with an unrelated algorithm
  family (evolutionary, population-based RL). CSHRL's own theorems
  give us what we need.

## Theoretical anchor

Two results from `CSHRLSynthesis` §10:

- **`refine-commutes`**: for any two observations `o₁ o₂`, refining
  the version space with `o₁` then `o₂` is identical to refining with
  `o₂` then `o₁`. Observation arrival order is irrelevant.
- **`replay-redundant`**: re-applying an already-incorporated
  observation is a no-op on the version space.

And from `HybridSynthesis` §11.1: each of the `d × b` bits is "an
independent 2-action CSHRL problem". Bit-level coordinate descent is
the synthesis algorithm; the per-bit subproblems are independently
scorable against a frozen baseline policy.

Together: a streaming swarm contributing independent
`(bit_idx, candidate, mean_reward)` observations in any order, with
any duplication, converges to the same version space as a serial
optimizer — provided each commit gate validates against the policy
version under which the candidate was evaluated.

## Architecture overview

Three actors:

```
              ┌────────────────────────────────────────────┐
              │  Server (Oban + DB)                        │
              │                                            │
              │   ExperimentController (Oban)              │
              │     - owns global policy_version           │
              │     - owns per-bit candidate pool          │
              │     - applies commit gate (monotone)       │
              │                                            │
              │   chunks queue (Oban) + batches table      │
              │     - incremental aggregates per chunk     │
              │                                            │
              └────────────────────────────────────────────┘
                       ▲                       │
                       │ HTTP                  │ HTTP
                       │ (results)             │ (tasks)
                       │                       ▼
              ┌────────────────────────────────────────────┐
              │  Worker (one of N)                         │
              │     - pulls task (bit_idx, candidate, v)   │
              │     - constructs policy = base @ bit_idx   │
              │       ← candidate                          │
              │     - runs n_episodes in MuJoCo            │
              │     - returns (mean, n, v)                 │
              └────────────────────────────────────────────┘
```

The master Oban job (`ExperimentController`) does **not** own a
synchronous reduce. It owns three asynchronous concerns:

- Pool maintenance: keep enough live `(bit_idx, candidate, v)` tasks
  in flight that the swarm is saturated.
- Commit gate: react to incoming task results, apply the monotonicity
  rules, update the global policy.
- CEGAR transitions: when no candidate has improved any bit for a
  saturation window, re-collect states under the current policy,
  rebuild features, regenerate the candidate pool.

Synthex provides the math primitives unchanged:
`collect_states`, `build_features`, `optimize_bit` candidate
enumeration. The Elixir glue inside `Synthex.Gym.Mujoco.solve` — the
sequential `Enum.reduce` — is what we replace.

## Layer 1 — Streaming aggregation (no algorithmic change)

**Goal**: make a chunk's contribution visible to the dashboard the
moment it lands, not at batch close. Reduce chunk size to make this
granularity useful.

### Changes

1. `chunk_size` default 100 → 10 *candidates* (each candidate is still
   evaluated on `n_episodes` episodes) in `experiments/configs/*.json`
   and the server fallback. This brings per-chunk wall-clock down from
   ~5 min (3000 episodes) to ~30 s (300 episodes) at typical
   `n_episodes=30`, which is the granularity the dashboard needs.
2. `Server.Queue.submit_chunk_result/2` (today: appends to
   `batches.results`) becomes incremental: it atomically updates the
   batch row's running aggregates `(n_episodes_completed, sum_reward,
   sum_sq_reward, best_so_far_reward, best_candidate)`. The detailed
   per-episode `results` array continues to grow but is no longer
   what the dashboard reads.
3. New `Server.AggregateBroker` GenServer (sibling of
   `Server.MetricsBroker`) that snapshots batch aggregates per second
   and fan-outs to SSE subscribers.
4. New SSE route `GET /api/public-status/stream/aggregates` emitting
   `event: aggregate\ndata: {experiment_id, bit_idx, n, mean, best,
    candidates_per_min}` lines.
5. Dashboard: each experiment card gets a per-bit live strip
   underneath the existing "bits 0/24" row, showing "current bit:
   325 candidates evaluated · best so far: r=42.1 · 18 cand/min".

### Properties preserved

- Master loop unchanged. CEGAR iter still runs sequentially through
  bits; user sees per-chunk progress within the current
  `optimize_bit` window. Batch close behavior unchanged.
- No new failure modes; the only DB write per chunk that didn't
  already exist is an `UPDATE batches SET n_episodes_completed = …`.

### Risks / mitigations

- Increased DB write rate. Smaller chunks → more `submit` calls. With
  current production load (1–10 workers, ~10 chunks/sec at most) this
  is negligible; revisit at 1000 workers.
- SSE consumers: bounded by browser tabs on the landing page. Use
  same connection-cap pattern as `MetricsBroker`.

## Layer 2 — Parallel-bit dispatch (Jacobi coordinate descent)

**Goal**: stop serializing across bits within an iter. Dispatch all
N bits' candidate batches concurrently against the same frozen
baseline, then apply the accept rule at iter end.

### Changes

1. `Server.Workers.ExperimentCegarIter.do_iter/1` is rewritten:
   - `collect_states` + `build_features` unchanged.
   - For each `bit_idx` in `shuffle`, *concurrently* spawn a Synthex
     candidate batch (`Task.async_stream`, one Scorer call per bit,
     all against the same `preds` baseline).
   - As batches complete, candidates' aggregates are evaluated;
     each bit's best candidate (or `:no_improvement`) is recorded.
   - At iter end: compose `v_{i+1}` by applying all accepted bit
     deltas to `v_i`. Single checkpoint.

2. `Synthex.Hub.Scorer.dispatch/2` may need a per-bit batch grouping
   variant; today it batches one candidate set per call which already
   parallelizes across candidates inside a bit. The change is to
   parallelize *across bits within the iter*.

### Properties preserved

- Each bit's candidate evaluation is still against the same
  baseline within an iter (Jacobi semantics). The CEGAR per-iter
  contract — accept at most one delta per bit per iter — is
  unchanged.
- `bit_progress` checkpoint per accepted bit becomes a per-iter
  batch checkpoint; resume semantics adapt accordingly (idempotent
  by `(experiment_id, cegar_iter, iter)` keying).

### Risks / mitigations

- 24× → 51× swarm pressure inside a single iter. For a 1-core swarm
  this is a no-op; for a many-core swarm it's the whole point.
- Memory: in-flight per-bit aggregates need bounded retention.
  Bounded by `n_bits × max_candidates_per_bit`, typically <10 MB.

## Layer 3 — Streaming commit with versioned validation

**Goal**: remove the iter barrier entirely. Workers continuously
pull tasks; server continuously commits improvements; CEGAR
transitions become opportunistic.

### Schema changes

```
ALTER TABLE experiments ADD COLUMN policy_version integer NOT NULL DEFAULT 0;

CREATE TABLE policy_versions (
  id              bigserial PRIMARY KEY,
  experiment_id   uuid NOT NULL REFERENCES experiments(id),
  version         integer NOT NULL,
  predicates      jsonb NOT NULL,
  bit_idx         integer NOT NULL,        -- which bit flipped
  prev_reward     double precision,
  new_reward      double precision,
  committed_at    timestamptz NOT NULL DEFAULT now(),
  worker_id       uuid REFERENCES workers(id)
);
CREATE UNIQUE INDEX ON policy_versions (experiment_id, version);
```

### New worker: `Server.Workers.ExperimentController`

Replaces `ExperimentCegarIter`. Long-lived Oban job with heartbeat.

- Initial state: read experiment row, fetch current `predicates` +
  `policy_version` + `bit_progress` (defines which bits are "open").
- Pool maintenance loop: while the experiment is running, ensure
  `pool_capacity` task slots are filled with
  `(bit_idx, candidate, policy_version=V)` tuples for the bits that
  are still open at version V. Dispatch via Scorer.
- Reaction loop: on each batch / chunk completion (telemetry
  hook), check if any candidate's aggregate has crossed the commit
  threshold against the current V. If yes, run the commit gate
  (see below). If commit succeeds, V is bumped; in-flight tasks at
  V−1 become stale; the pool maintainer re-fills with new tasks at V.
- CEGAR transition: when no commit has happened for
  `cegar_saturation_window_seconds` (default 5 min), trigger
  `collect_states` under current policy → rebuild features →
  re-seed candidate pool. This becomes the new "iter".

### Commit gate (option c — version reject)

```
def attempt_commit(experiment_id, bit_idx, candidate, mean_reward, evaluated_at_version):
  with transaction:
    current = SELECT policy_version, predicates, best_reward_per_bit FROM experiments WHERE id = experiment_id FOR UPDATE
    if evaluated_at_version != current.policy_version:
      return :stale  # discard
    if mean_reward <= current.best_reward_per_bit[bit_idx] + acceptance_epsilon:
      return :no_improvement
    new_predicates = current.predicates with bit_idx ← candidate
    new_version = current.policy_version + 1
    UPDATE experiments SET predicates = new_predicates, policy_version = new_version, …
    INSERT INTO policy_versions (…)
    return {:committed, new_version}
```

This is the *only* path that mutates the global policy. Atomicity
via `FOR UPDATE`. Stale evaluations are silently discarded — they
have no effect, harmful or otherwise. **Monotonicity invariant**:
`policy_version` only increases; each version's mean reward
strictly exceeds the previous (by `acceptance_epsilon`).

### Worker API additions

- Task dispatch payload gains `policy_version`.
- Result submission gains `policy_version`; server compares against
  current at commit.
- Worker logic unchanged otherwise — it doesn't know about commits;
  it just evaluates the policy it was given.

### Dashboard additions

- Live "policy version" counter per experiment card.
- Commit log strip showing the last N commits: `v=12 bit_3 r=+2.1`
  with timestamps.
- Reward over time: scatter / line of best_reward_per_bit at each
  version.

## Phasing and roll-out

Each layer is independently deployable. The sequenced order matters:

1. Layer 1 first because it gives immediate user-visible benefit
   even on the current serial master. It also de-risks Layer 3 by
   establishing the streaming aggregate plumbing.
2. Layer 2 second because it stresses the swarm and validates that
   the chunk infrastructure handles the higher dispatch rate.
3. Layer 3 last; it replaces `ExperimentCegarIter` outright. We will
   cancel any in-flight experiments before deploying Layer 3 (their
   checkpoint format is forward-incompatible) and re-submit them on
   the new architecture.

Each layer's deploy includes:

- A boot-time DB integrity check (no half-migrated states).
- Rollback path: previous Oban worker module retained one release for
  emergency revert.

## Open questions tracked elsewhere

- Throughput tuning of pool capacity and `n_episodes` per task under
  the streaming commit model. Empirical — set after Layer 3 ships.
- Whether per-worker affinity (worker X always evaluates bit_3) is a
  useful optimization for caches. Premature.
- Validation-before-commit (option a) as a future throughput
  optimization if the swarm grows large enough that stale-discards
  become wasteful.
