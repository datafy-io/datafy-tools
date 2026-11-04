# Datafy AWS Explorer

A Claude Code plugin that helps you explore your own AWS estate:

- **`/datafy-aws-explorer:discover`** runs the read-only [Datafy discovery scanner](../../discovery-tool/aws/) across your AWS Organization.
- **Ask questions** about the results in plain language ("which unattached gp2 volumes are over 500 GiB?").
- **`/datafy-aws-explorer:utilization`** measures real disk utilization on a 5% sample of your volumes: CloudWatch first, then, only with your approval, `df` over SSM.
- **`/datafy-aws-explorer:dashboard`** builds an offline HTML dashboard from whatever data exists, at any point.

> **Nothing is sent to Datafy.** Everything runs on your machine with your credentials. The plugin has no
> telemetry, no upload step, and no call home. You decide whether to share anything, and with whom.

## Install

```
/plugin marketplace add datafy-io/datafy-tools
/plugin install datafy-aws-explorer@datafy-tools
```

Needs Python 3.9+, `boto3` (`pip install boto3`), the `sqlite3` CLI, and AWS credentials for your management account
(the same requirements as the scanner; see its [IAM section](../../discovery-tool/aws/README.md#iam-permissions)).

## What you will be asked, and when

| Step | What happens | Your approval |
|---|---|---|
| Discover | Scanner runs read-only across the Organization | Confirm the account; asked before `--setup-role` |
| Sample | A representative **5%** of volumes is chosen (min 10, max 500) | Shown to you |
| Tier 1: CloudWatch | Reads `disk_used_percent` metrics, touches no instance | Cost shown first; **hard cap $1** |
| Tier 2: SSM `df` | Runs one fixed read-only command on the sampled instances | **Explicit yes**, with the instance list and exact command shown |
| Dashboard | Static HTML file written locally | none |

You can decline either tier; the plugin asks once and remembers.

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
| `ssm:DescribeInstanceInformation`, `SendCommand`, `GetCommandInvocation` | Tier 2 | Free. Output returned inline, never to S3 |
| `cloudwatch:ListMetrics` | Tier 1 | ~$0.01 per 1,000 requests |
| `cloudwatch:GetMetricData` | Tier 1 | ~$0.01 per 1,000 metrics |

For scale: 5% of a 4,000-volume estate is ≈200 volumes, a fraction of a cent. Cost Explorer is never called.

## Setting up tier 2 (SSM)

`ssm:SendCommand` can run arbitrary commands unless you restrict it. So the plugin ships a **fixed document**:

1. Deploy [`iam/datafy-disk-usage.cfn.yaml`](iam/datafy-disk-usage.cfn.yaml) in each account/region you want to measure.
   It creates `DatafyDiskUsage`, which runs only `df -PT -B1` and `lsblk`.
2. Grant the identity running the plugin [`iam/ssm-sendcommand-policy.json`](iam/ssm-sendcommand-policy.json):
   `SendCommand` is allowed **on that document only**.
3. Instances must be SSM-managed (agent + instance profile). Those that aren't are reported with the reason,
   never skipped silently.

### Org-wide: running from the management account

The plugin runs from your **management (admin) account** and reaches every member account by assuming a role.
For tier 1 and 2 that role must be able to read CloudWatch/SSM, and the `DatafyDiskUsage` document must exist in
each account **and region** you measure. Two options:

- **Quick:** use `OrganizationAccountAccessRole` (`--role OrganizationAccountAccessRole`, the default). It is
  full-admin in each account, so you give up least privilege, and you still deploy the document yourself.
- **Least privilege (recommended):** deploy two templates as **service-managed StackSets** to the organization:
  [`iam/datafy-explorer-role.cfn.yaml`](iam/datafy-explorer-role.cfn.yaml) (once per account; takes your
  `ManagementAccountId`) and [`iam/datafy-disk-usage.cfn.yaml`](iam/datafy-disk-usage.cfn.yaml) (every region you
  measure). Then pass `--role DatafyExplorerRole`.
- **The management account itself is not covered by a service-managed StackSet.** Deploy both templates there as
  ordinary stacks. The role is not needed there, since you are already that identity.

The scanner's temporary `--setup-role` creates `DatafyDiscoveryRole`, which is read-only EC2 access and is
**deleted after the scan**, so it cannot be reused for utilization.

Tier 1 needs [`iam/cloudwatch-readonly-policy.json`](iam/cloudwatch-readonly-policy.json) and instances running the
CloudWatch agent with `disk_used_percent`.

## Limits, stated plainly

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
