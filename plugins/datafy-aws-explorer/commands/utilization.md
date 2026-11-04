---
description: Measure real disk utilization on a 5% sample of volumes by running df over SSM (with your approval)
argument-hint: "[--count N | --fraction 0.05]"
---

Follow the `disk-utilization` skill end to end. Arguments (`$ARGUMENTS`) go to `sample_volumes.py`.

Start by checking that `datafy-explorer/discovery.jsonl` exists. SSM `df` is the default method; CloudWatch is optional. Present the plan and obtain an explicit
yes before any `run ... --yes`, using the plain-language approval message in the skill (instance list, an accurate
reassurance that only `df` and `lsblk` run, no script names or flags shown to the customer). AWS spend is capped at $1
(only CloudWatch can bill); the scripts enforce it.
