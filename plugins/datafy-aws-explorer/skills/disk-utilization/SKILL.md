---
name: disk-utilization
description: Guide the customer through measuring real disk utilization on a sample of their volumes (CloudWatch metrics, then optionally df over SSM on the sampled instances). Use when discovery has finished and utilization is unmeasured or below the 5% sample target, or when the customer asks how full their disks are.
---

# Measuring real utilization

Discovery knows how big each volume is, not how full. Measuring a representative **5% sample** (min 10,
max 500) turns "estimated from size" into a measured range. Offer this once after discovery, and again only if
the dashboard or a question depends on it.

## The three tiers (cheapest and least invasive first)

| Tier | What it does | Cost / access |
|---|---|---|
| 0 | Size only, from discovery | none |
| 1 `cloudwatch` | Reads `disk_used_percent` (CWAgent). Touches no instance. | Billed, ~cents. Hard cap **$1** per run, never exceeded. |
| 2 `ssm` | Runs the fixed `DatafyDiskUsage` document (`df -PT -B1` + `lsblk`) on the sampled instances | No AWS charge. **Needs the customer's explicit approval.** |

## Reaching member accounts

The customer runs from the Organization's **management account**. Member accounts are reached by assuming a role:
pass `--role DatafyExplorerRole` (least privilege, see the README's StackSet setup) or rely on the default
`OrganizationAccountAccessRole`. The scanner's `--setup-role` role is deleted after the scan and cannot be used here.
`DatafyDiskUsage` must exist in each account and region being measured; accounts that lack it come back as
failed with the AWS error, which you should report grouped by account.

## Procedure

1. `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/sample_volumes.py` — picks a stratified, reproducible sample. Tell the
   customer the population, the target, and how many are unmeasurable (unattached, stopped, Windows).
2. **Tier 1:** `collect_utilization.py plan cloudwatch`. Show the estimated cost. If they agree, run it with
   `run cloudwatch --yes`. Report how many instances had no agent metrics.
3. **Tier 2:** `collect_utilization.py plan ssm`. Show the customer, verbatim: the instance list, the document
   name, and the exact command. Ask for an explicit yes. **Only then** `run ssm --yes`.
   - Never run any command other than the fixed document. There is no free-form command path; do not
     construct one, and do not use `--use-aws-runshellscript` unless the customer asks and understands that the
     stock document can run arbitrary commands.
   - If instances come back `not_managed`/`ssm_offline`, explain why (no SSM agent / instance profile) and
     do not retry in a loop.
4. Rebuild: `build_db.py`, then offer `/datafy-aws-explorer:dashboard`.

If the customer says no to either tier, record it so you do not ask again this run:
`echo '{"cloudwatch": true}' > datafy-explorer/.declined.json` (or `"ssm"`).

## Hard rules

- Nothing here is ever sent to Datafy. These scripts talk only to the customer's own AWS.
- Do not exceed the $1 AWS spend cap, and do not call Cost Explorer or any billed API outside the scripts.
- Results are cumulative: re-running samples fresh volumes and skips instances already measured.
