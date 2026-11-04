#!/usr/bin/env python3
"""Build dashboard.html: one self-contained, offline page from the workspace files.

The page is templates/dashboard.html (the Datafy savings assessment) with the workspace
data embedded, so it opens with no wizard and no upload. It makes no network requests of
any kind: the template's Content-Security-Policy (`connect-src 'none'`) enforces that in
the browser, and this script leaves it untouched.

Works with discovery data alone. Utilization sections then show what is still unmeasured
and how to measure it; they never present a size-based estimate as a measurement.

  build_dashboard.py [--workspace DIR] [--out PATH]
Prints the path of the file written.
"""
import argparse
import json
import os

from common import (DASHBOARD_FILE, DISCOVERY_FILE, UTILIZATION_FILE, now_iso, read_discovery, read_jsonl,
                    volume_index, workspace, log)
from extrapolate import estimate
from sample_volumes import measurable, target_size

TEMPLATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "templates", "dashboard.html")
MARKER = "<script>\n'use strict';"


def measured_pct(records):
    """{volume_id: used_pct} from instance records: the largest filesystem wins, as in the page."""
    best = {}
    for r in records:
        if r.get("record_type") != "instance" or r.get("status") not in ("ok", "partial"):
            continue
        for m in r.get("mounts", []):
            vid, pct = m.get("volume_id"), m.get("used_pct")
            if not vid or not isinstance(pct, (int, float)):
                continue
            if vid not in best or (m.get("size_bytes") or 0) > (best[vid].get("size_bytes") or 0):
                best[vid] = m
    return {v: m["used_pct"] for v, m in best.items()}


def js_json(obj):
    """JSON safe to place inside a <script> element.

    ensure_ascii escapes U+2028/U+2029; the three characters below could otherwise end the
    script element or open a comment, and only ever occur inside JSON strings, where the
    \\u escape is equivalent.
    """
    s = json.dumps(obj, separators=(",", ":"), ensure_ascii=True)
    return s.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")


def build_embed(ws):
    path = os.path.join(ws, DISCOVERY_FILE)
    if not os.path.exists(path):
        raise SystemExit("no %s in %s; run /datafy:discover first" % (DISCOVERY_FILE, ws))
    with open(path, encoding="utf-8") as f:
        discovery = f.read()
    idx = volume_index(read_discovery(ws))
    util = [r for r in read_jsonl(os.path.join(ws, UTILIZATION_FILE)) if r.get("record_type") == "instance"]
    pct = measured_pct(util)
    est = estimate(idx, pct)
    pop = measurable(idx)
    target = target_size(len(pop))
    sample_file = os.path.join(ws, "sample.json")
    if os.path.exists(sample_file):
        try:
            with open(sample_file) as f:
                target = int(json.load(f).get("target", target))
        except (ValueError, OSError):
            pass
    return {
        "discovery": discovery,
        "utilization": util,
        "estimate": est,
        "generated_at": now_iso(),
        "sample": {"population": len(pop), "measured": est["measured"], "target": target,
                   "unmeasurable": len(idx) - len(pop)},
    }


def render(embed, template_path=TEMPLATE):
    with open(template_path, encoding="utf-8") as f:
        tpl = f.read()
    if tpl.count(MARKER) != 1:
        raise SystemExit("template is missing its script marker; cannot embed data")
    tag = "<script>window.__DATAFY_EMBED__=%s;</script>\n" % js_json(embed)
    return tpl.replace(MARKER, tag + MARKER, 1)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--workspace")
    ap.add_argument("--out")
    a = ap.parse_args(argv)
    ws = workspace(a.workspace)
    out = os.path.abspath(a.out or os.path.join(ws, DASHBOARD_FILE))
    html = render(build_embed(ws))
    with open(out, "w", encoding="utf-8") as f:
        f.write(html)
    log("wrote %s (%.1f MB)" % (out, len(html) / 1e6))
    print(out)


if __name__ == "__main__":
    main()
