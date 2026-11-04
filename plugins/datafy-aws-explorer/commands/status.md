---
description: Show what data the explorer has (discovery coverage, utilization coverage, spend)
---

Run `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/build_db.py`, then using `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/query.py` report:
the `scan_summary` row, `scan_gaps`, the count of volumes, how many distinct volumes have a measured mount,
the eligible-population size (attached to running Linux instances), and the 5% target (ceil(0.05 × eligible), min 10, max 500).
Suggest the next command.
