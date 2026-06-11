# Datafy Discovery Tool

Inventories EBS volumes and EC2 instances across AWS accounts — used to scope a Datafy engagement before installation.

**Read-only. No writes, no mutations. Safe to run in production.**

## Requirements

- Python 3.9+
- `boto3` — ships with AWS CLI v2, or `pip install boto3`
- AWS credentials with access to the management account

## Usage

### Option A — Use an existing cross-account role

If your org already has a role that allows cross-account access (e.g. `OrganizationAccountAccessRole`):

```bash
# All accounts in the org
python3 discovery.py

# Specific OU only
python3 discovery.py --ou ou-xxxx-xxxxxxxx

# Custom role name
python3 discovery.py --role MyReadOnlyRole

# Skip specific accounts
python3 discovery.py --exclude 111111111111,222222222222
```

### Option B — Deploy a minimal role via StackSet (recommended for large orgs)

If you don't have an existing cross-account role, or if `OrganizationAccountAccessRole` is missing from some accounts, use `--setup-role`. This:

1. Creates a CloudFormation StackSet that deploys a minimal read-only role (`DatafyDiscoveryRole`) to every account in scope
2. Runs the scan
3. **Always removes the StackSet and role when done** — even if the scan fails

```bash
# All accounts
python3 discovery.py --setup-role

# Specific OU
python3 discovery.py --setup-role --ou ou-xxxx-xxxxxxxx

# Specific accounts only
python3 discovery.py --setup-role --include 111111111111,222222222222
```

> **Requires:** CloudFormation trusted access with AWS Organizations must be enabled.
> Run `aws organizations enable-aws-service-access --service-principal cloudformation.amazonaws.com` if you see a permissions error.

## What it collects (per account, per region)

| Data | Fields |
|---|---|
| EBS Volumes | ID, size, type, IOPS, throughput, state, encryption, attached instance, device, AZ, tags |
| EC2 Instances | ID, type, state, platform, AMI, AZ, root device, architecture, tags |
| AMIs | ID, name, description, platform, architecture |
| Snapshots | ID, volume ID, size, creation time, state, encryption, tags |
| DLM Policies | Policy list (nice-to-have) |
| AWS Backup Plans | Plan list (nice-to-have) |

## Output format

Each run produces a `.json` file (one JSON object per line, one per account+region).

```
discovery_20260610_143022.json
```

Each line:
```json
{"account_id": "123456789012", "region": "us-east-1", "scanned_at": "...", "volumes": [...], "instances": [...], ...}
```

**Files from multiple runs can be concatenated:**
```bash
cat discovery_*.json > all_accounts.json
```

## All flags

| Flag | Description |
|---|---|
| `--setup-role` | Deploy read-only role via StackSet, auto-removed after scan |
| `--role NAME` | Role name to assume in child accounts (default: `OrganizationAccountAccessRole`) |
| `--ou OU_ID` | Limit to a specific Organizational Unit |
| `--include ID,...` | Scan only these account IDs |
| `--exclude ID,...` | Skip these account IDs |
| `--output FILE` | Output file path (default: `discovery_<timestamp>.json`) |

## IAM permissions required to run the script

The credentials used to run the script need:

```json
{
  "Effect": "Allow",
  "Action": [
    "sts:GetCallerIdentity",
    "sts:AssumeRole",
    "organizations:ListAccounts",
    "organizations:ListAccountsForParent",
    "organizations:ListRoots",
    "organizations:DescribeOrganization",
    "cloudformation:CreateStackSet",
    "cloudformation:CreateStackInstances",
    "cloudformation:DeleteStackInstances",
    "cloudformation:DeleteStackSet",
    "cloudformation:DescribeStackSetOperation"
  ],
  "Resource": "*"
}
```

The last five (`cloudformation:*`) are only needed with `--setup-role`.
