#!/usr/bin/env python3
"""Pick a representative, reproducible sample of volumes to measure.

Population = volumes attached to a *running* instance. Unattached volumes and volumes on
stopped instances have no live filesystem to read, so they cannot be measured.

Size = 5% of the population, floored at 10 and capped at 500 (never more than exists).
Selection is stratified by account x volume type x size band, allocated proportionally
(largest remainder) with every stratum represented while the budget allows, then drawn
with a seeded RNG so the same input always yields the same sample.

Volumes already measured in utilization.jsonl are excluded from the draw but count
toward the target, so repeated runs are cumulative rather than repetitive.

  sample_volumes.py [--workspace DIR] [--fraction 0.05 | --count N] [--seed S]
Writes sample.json in the workspace; prints a one-line JSON summary.
"""
import argparse
import hashlib
import json
import math
import os
import random

from common import (SAMPLE_CEILING, SAMPLE_FLOOR, SAMPLE_FRACTION, UTILIZATION_FILE, read_discovery,
                    read_jsonl, volume_index, workspace, log)

SIZE_BANDS = [(50, "<=50"), (200, "51-200"), (1000, "201-1000"), (float("inf"), ">1000")]


def size_band(gib):
    for limit, label in SIZE_BANDS:
        if (gib or 0) <= limit:
            return label


def target_size(population, fraction=SAMPLE_FRACTION, count=None):
    if population <= 0:
        return 0
    n = count if count is not None else math.ceil(population * fraction)
    n = max(SAMPLE_FLOOR if count is None else 1, n)
    return min(n, SAMPLE_CEILING, population)


def measurable(idx):
    return {vid: e for vid, e in idx.items()
            if e["instance"] and e["instance"].get("State") == "running"
            and "windows" not in (e["instance"].get("PlatformDetails") or "").lower()}


def allocate(strata_sizes, n):
    """Proportional allocation with largest remainder; every stratum gets >=1 if n allows."""
    keys = sorted(strata_sizes)
    total = sum(strata_sizes.values())
    if n >= total:
        return dict(strata_sizes)
    if n < len(keys):  # more strata than slots: keep the largest strata, one each
        keep = sorted(keys, key=lambda k: (-strata_sizes[k], k))[:n]
        return {k: (1 if k in keep else 0) for k in keys}
    alloc = {k: 1 for k in keys}
    quota = {k: strata_sizes[k] * n / total for k in keys}
    for k in keys:
        alloc[k] = min(strata_sizes[k], max(1, int(quota[k])))
    rest = n - sum(alloc.values())
    for k in sorted(keys, key=lambda k: (quota[k] - int(quota[k]), k), reverse=True):
        if rest <= 0:
            break
        if alloc[k] < strata_sizes[k]:
            alloc[k] += 1
            rest -= 1
    return alloc


def draw(idx, measured_ids, fraction=SAMPLE_FRACTION, count=None, seed="datafy"):
    pop = measurable(idx)
    n_total = target_size(len(pop), fraction, count)
    already = len([v for v in pop if v in measured_ids])
    need = max(0, n_total - already)
    todo = {v: e for v, e in pop.items() if v not in measured_ids}
    strata = {}
    for vid, e in todo.items():
        v = e["volume"]
        strata.setdefault((e["account_id"], v.get("VolumeType"), size_band(v.get("Size"))), []).append(vid)
    alloc = allocate({k: len(m) for k, m in strata.items()}, min(need, len(todo)))
    picked = []
    for k in sorted(strata, key=str):
        members = sorted(strata[k])
        rng = random.Random(hashlib.sha256(("%s|%s" % (seed, k)).encode()).hexdigest())
        rng.shuffle(members)
        picked.extend(members[:alloc.get(k, 0)])
    picked.sort()
    instances = sorted({idx[v]["instance"]["InstanceId"] for v in picked})
    return {
        "population": len(pop),
        "unmeasurable": len(idx) - len(pop),
        "target": n_total,
        "already_measured": already,
        "volumes": picked,
        "instances": instances,
        "strata": len(strata),
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--workspace")
    ap.add_argument("--fraction", type=float, default=SAMPLE_FRACTION)
    ap.add_argument("--count", type=int)
    ap.add_argument("--seed", default="datafy")
    a = ap.parse_args(argv)
    ws = workspace(a.workspace)
    idx = volume_index(read_discovery(ws))
    if not idx:
        raise SystemExit("no discovery data in %s; run discovery first" % ws)
    measured = set()
    for r in read_jsonl(os.path.join(ws, UTILIZATION_FILE)):
        if r.get("record_type") == "instance" and r.get("status") in ("ok", "partial"):
            measured.update(m["volume_id"] for m in r.get("mounts", []) if m.get("volume_id"))
    plan = draw(idx, measured, a.fraction, a.count, a.seed)
    plan["generated_with"] = {"fraction": a.fraction, "count": a.count, "seed": a.seed}
    with open(os.path.join(ws, "sample.json"), "w") as f:
        json.dump(plan, f, indent=1)
    log("wrote %s" % os.path.join(ws, "sample.json"))
    print(json.dumps({k: plan[k] for k in ("population", "unmeasurable", "target", "already_measured")}
                     | {"sampled_volumes": len(plan["volumes"]), "instances": len(plan["instances"])}))


if __name__ == "__main__":
    main()
