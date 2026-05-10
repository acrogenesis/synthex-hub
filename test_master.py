"""End-to-end smoke test against a running Synthex Hub.

Spin up server (`API_TOKEN=foo mix run --no-halt`) and at least one
worker, then:

    SYNTHEX_HUB_TOKEN=foo python3 test_master.py
"""

import os
import sys
import time

import requests

SERVER_URL = os.environ.get("SYNTHEX_HUB_URL", "http://localhost:4000/api")
TOKEN = os.environ.get("SYNTHEX_HUB_TOKEN")
HEADERS = {"Authorization": f"Bearer {TOKEN}"} if TOKEN else {}


def main():
    payload = {
        "env_name": "Ant-v5",
        "cmd": "score_bit",
        "name": "smoke-test",
        "bits_per_dim": 3,
        "max_steps": 20,
        "target_bit": 0,
        "bit_predicates": ["falsep"] * 24,
        "seeds": [42],
        "chunk_size": 100,
        "candidates": [["feat", ["axis", 0, i * 0.1]] for i in range(500)],
    }

    print("Submitting batch...")
    resp = requests.post(
        f"{SERVER_URL}/master/batches", json=payload, headers=HEADERS, timeout=10
    )
    if resp.status_code == 401:
        sys.exit("401 unauthorized: set SYNTHEX_HUB_TOKEN")
    resp.raise_for_status()
    body = resp.json()
    batch_id = body["batch_id"]
    print(f"Batch {batch_id}: {body['total_chunks']} chunks queued")

    while True:
        status = requests.get(
            f"{SERVER_URL}/master/batches/{batch_id}", headers=HEADERS, timeout=10
        ).json()
        progress = status.get("progress", 0.0) or 0.0
        print(
            f"  status={status['status']:>10}  "
            f"progress={progress * 100:6.1f}%  "
            f"({status['completed_chunks']}/{status['total_chunks']})"
        )

        if status["status"] == "completed":
            chunks = status["results"]
            flat = [r for chunk in chunks for r in chunk["items"]]
            print(f"\ngot {len(flat)} scored candidates")
            ok = [r for r in flat if "error" not in r]
            errs = [r for r in flat if "error" in r]
            if ok:
                best = max(ok, key=lambda r: r["reward"])
                print(f"  best:  idx={best['idx']}  reward={best['reward']:.2f}")
            if errs:
                print(f"  errors: {len(errs)}  (first: {errs[0]})")
            break

        time.sleep(2)


if __name__ == "__main__":
    main()
