---
description: Measure real disk utilization on a 5% sample of volumes (CloudWatch first, then optionally df over SSM)
argument-hint: "[--count N | --fraction 0.05]"
---

Follow the `disk-utilization` skill end to end. Arguments (`$ARGUMENTS`) go to `sample_volumes.py`.

Start by checking that `datafy-explorer/discovery.jsonl` exists. Present each plan to the customer and obtain
an explicit yes before any `run ... --yes`. For the SSM tier show the instance list and the exact command.
Cap AWS spend at $1; the scripts enforce it.
