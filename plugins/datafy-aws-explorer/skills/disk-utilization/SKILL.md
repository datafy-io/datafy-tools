---
name: disk-utilization
description: Guide the customer through measuring real disk utilization on a sample of their volumes with df over SSM (default), optionally CloudWatch metrics. Use when discovery has finished and utilization is unmeasured or below the 5% sample target, or when the customer asks how full their disks are.
---

# Measuring real utilization

Discovery knows how big each volume is, not how full. Measuring a representative **5% sample** (min 10,
max 500) turns "estimated from size" into a measured range. Offer this once after discovery, and again only if
the dashboard or a question depends on it.

## Methods

**SSM `df` is the default and the one to recommend.** It works on any SSM-managed Linux instance, needs nothing
installed, returns real used/size/mount data mapped to EBS volume IDs, and costs nothing on AWS. It does run a
command on the customer's instances, so it needs their explicit approval every time.

| | What it does | Cost / access |
|---|---|---|
| **`ssm` (default)** | Runs the fixed `DatafyDiskUsage` document (`df -PT -B1` + `lsblk`) on the sampled instances | No AWS charge. **Explicit approval required.** |
| `cloudwatch` (optional) | Reads `disk_used_percent` (CWAgent). Touches no instance. | Billed, ~cents, hard cap **$1**. Only worth trying if the customer says they run the CloudWatch agent; in practice most estates don't, and every unmeasured instance comes back `no_agent_metrics`. |

Size alone (discovery data) is the baseline when nothing is measured.

## Reaching member accounts

The customer runs from the Organization's **management account**. Member accounts are reached by assuming a role:
pass `--role DatafyExplorerRole` (least privilege, see the README's StackSet setup) or rely on the default
`OrganizationAccountAccessRole`. The scanner's `--setup-role` role is deleted after the scan and cannot be used here.
`DatafyDiskUsage` must exist in each account and region being measured; accounts that lack it come back as
failed with the AWS error, which you should report grouped by account.

## Procedure (SSM)

1. `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/sample_volumes.py` — picks a stratified, reproducible sample (5%, min 10,
   max 500) of volumes on running Linux instances. Tell the customer the population, the target, and how many
   volumes are unmeasurable (unattached, stopped, Windows).
2. `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/collect_utilization.py plan` — shows the instance list by account/region
   and the exact command. Present this to the customer verbatim.
3. `... check ssm` (free) — is `DatafyDiskUsage` deployed in each account/region? If any are `missing`, tell the
   customer plainly and offer, grouped by account:
   - **(a) Deploy it** with `deploy-doc ssm --yes`: creates only that one read-only document, tagged
     `created-by: datafy-aws-explorer`, only in the missing scopes. Needs their approval. Offer to remove it
     afterwards with `remove-doc ssm --yes`, which deletes only documents this tool created.
   - **(b) Deploy it themselves** from `iam/datafy-disk-usage.cfn.yaml` (e.g. a StackSet).
   - **(c) Use the stock `AWS-RunShellScript`** (`--use-aws-runshellscript`): no deployment, but that document
     can run arbitrary commands, so only if they ask for it and understand the difference.
4. Get an explicit yes for the plan, then `... run ssm --yes`. Never run any command other than the fixed one.
   Report results grouped by status and reason: `not_managed` / `ssm_offline` mean no SSM agent or instance
   profile on that instance; explain and do not retry in a loop.
5. Rebuild: `build_db.py`, then summarize measured volumes against the 5% target, and offer
   `/datafy-aws-explorer:dashboard`.

CloudWatch (optional): `collect_utilization.py plan cloudwatch`, show the cost, `run cloudwatch --yes`.

If the customer declines, record it so you do not ask again this run:
`echo '{"ssm": true}' > datafy-explorer/.declined.json` (or `"cloudwatch"`).

## Hard rules

- Nothing here is ever sent to Datafy. These scripts talk only to the customer's own AWS.
- Do not exceed the $1 AWS spend cap, and do not call Cost Explorer or any billed API outside the scripts.
- Results are cumulative: re-running samples fresh volumes and skips instances already measured.
