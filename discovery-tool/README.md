# Datafy Discovery Tool

Inventories EBS volumes, EC2 instances, AMIs, snapshots, DLM policies, and AWS Backup plans across all accounts in an AWS Organization. Used to scope a Datafy engagement before installation.

**Read-only. No writes, no mutations. Safe to run in production.**

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
| `dlm:GetLifecyclePolicies` | |
| `backup:ListBackupPlans` | |

The role must also trust the management account: `"Principal": {"AWS": "arn:aws:iam::<mgmt-account-id>:root"}`.

## Scope options

By default the tool scans all accounts in the organization. Use these flags to narrow scope:

| Flag | Description |
|---|---|
| `--ou ID` | Limit to a specific Organizational Unit (e.g. `ou-ab12-xxxxxxxx`) |
| `--include IDS` | Scan only these account IDs (comma-separated) |
| `--exclude IDS` | Skip these account IDs (comma-separated) |

## Implementations

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

### The parity harness — `test/parity/`

Where the behavioural suite asks whether each implementation is *correct*, the
parity harness asks whether they are *identical*: it runs one scenario through
all three and diffs the normalised output line for line. That catches drift the
per-case assertions would not think to look for — a renamed field, a differently
rounded number, a reordered array.

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
--version           Print version and exit
```

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
