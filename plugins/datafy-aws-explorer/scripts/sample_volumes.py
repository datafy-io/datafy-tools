#!/usr/bin/env python3
"""Pick the volumes to measure: SSM-reachable instances, biggest data disks first.

Strategy `largest` (default): population = volumes on running Linux instances that SSM can actually reach (from
ssm_inventory.jsonl, taken by `collect_utilization.py inventory`). Instances are ranked by their largest *data*
(non-root) disk, then total size, and taken from the top until the target number of volumes is covered. The sample
is deliberately NOT random: it concentrates where utilization matters most, so extrapolation is restricted
(see extrapolate.py). Strategy `stratified` draws a seeded random sample across account x type x size band
and is the one to use when an estate-wide estimate matters more than finding the biggest disks.

Original description (applies to both): population = volumes attached to a *running* instance. Unattached volumes and volumes on
stopped instances have no live filesystem to read, so they cannot be measured.

Target size = 5% of the population, floored at 10 and capped at 500 (never more than exists).
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
                    read_jsonl, ssm_reachable, volume_index, workspace, log)

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


def restrict_to_reachable(pop, reachable):
    if reachable is None:
        return pop
    return {v: e for v, e in pop.items() if e["instance"]["InstanceId"] in reachable}


def data_disk_gib(entry_vols, root_device):
    """Largest non-root volume, or 0 if the instance only has its root disk."""
    return max([v.get("Size") or 0 for v in entry_vols if v.get("Device") != root_device] or [0])


def draw_largest(idx, measured_ids, reachable=None, fraction=SAMPLE_FRACTION, count=None):
    full = measurable(idx)
    pop = restrict_to_reachable(full, reachable)
    n_total = target_size(len(pop), fraction, count)
    already = len([v for v in pop if v in measured_ids])
    need = max(0, n_total - already)
    by_inst = {}
    for vid, e in pop.items():
        by_inst.setdefault(e["instance"]["InstanceId"], []).append((vid, e))
    ranked = []
    for iid, items in by_inst.items():
        todo = [vid for vid, _ in items if vid not in measured_ids]
        if not todo:
            continue
        vols = [e["volume"] for _, e in items]
        big = data_disk_gib(vols, items[0][1]["instance"].get("RootDeviceName"))
        ranked.append((big > 0, big, sum(v.get("Size") or 0 for v in vols), iid, sorted(todo), items[0][1]["account_id"]))
    ranked.sort(key=lambda r: (r[0], r[1], r[2], r[3]), reverse=True)
    picked, instances, selection = [], [], []
    for has_data, big, total, iid, todo, account in ranked:
        if len(picked) >= need:
            break
        picked += todo
        instances.append(iid)
        selection.append({"instance_id": iid, "account_id": account, "largest_data_disk_gib": big,
                          "total_gib": total, "volumes": len(todo)})
    return {
        "strategy": "largest",
        "population": len(pop),
        "unmeasurable": len(idx) - len(full),
        "unreachable_by_ssm": (len(full) - len(pop)) if reachable is not None else None,
        "ssm_inventory": "applied" if reachable is not None else "absent: run `collect_utilization.py inventory` first",
        "target": n_total,
        "already_measured": already,
        "volumes": sorted(picked),
        "instances": sorted(instances),
        "selection": selection,
        "strata": 0,
    }


def draw(idx, measured_ids, fraction=SAMPLE_FRACTION, count=None, seed="datafy", reachable=None):
    pop = restrict_to_reachable(measurable(idx), reachable)
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
        "strategy": "stratified",
        "population": len(pop),
        "unmeasurable": len(idx) - len(measurable(idx)),
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
    ap.add_argument("--strategy", choices=["largest", "stratified"], default="largest")
    ap.add_argument("--ignore-ssm", action="store_true", help="do not restrict to SSM-reachable instances")
    a = ap.parse_args(argv)
    ws = workspace(a.workspace)
    idx = volume_index(read_discovery(ws))
    if not idx:
        raise SystemExit("no discovery data in %s; run discovery first" % ws)
    measured = set()
    for r in read_jsonl(os.path.join(ws, UTILIZATION_FILE)):
        if r.get("record_type") == "instance" and r.get("status") in ("ok", "partial"):
            measured.update(m["volume_id"] for m in r.get("mounts", []) if m.get("volume_id"))
    reachable = None if a.ignore_ssm else ssm_reachable(ws)
    if reachable is None and not a.ignore_ssm:
        log("warning: no SSM inventory yet, so reachability is unknown. Run `collect_utilization.py inventory` first.")
    if a.strategy == "largest":
        plan = draw_largest(idx, measured, reachable, a.fraction, a.count)
    else:
        plan = draw(idx, measured, a.fraction, a.count, a.seed, reachable)
        plan["ssm_inventory"] = "applied" if reachable is not None else "absent"
    plan["generated_with"] = {"fraction": a.fraction, "count": a.count, "seed": a.seed, "strategy": a.strategy}
    with open(os.path.join(ws, "sample.json"), "w") as f:
        json.dump(plan, f, indent=1)
    log("wrote %s" % os.path.join(ws, "sample.json"))
    print(json.dumps({k: plan[k] for k in ("strategy", "population", "unmeasurable", "target", "already_measured", "ssm_inventory")}
                     | {"sampled_volumes": len(plan["volumes"]), "instances": len(plan["instances"])}))


if __name__ == "__main__":
    main()
