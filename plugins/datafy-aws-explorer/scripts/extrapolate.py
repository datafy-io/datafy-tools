#!/usr/bin/env python3
"""Estimate whole-estate utilization from the measured sample, as a RANGE.

Method: stratify attached volumes by volume type x size band. Within each stratum take
the mean measured used% (finite-population-corrected standard error). Strata with fewer
than 3 measurements borrow the pooled mean. Totals combine strata in quadrature; the
range is a ~95% interval, clamped to 0..100%. With fewer than 5 measured volumes no
range is produced at all: a small sample must not look like a finding.

A single df snapshot says nothing about growth, so this is a point-in-time estimate.
"""
import math

from sample_volumes import measurable, size_band

MIN_FOR_RANGE = 5
MIN_PER_STRATUM = 3
Z = 1.96


def _mean_se(xs, big_n):
    n = len(xs)
    m = sum(xs) / n
    if n < 2:
        return m, None
    var = sum((x - m) ** 2 for x in xs) / (n - 1)
    fpc = max(0.0, 1 - n / big_n) if big_n else 1.0
    return m, math.sqrt(var / n * fpc)


def estimate(idx, measured_pct):
    """idx: volume_index(); measured_pct: {volume_id: used_pct}. Returns a dict."""
    pop = measurable(idx)
    total_gib = sum(e["volume"].get("Size") or 0 for e in pop.values())
    meas = {v: p for v, p in measured_pct.items() if v in pop and p is not None}
    out = {"population": len(pop), "measured": len(meas), "total_gib": total_gib,
           "measured_gib": sum(pop[v]["volume"].get("Size") or 0 for v in meas)}
    if len(meas) < MIN_FOR_RANGE:
        out.update(range=None, note="Fewer than %d volumes measured: no estimate is given." % MIN_FOR_RANGE)
        return out

    key = lambda e: (e["volume"].get("VolumeType"), size_band(e["volume"].get("Size")))
    strata = {}
    for vid, e in pop.items():
        strata.setdefault(key(e), []).append(vid)
    pooled, _ = _mean_se(list(meas.values()), len(pop))

    mid = var = 0.0
    for k, members in strata.items():
        gib = sum(pop[v]["volume"].get("Size") or 0 for v in members)
        xs = [meas[v] for v in members if v in meas]
        if len(xs) >= MIN_PER_STRATUM:
            m, se = _mean_se(xs, len(members))
        else:
            m, se = pooled, None
            se = (_mean_se(list(meas.values()), len(pop))[1] or 0) * 2  # widen: borrowed mean
        mid += gib * m / 100.0
        var += (gib * (se or 0) / 100.0) ** 2
    half = Z * math.sqrt(var)
    lo, hi = max(0.0, mid - half), min(float(total_gib), mid + half)
    out["range"] = {
        "used_gib": [round(lo, 1), round(hi, 1)], "used_gib_mid": round(mid, 1),
        "used_pct": [round(100 * lo / total_gib, 1) if total_gib else 0,
                     round(100 * hi / total_gib, 1) if total_gib else 0],
        "empty_gib": [round(total_gib - hi, 1), round(total_gib - lo, 1)],
    }
    out["note"] = ("Measured on %d of %d eligible volumes (%.1f%%). Range is ~95%%, point-in-time, "
                   "and excludes growth." % (len(meas), len(pop), 100 * len(meas) / len(pop)))
    return out
