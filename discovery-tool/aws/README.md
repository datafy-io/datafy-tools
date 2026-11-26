# Datafy Discovery Tool

Inventories EBS volumes, EC2 instances, AMIs, snapshots, DLM policies, and AWS Backup plans across all accounts in an AWS Organization. Used to scope a Datafy engagement before installation.

**Read-only. No writes, no mutations. Safe to run in production.**

This is the AWS edition. See the [Azure edition](../azure/) for Azure tenants,
or the [overview](../README.md) for what the two have in common.

## What it collects

| Data | Fields |
|---|---|
| EBS Volumes | ID, size, type, IOPS, throughput, state, encryption, attached instance, device, AZ, tags |
| EC2 Instances | ID, type, state, platform, AMI, AZ, root device, architecture, tags |
| AMIs | ID, name, description, platform, architecture |
| Snapshots | ID, volume ID, size, creation time, state, encryption, tags |
| DLM Policies | Policy list |
| AWS Backup Plans | Plan list |

Output is one JSON object per account × region (JSONL format), identical across all three implementations, followed by a summary record. Accounts and regions that could not be scanned are recorded in the file with a reason — see [Output format](#output-format).

## Prerequisites

- **Run from the AWS management (root) account.** The tool uses the AWS Organizations API to enumerate accounts and assumes a role into each child account to perform the scan.
- AWS credentials for the management account — via a named profile (`--profile`), environment variables, or instance role.

## How it accesses child accounts

The tool assumes a role in each child account to read data. You have three options:

### Option 1 — Use the default cross-account role (simplest)

Most AWS organizations have `OrganizationAccountAccessRole` in every member account (created automatically when accounts are provisioned through Organizations). No extra setup needed:

```bash
./discovery --profile myprofile
```

### Option 2 — Use an existing custom role

If your org uses a different cross-account role:

```bash
./discovery --profile myprofile --role MyExistingReadOnlyRole
```

The role must trust your management account and have the [child account permissions](#child-account-role) listed below.

### Option 3 — Auto-provision a minimal role (recommended when no suitable role exists)

Use `--setup-role` when `OrganizationAccountAccessRole` does not exist in all accounts, or when you want a minimal ephemeral role:

```bash
./discovery --profile myprofile --setup-role
```

This creates a CloudFormation StackSet that deploys `DatafyDiscoveryRole` to every target account, runs the scan, and **always removes the StackSet when done** — even if the scan fails.

> **Requires:** CloudFormation trusted access with AWS Organizations must be enabled.  
> Run `aws organizations enable-aws-service-access --service-principal cloudformation.amazonaws.com` if you see a permissions error.

## IAM permissions

### Your caller identity

The AWS identity you run the tool as — whether an IAM user, role, or SSO session — needs these permissions attached in the management account. If you are already an administrator, you likely have them already.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "OrganizationsReadOnly",
      "Effect": "Allow",
      "Action": [
        "organizations:ListAccounts",
        "organizations:ListAccountsForParent",
        "organizations:ListRoots"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AssumeDiscoveryRoles",
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": [
        "arn:aws:iam::*:role/OrganizationAccountAccessRole",
        "arn:aws:iam::*:role/DatafyDiscoveryRole"
      ]
    }
  ]
}
```

If using `--setup-role`, add this statement as well:

```json
{
  "Sid": "StackSetManagement",
  "Effect": "Allow",
  "Action": [
    "cloudformation:CreateStackSet",
    "cloudformation:CreateStackInstances",
    "cloudformation:DeleteStackInstances",
    "cloudformation:DeleteStackSet",
    "cloudformation:DescribeStackSetOperation"
  ],
  "Resource": "arn:aws:cloudformation:*:*:stackset/DatafyDiscovery:*"
}
```

Notes:
- `organizations:List*` actions do not support resource-level permissions in IAM — `*` is required by AWS.
- `sts:AssumeRole` is scoped to the two role names the tool uses. If you pass `--role MyCustomRole`, add `arn:aws:iam::*:role/MyCustomRole` to that resource list.
- `StackSetManagement` is only needed when using `--setup-role`, and is scoped to the `DatafyDiscovery` StackSet the tool creates.

### Child account role

Each child account role (whether `OrganizationAccountAccessRole`, a custom role, or the auto-provisioned `DatafyDiscoveryRole`) must grant:

| Actions | Notes |
|---------|-------|
| `ec2:DescribeVolumes`, `ec2:DescribeInstances`, `ec2:DescribeRegions`, `ec2:DescribeImages`, `ec2:DescribeSnapshots` | EC2 Describe APIs require `Resource: *` — AWS does not support resource-level permissions for these |
| `dlm:GetLifecyclePolicies` | Also requires `Resource: *` — AWS defines no resource type for this action |
| `backup:ListBackupPlans` | Also requires `Resource: *` — AWS defines no resource type for this action |

The role must also trust the management account: `"Principal": {"AWS": "arn:aws:iam::<mgmt-account-id>:root"}`.

## Rate limits and retries

A scan of a large organization makes tens of thousands of API calls, and AWS
throttles it long before the end. All three implementations pin the same retry
policy — AWS **standard** mode, **10 attempts**, exponential backoff with jitter
— so a throttled call is ridden out rather than lost.

This is pinned rather than left to each client's default, because the defaults
disagree: boto3 still ships `legacy` mode while the AWS CLI and the Go SDK ship
`standard`. Two overrides are honoured, if you need to tune for a particularly
tight account:

| Variable | Default | Meaning |
|---|---|---|
| `AWS_RETRY_MODE` | `standard` | AWS retry mode |
| `AWS_MAX_ATTEMPTS` | `10` | **Total** attempts per call, first one included |

`adaptive` mode is deliberately not the default. It keeps a client-side rate
limiter in memory, and the bash implementation spawns a fresh AWS CLI process
per call — it would have nothing to carry between them, so the same setting
would quietly mean less in bash than in Python or Go.

If a call does exhaust its attempts, the region is recorded as `partial` or
`failed` with the AWS error code in `errors` — it is never reported as an empty
region. So throttling costs coverage visibly, and `tail -1` on the output tells
you it happened.

## Scope options

By default the tool scans all accounts in the organization. Use these flags to narrow scope:

| Flag | Description |
|---|---|
| `--ou ID` | Limit to a specific Organizational Unit (e.g. `ou-ab12-xxxxxxxx`) |
| `--include IDS` | Scan only these account IDs (comma-separated) |
| `--exclude IDS` | Skip these account IDs (comma-separated) |

## Anonymizing the output

Some organizations would rather not share their tag values or account IDs. Two
flags keep them out of the file. Both are **off by default** — without a flag the
output is exactly what it was before — and they can be used separately or
together. All three implementations take the same flags and produce the same
output.

| Flag | What it does |
|---|---|
| `--anonymize-tags` | Drops every tag except Datafy's own, and replaces them with a few derived fields. Cluster, node group and ASG names are hashed. |
| `--anonymize-accounts` | Replaces each account ID with a stable alias (`acct-…`) everywhere in the output. |

When either flag is used, the summary record says which were applied:
`"anonymization": {"tags": true, "accounts": false}`.

### `--anonymize-tags`

Only the tag keys below are read; **every other tag is dropped** — on volumes,
instances and snapshots, `Name` included. What remains on each resource is:

| Output field | Taken from | Value in the output |
|---|---|---|
| `cluster` | `eks:cluster-name`, `aws:eks:cluster-name`, `eks:eks-cluster-name`, `ClusterName`, `KubernetesCluster`, `kubernetes.io/cluster/<name>` (the name is in the key), `ebs.csi.aws.com/cluster-name` | Hashed |
| `node_group` | `eks:nodegroup-name`, `karpenter.sh/nodepool` | Hashed |
| `asg` | `aws:autoscaling:groupName` | Hashed |
| `is_k8s` | Any cluster or node group key above, or `ebs.csi.aws.com/cluster`, `CSIVolumeName`, `kubernetes.io/created-for/pv/name` | `true` / `false` |
| `managed_by` | `eks:nodegroup-name` → `eks-nodegroup`; `aws:autoscaling:groupName` → `autoscaling-group`; `karpenter.sh/*` → `karpenter`; `cast:managed-by` or `autoscaling.cast.ai/*` → `cast.ai`; `kops.k8s.io/instancegroup` → `kops`; `sigs.k8s.io/cluster-api-provider-aws/*` → `cluster-api`; `aws:cloudformation:stack-name` → `cloudformation` | A fixed category; the tag's value isn't kept |
| `Tags` | `Managed-By` = `Datafy.io`, and `datafy:*` | Kept as is |

Keys are matched exactly (AWS tag keys are case-sensitive). Where several keys
could supply a field, the first one in the order above wins. A volume inherits
`cluster`, `node_group` and `asg` from the instance it is attached to, and its
own tags override them; `is_k8s` is true if either the volume's tags or what it
inherited mark it as Kubernetes. Fields with no source are `null` (`is_k8s`:
`false`).

Not read on purpose, so dropped: generic `Managed-By` / `managed-by` / `Terraform`
keys (free-text values), `kubernetes.io/created-for/pvc/name` and
`.../pvc/namespace` (the most sensitive values), `k8s.io/cluster-autoscaler/*`,
`Environment`, `team`, `Owner`, `app`, and anything else not listed.

> **Downside:** Datafy's analysis of your workloads is less accurate, because we
> can no longer tell what workload a volume runs.

### `--anonymize-accounts`

Every account ID becomes an alias such as `acct-3fa91c0b27de`, and the same
account gets the same alias on every record and on every run. This covers
`account_id`, an instance's `OwnerId`, and any account ID inside an error message
or ARN. Any other twelve-digit number in the output is aliased too — masking too
much is the safe direction.

> **Downside:** the aliases mean nothing on their own. To act on Datafy's results
> you reconcile them with your accounts using the mapping file. The same applies
> to the hashed cluster, node group and ASG names.

### Hashing and the mapping file

Cluster, node group and ASG names are replaced by a keyed hash (SHA-256 over a
secret key, the kind of value and the value, shortened to 16 hex characters). The
key is generated on your machine the first time you use a flag and kept in
`~/.datafy-discovery/anonymize.key` (owner-only; override the location with
`DATAFY_ANONYMIZE_KEY_FILE`), so the same name gets the same hash across runs.

With either flag the tool also writes a **mapping file** next to the output —
`<output>.mapping.private` — holding every alias and hash with its real value:

```json
{
  "accounts":    { "acct-3fa91c0b27de": "123456789012" },
  "clusters":    { "9c1e5a7d02b4f863": "prod-eks" },
  "node_groups": { "…": "…" },
  "asgs":        { "…": "…" }
}
```

(`accounts` appears with `--anonymize-accounts`; the other three with
`--anonymize-tags`.) The tool prints where it was written. **Keep it. Do not send
it to Datafy** — it is not part of the output file, and it is the only way back
from the aliases to the real values. The key file is just as private.

## Implementations

Three implementations of the AWS edition, sharing one interface and one output
format. (The [Azure edition](../azure/) is Python only.)

| | [Python](python/) | [Go](golang/) | [Bash](bash/) |
|---|---|---|---|
| **Requirements** | Python 3.8+, boto3 | Pre-built binary or Go 1.21+ | aws-cli v2, jq, bash 4.3+ |
| **Best for** | CloudShell, quick runs | Speed, no dependencies | Minimal environments |
| **Parallelism** | ThreadPoolExecutor | Goroutines | Background jobs |

### Quick start

**Python** (recommended for CloudShell):
```bash
pip install boto3
python discovery.py --profile myprofile
```

**Go** (recommended for speed — download from [Releases](https://github.com/datafy-io/datafy-tools/releases)):
```bash
./discovery --profile myprofile
```

**Bash**:
```bash
chmod +x discovery.sh
./discovery.sh --profile myprofile
```

## Tests

Three suites, none of which needs an AWS account:

```bash
./test/run_tests.sh                  # every case, on all three implementations
./test/run_tests.sh --impl go 04     # one implementation, one case
./test/parity/run_parity.sh          # all three, output diffed line for line
./bash/test/run_tests.sh             # bash-internal checks
```

The Azure edition has [its own suite](../azure/README.md#tests), run with
`../azure/test/run_tests.sh`.

### The behavioural suite — `test/`

This is the main one. Each case in `test/cases/` describes the org it needs as a
scenario — accounts, regions, resource counts, which calls are denied, whether
the session expires part-way through — and then asserts on what came out,
without naming any implementation. Every case runs **once per implementation**.

They all talk to `test/lib/fake_aws.py`, a fake AWS endpoint reached through
`AWS_ENDPOINT_URL`, so the real AWS CLI, real boto3 and the real Go SDK are each
exercised — including their signing, their pagination and their error handling —
against byte-identical responses. Mocking any one client instead would only ever
test one of the three.

| Case | Covers |
|---|---|
| `00_smoke` | A healthy small org produces the documented records |
| `01_stress_large_region` | 4000 volumes in one region arrive whole |
| `02_stress_many_accounts` | 12 accounts × 4 regions — no lost or duplicated records |
| `03_stress_many_amis` | 3000 distinct AMIs, looked up within the API's id cap |
| `04_region_failure_vs_empty` | An empty region is distinguishable from a denied one |
| `05_account_skipped_reported` | Unreachable accounts appear in the file, with a reason |
| `06_summary_record` | Coverage is answerable from the output alone |
| `07_interrupt_preserves_data` | A killed run keeps what it collected, and exits 143 |
| `08_credential_expiry` | An expired session is reported, never shown as empty |
| `09_concurrency_ceiling` | Peak parallelism stays within each implementation's cap |
| `10_corrupt_payload` | An unparseable response is reported, not read as empty |
| `11_pagination` | Multi-page result sets arrive whole, on every client |
| `12_unwritable_output` | An unwritable `--output` path fails loudly and early |
| `13_diagnostics_on_stderr` | The file is the only product; stdout stays clean |
| `14_throttling_retried` | A throttled call is retried with backoff, and reported if it runs out |
| `15_setup_role_template` | The role `--setup-role` deploys grants only what AWS will honour (DT-11548) |
| `16_anonymize_tags` | `--anonymize-tags` drops every tag but Datafy's, derives cluster/node group/ASG/`is_k8s`/`managed_by`, hashes stably |
| `17_anonymize_accounts` | `--anonymize-accounts` leaves no account ID anywhere — error text and `OwnerId` included |
| `18_anonymize_off_by_default` | Without the flags the output is unchanged; `--help` documents both |
| `19_anonymize_interrupt` | An interrupted anonymized run does not leak the IDs of accounts that never finished |

### The parity harness — `test/parity/`

Where the behavioural suite asks whether each implementation is *correct*, the
parity harness asks whether they are *identical*: it runs one scenario through
all three and diffs the normalised output line for line. That catches drift the
per-case assertions would not think to look for — a renamed field, a differently
rounded number, a reordered array. It also runs all three with a pinned key and
both anonymization flags, and requires the hashes, the aliases and the mapping
file to match.

### The bash-internal suite — `bash/test/`

Two checks that are properties of `discovery.sh` itself rather than of what it
produces, and so have no Python or Go equivalent: that nothing disables AWS CLI
pagination (`--no-paginate`, `--max-items` and `--page-size` each silently
return a prefix of the data), and that an unwritable `$TMPDIR` — which only the
bash implementation stages records through — fails with a message naming the
variable to change. It runs against a small mock `aws` on `PATH`, so it needs
neither `python3` nor `go`.

### Requirements

`jq`, `python3` and `curl` are needed to run any of it, plus the toolchain of
each implementation under test: `aws-cli v2` for bash, `boto3` for Python, `go`
for Go. An implementation whose toolchain is missing is reported as skipped
rather than silently passing.

### Differences the suites deliberately allow

The three are held to the same output, the same statuses and the same exit
codes. Two things are left to differ, because they follow from the runtime:

- **Parallelism.** Python and Go pin their worker pools (20 accounts × 10
  regions); bash sizes its limits from available RAM at startup, because each
  AWS CLI process costs ~125MB. `09_concurrency_ceiling` asserts that each
  implementation stays within *its own* documented cap.
- **How quickly an interrupt takes effect.** bash kills the process tree and Go
  cancels the request context, so both stop within moments. Python's
  `ThreadPoolExecutor` cannot cancel a future that is already running, so it
  drains its outstanding calls first. All three then write out what they have,
  mark the run interrupted and exit 143 — which is what
  `07_interrupt_preserves_data` asserts.

## All flags

All three implementations share the same interface:

```
--profile    NAME   AWS named profile (~/.aws/config)
--role       NAME   IAM role to assume in child accounts
                    (default: OrganizationAccountAccessRole)
--setup-role        Deploy a minimal read-only role via CloudFormation StackSet;
                    always auto-removed after scan
--ou         ID     Limit to a specific Organizational Unit (ou-xxxx-xxxxxxxx)
--include    IDS    Comma-separated account IDs to scan
--exclude    IDS    Comma-separated account IDs to skip
--output     FILE   Output file (default: discovery_<timestamp>.json)
--anonymize-tags    Drop every tag except Datafy's own; keep only hashed cluster/node
                    group/ASG names plus is_k8s and managed_by
--anonymize-accounts
                    Replace account IDs with stable aliases everywhere in the output
--print-role-template
                    Print the CloudFormation template --setup-role would deploy,
                    and exit. Contacts nothing and deploys nothing
--version           Print version and exit
```

### Reviewing the role before deploying it

`--setup-role` creates a role in every target account, so it is reasonable to
want to read the template first. Print it, and nothing else happens — no AWS
call is made:

```bash
./discovery --print-role-template
```

All three implementations print the same template, byte for byte.

## Output format

One JSON object per line. Every line carries a `record_type` — `region`, `account`, or `summary`.

The file named by `--output` is the tool's only product. Progress, warnings and
the closing tallies go to **stderr** in all three implementations, so stdout
stays clean for the caller and an operator who redirects it still sees which
accounts were skipped. (`--version` is the exception: there the version *is* the
output, so it goes to stdout.)

### Region records

One per account × region:

```json
{
  "record_type": "region",
  "account_id": "123456789012",
  "region": "us-east-1",
  "status": "ok",
  "scanned_at": "2026-06-10T14:30:00Z",
  "errors": [],
  "volumes": [...],
  "instances": [...],
  "amis": [...],
  "snapshots": [...],
  "dlm_policies": [...],
  "backup_plans": [...]
}
```

`status` tells you whether the data is trustworthy — an empty region and an
inaccessible one are no longer indistinguishable:

| `status` | Meaning |
|---|---|
| `ok` | Every API call succeeded. Empty arrays mean the region really is empty. |
| `partial` | Some calls were denied or failed. The data is incomplete; `errors` says which calls and why. |
| `failed` | The region could not be read at all. All arrays are empty and `errors` explains why. |

`errors` entries name the API and the reason, e.g.
`"ec2:DescribeVolumes: AccessDenied: User is not authorized to perform..."`.

### Account records

Emitted only for accounts that were never scanned, so a missing account is
always visible in the file itself:

```json
{
  "record_type": "account",
  "account_id": "234567890123",
  "status": "skipped",
  "reason": "cannot assume role OrganizationAccountAccessRole: AccessDenied: ...",
  "scanned_at": "2026-06-10T14:30:00Z"
}
```

`skipped` means the role could not be assumed; `failed` means the role was
assumed but the scan could not start (for example `ec2:DescribeRegions` was
denied).

### Summary record

Always the **last** line, so a truncated upload is obvious and coverage is
answerable from the shared file alone:

```json
{
  "record_type": "summary",
  "tool_version": "0.2.0",
  "scanned_at": "2026-06-10T14:35:00Z",
  "interrupted": false,
  "accounts_total": 900,
  "accounts_scanned": 880,
  "accounts_skipped": 15,
  "accounts_failed": 5,
  "regions_scanned": 15840,
  "regions_partial": 12,
  "regions_failed": 8
}
```

`interrupted` is `true` when the run was stopped by Ctrl+C, a timeout or a
supervisor. The tool writes out everything it had already collected, so a
partial file is still useful — just don't read it as full coverage.

All timestamps are RFC3339 UTC with a `Z` suffix, in every implementation.

### Checking coverage

```bash
# Did the run cover everything?
tail -1 discovery_*.json | jq

# Which accounts were never scanned, and why?
jq -r 'select(.record_type == "account") | "\(.account_id)\t\(.status)\t\(.reason)"' discovery_*.json

# Which regions came back incomplete?
jq -r 'select(.record_type == "region" and .status != "ok")
       | "\(.account_id)/\(.region)\t\(.status)\t\(.errors | join("; "))"' discovery_*.json
```

Concatenate output from multiple runs (each run keeps its own summary line):

```bash
cat run1.json run2.json > combined.json
```
