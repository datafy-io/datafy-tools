---
description: Measure real disk utilization on a 5% sample of volumes by running df over SSM (with your approval)
argument-hint: "[--count N | --fraction 0.05]"
---

Follow the `disk-utilization` skill end to end. Arguments (`$ARGUMENTS`) go to `sample_volumes.py`.

Start by checking that `datafy-explorer/discovery.jsonl` exists. SSM `df` is the default method; CloudWatch is optional. Present the plan, check that the
`DatafyDiskUsage` document exists (offering to deploy it, with approval, where missing), and obtain an explicit
yes before any `run ... --yes`, showing the instance list and the exact command. AWS spend is capped at $1
(only CloudWatch can bill); the scripts enforce it.
