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

1. **Find out what SSM can reach first:** `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/collect_utilization.py inventory`.
   Free and read-only (it only lists which instances have a working SSM agent; it runs nothing on them). Tell the
   customer how many running Linux instances are reachable vs not. If most are not, say so plainly now: SSM
   cannot measure them, and no sampling can change that.
2. `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/sample_volumes.py` — by default (`--strategy largest`) takes only
   SSM-reachable instances and picks the ones with the **biggest data disks** first, until about 5% of the
   reachable volumes (min 10, max 500) are covered. Tell the customer the reachable population, the target, how
   many volumes were left out as unmeasurable (unattached, stopped, Windows) or unreachable, and that the sample
   deliberately favours the biggest disks. Use `--strategy stratified` only if they want an estate-wide
   statistical estimate more than the biggest disks.
3. `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/collect_utilization.py plan` — gives you the instance list by
   account/region. You use this to write the approval message (see "Asking for approval"); do not paste the plan
   JSON at the customer.
4. `... check ssm` (free) — is `DatafyDiskUsage` deployed in each account/region? If any are `missing`, tell the
   customer plainly and offer, grouped by account:
   - **(a) Deploy it** with `deploy-doc ssm --yes`: creates only that one read-only document, tagged
     `created-by: datafy-aws-explorer`, only in the missing scopes. Needs their approval. Offer to remove it
     afterwards with `remove-doc ssm --yes`, which deletes only documents this tool created.
   - **(b) Deploy it themselves** from `iam/datafy-disk-usage.cfn.yaml` (e.g. a StackSet).
   - **(c) Use the stock `AWS-RunShellScript`** (`--use-aws-runshellscript`): no deployment, but that document
     can run arbitrary commands, so only if they ask for it and understand the difference.
5. Get an explicit yes using the approval message below, then `... run ssm --yes`. Never run any command other than the fixed one.
   Report results grouped by status and reason: `not_managed` / `ssm_offline` mean no SSM agent or instance
   profile on that instance; explain and do not retry in a loop.
6. Rebuild: `build_db.py`, then summarize measured volumes against the 5% target, and offer
   `/datafy-aws-explorer:dashboard`.

CloudWatch (optional): `collect_utilization.py plan cloudwatch`, show the cost, `run cloudwatch --yes`.

If the customer declines, record it so you do not ask again this run:
`echo '{"ssm": true}' > datafy-explorer/.declined.json` (or `"cloudwatch"`).

## Reading the results honestly

With the default `largest` strategy the sample is the biggest data disks, **not a random sample**. The dashboard's
range therefore covers only the size bands with enough readings, on SSM-reachable volumes. Smaller disks and
instances SSM cannot reach are reported as unmeasured, never filled in from the average. Say this when quoting
numbers: "on the biggest disks we could reach, usage was X to Y%", never "your estate is X% full".

## Asking for approval

Write the approval request in plain language. **Never show the customer script names, flags or CLI invocations**
(no `collect_utilization.py ...`, no `--yes`, no `--profile`). Include, in this order:

1. **What and where:** "I'd like to check disk usage on N instances (the ones SSM can reach, with the biggest data
   disks first) across X accounts and Y regions," with the instances listed by account.
2. **A reassurance that is accurate and complete**, for example:
   > This only runs `df` (the same report as `df -h`) and `lsblk` (which lists which disk is which). They read
   > disk sizes and usage and nothing else: nothing is installed, changed or deleted, and nothing is sent to
   > Datafy. The results come back to this machine only. I can show you the exact command if you'd like.
   Do not claim it runs "only `df -h`": it is `df` plus `lsblk`, and saying less would be untrue.
3. **What may not work**, briefly: instances without the SSM agent can't be reached and will be reported, not retried.
4. A plain yes/no question. On "no", record the decline and do not ask again this run.

Only if the customer asks for the exact command, show `REMOTE_COMMAND` from `scripts/collect_utilization.py`.
The same rule applies to the missing-document offer: describe it ("create one small read-only SSM document that
holds that command; I'll offer to delete it afterwards") without printing flags.

## Hard rules

- Nothing here is ever sent to Datafy. These scripts talk only to the customer's own AWS.
- Do not exceed the $1 AWS spend cap, and do not call Cost Explorer or any billed API outside the scripts.
- Results are cumulative: re-running samples fresh volumes and skips instances already measured.
