---
description: Build the offline Datafy dashboard from whatever data exists (discovery, utilization)
---

1. `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/build_db.py`
2. `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/build_dashboard.py` — writes `datafy-explorer/dashboard.html`.
3. Tell the customer the path and open it (`open` on macOS, `xdg-open` on Linux). It is a static file with no
   network access; they decide whether to share it.
4. Say which sections are measured vs estimated from size, and, if utilization coverage is below the 5%
   target, point at `/datafy:utilization`.
