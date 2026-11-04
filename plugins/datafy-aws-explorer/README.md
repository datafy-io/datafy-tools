# Datafy AWS Explorer

A Claude Code plugin that helps you explore your own AWS estate:

- **`/datafy-aws-explorer:discover`** runs the read-only [Datafy discovery scanner](../../discovery-tool/aws/) across your AWS Organization.
- **Ask anything about the results, in the session, in plain language** ("which unattached gp2 volumes are over 500 GiB?", "which accounts have no backups?"), with follow-ups. Claude writes read-only SQL against a local database, so the dashboard is optional, not the only way to see your data.
- **`/datafy-aws-explorer:utilization`** measures real disk utilization on a 5% sample of your volumes by running `df` over SSM, only with your approval. (CloudWatch metrics are an optional extra, for estates that run the CloudWatch agent.)
- **`/datafy-aws-explorer:dashboard`** builds an offline HTML dashboard from whatever data exists, at any point.

> **Nothing is sent to Datafy.** Everything runs on your machine with your credentials. The plugin has no
> telemetry, no upload step, and no call home. You decide whether to share anything, and with whom.

## Install

```
/plugin marketplace add datafy-io/datafy-tools
/plugin install datafy-aws-explorer@datafy-tools
```

Needs Python 3.9+, `boto3` (`pip install boto3`), and AWS credentials for your management account
(the same requirements as the scanner; see its [IAM section](../../discovery-tool/aws/README.md#iam-permissions)).

## What you will be asked, and when

| Step | What happens | Your approval |
|---|---|---|
| Discover | Scanner runs read-only across the Organization | Confirm the account; asked before `--setup-role` |
| SSM inventory | Lists which running Linux instances SSM can reach. Free, read-only, runs nothing on them | none |
| Sample | Among reachable instances, the ones with the **biggest data disks** first, about 5% of volumes (min 10, max 500) | Shown to you |
| `df` over SSM (default) | Runs one fixed read-only command on the sampled instances. **Nothing is created in your account.** | **Explicit yes**, with the instance list and a plain-language explanation. Only `df` and `lsblk` run, and the exact command is shown on request |
| CloudWatch (optional) | Reads `disk_used_percent`; touches no instance | Cost shown first; **hard cap $1** |
| Dashboard | Static HTML file written locally | none |

You can decline any step; the plugin asks once and remembers.

## Exactly what it contacts

| Host | Why | What is sent |
|---|---|---|
| Your AWS endpoints (EC2, SSM, CloudWatch, STS) | The scan and measurements | Your own API calls, as you |
| `github.com/datafy-io/datafy-tools/releases` | Download the scanner, once, pinned to a release | Nothing about you |

The scanner is pinned by release tag and **SHA-256** in [`scanner.lock.json`](scanner.lock.json); a mismatch is
refused. The dashboard is a single file with a Content-Security-Policy of `connect-src 'none'`: your browser
itself blocks any network request from it. CI fails the build if a script imports a network library, mentions a
URL outside the release host, or makes a billed call without a budget charge.

Your data lives in `./datafy-explorer/` (git-ignored by a `.gitignore` the plugin writes there). While you ask
Claude questions, results pass through your own Claude session under your own Anthropic terms; the plugin itself
transmits nothing.

## AWS API calls and cost

The plugin never spends more than **$1** of your AWS money in a run, enforced in code, and shows an estimate first.

| Call | Used for | Cost |
|---|---|---|
| EC2 `Describe*`, Organizations `List*`, STS | Scanner | Free |
| `ssm:DescribeInstanceInformation`, `SendCommand` (stock `AWS-RunShellScript`), `GetCommandInvocation` | SSM `df` | Free. Output returned inline, never to S3 |
| `ssm:DescribeDocument`, `CreateDocument`, `DeleteDocument` (+ tags) | Only in the opt-in document mode, for `DatafyDiskUsage` | Free |
| `cloudwatch:ListMetrics` | CloudWatch (optional) | ~$0.01 per 1,000 requests |
| `cloudwatch:GetMetricData` | CloudWatch (optional) | ~$0.01 per 1,000 metrics |

For scale: 5% of a 4,000-volume estate is ≈200 volumes, a fraction of a cent. Cost Explorer is never called.

## Setting up SSM `df`

Nothing needs to be deployed. The plugin runs one fixed command (`df -PT -B1` and `lsblk`) through SSM Run Command
using the stock `AWS-RunShellScript` document, which exists in every account. The command appears in SSM's command
history, which is your audit trail. Instances must be SSM-managed (agent + instance profile); those that aren't are
reported with the reason, never skipped silently.

The plugin only ever sends that one command, and its tests check that. AWS itself cannot enforce that, though:
the identity running the plugin needs `ssm:SendCommand` on `AWS-RunShellScript`, which could run any command.
Grant only [`iam/ssm-sendcommand-policy.json`](iam/ssm-sendcommand-policy.json).

**If your security team wants IAM to enforce "this command only"**, use the opt-in document mode: deploy
[`iam/datafy-disk-usage.cfn.yaml`](iam/datafy-disk-usage.cfn.yaml) (it creates `DatafyDiskUsage`, which runs only that
command) and grant [`iam/ssm-sendcommand-document-only-policy.json`](iam/ssm-sendcommand-document-only-policy.json), where
`SendCommand` is allowed on that document only. The plugin can create and later delete the document itself, with your
approval, and runs with `--use-document`.

### Org-wide: running from the management account

The plugin runs from your **management (admin) account** and reaches every member account by assuming a role that
can use SSM:

- **Quick:** `OrganizationAccountAccessRole` (the default). It is full-admin in each account, so you give up least
  privilege.
- **Least privilege (recommended):** deploy [`iam/datafy-explorer-role.cfn.yaml`](iam/datafy-explorer-role.cfn.yaml) as a
  **service-managed StackSet** to the organization (takes your `ManagementAccountId`; set `AllowStockRunShellScript`
  to `false` for document-only mode), then pass `--role DatafyExplorerRole`.
- **The management account itself is not covered by a service-managed StackSet.** You are already that identity there,
  so no role is needed.

The scanner's temporary `--setup-role` creates `DatafyDiscoveryRole`, which is read-only EC2 access and is
**deleted after the scan**, so it cannot be reused for utilization.

The optional CloudWatch method needs [`iam/cloudwatch-readonly-policy.json`](iam/cloudwatch-readonly-policy.json) and instances running the
CloudWatch agent with `disk_used_percent`.

## Limits, stated plainly

- **The sample is the biggest disks, not a random one.** So the range covers only the size bands with enough readings, on SSM-reachable volumes; smaller disks and unreachable instances are reported as unmeasured, never filled in from an average. (`--strategy stratified` gives a random, estate-wide sample instead.)
- **Measured vs estimated.** Without utilization data the dashboard estimates from provisioned size. With it,
  results are a *range* extrapolated from the sample, never a point value, and with fewer than 5 volumes measured
  no estimate is given.
- **One snapshot, no growth.** `df` shows usage now. Savings figures are upper bounds until growth is known.
- **Not measurable:** unattached volumes, volumes on stopped instances, and Windows instances (v1 is Linux only).
- **Volume mapping.** Mounts are tied to EBS volume IDs via the NVMe serial. LVM/RAID spanning several volumes
  is kept but not attributed to one volume. CloudWatch gives a percentage only, so its byte figures are derived
  from provisioned size and labelled approximate.
- **A gap is never silent.** Skipped/failed/partial accounts and instances are listed in answers and on the dashboard.

## Development

```bash
cd tests && python3 -m unittest discover -p "test_*.py"
```

No AWS account is needed. Tests use fakes, and the policy tests enforce the promises above.
