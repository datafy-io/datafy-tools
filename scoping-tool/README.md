# Datafy Scoping Tool

Inventories EBS volumes, EC2 instances, AMIs, snapshots, DLM policies, and AWS Backup plans across all accounts in an AWS Organization. Used to scope Datafy migrations before engagement.

Output is one JSON object per account × region (JSONL format), identical across all three implementations.

## Implementations

| | [Python](python/) | [Go](golang/) | [Bash](bash/) |
|---|---|---|---|
| **Requirements** | Python 3.8+, boto3 | Pre-built binary or Go 1.21+ | aws-cli v2, jq |
| **Best for** | CloudShell, quick runs | Speed, no dependencies | Minimal environments |
| **Parallelism** | ThreadPoolExecutor | Goroutines | Background jobs |

## Quick start

### Python (recommended for CloudShell)

```bash
pip install boto3
python discovery.py --profile myprofile
```

### Go (recommended for speed)

Download the binary for your platform from [Releases](https://github.com/datafy-io/datafy-tools/releases), then:

```bash
./discovery --profile myprofile
```

### Bash

```bash
chmod +x bash/discovery.sh
./bash/discovery.sh --profile myprofile
```

## Common flags

All three tools share the same interface:

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

## IAM permissions

### Management account (where you run the tool)

The identity you run the tool with needs:

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
    },
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
  ]
}
```

Notes:
- `organizations:List*` actions do not support resource-level permissions in IAM — `*` is required by AWS.
- `sts:AssumeRole` is scoped to the two role names the tool uses. If you override `--role MyCustomRole`, add `arn:aws:iam::*:role/MyCustomRole` to that resource list.
- `StackSetManagement` is scoped to the `DatafyDiscovery` StackSet created by `--setup-role` only.
- The `StackSetManagement` statement is only required when using `--setup-role`.

### Child account role (`--setup-role`)

When you pass `--setup-role`, the tool uses a CloudFormation StackSet to deploy a read-only IAM role (`DatafyDiscoveryRole`) to every target account. The role is automatically deleted after the scan.

The deployed role grants:

| Statement | Actions | Resource | Notes |
|-----------|---------|----------|-------|
| `EC2DescribeReadOnly` | `ec2:DescribeVolumes`, `ec2:DescribeInstances`, `ec2:DescribeRegions`, `ec2:DescribeImages`, `ec2:DescribeSnapshots` | `*` | EC2 Describe APIs do not support resource-level permissions in IAM — `*` is required by AWS |
| `DLMPoliciesReadOnly` | `dlm:GetLifecyclePolicies` | `arn:aws:dlm:*:*:policy/*` | Scoped to DLM lifecycle policies only |
| `BackupPlansReadOnly` | `backup:ListBackupPlans` | `arn:aws:backup:*:*:backup-plan:*` | Scoped to Backup plans only |

The role can only be assumed by the management account (`arn:aws:iam::<mgmt-account>:root`) and has no write permissions.

### Bring your own role

Skip `--setup-role` and use `--role` to specify an existing role that already has the permissions above:

```bash
./discovery --profile myprofile --role MyExistingReadOnlyRole
```

## Output format

One JSON object per line, one per account × region:

```json
{
  "account_id": "123456789012",
  "region": "us-east-1",
  "scanned_at": "2026-06-10T14:30:00Z",
  "volumes": [...],
  "instances": [...],
  "amis": [...],
  "snapshots": [...],
  "dlm_policies": [...],
  "backup_plans": [...]
}
```

Concatenate output from multiple runs:

```bash
cat run1.json run2.json > combined.json
```
