# Datafy Discovery Tool — Go

A fast, single-binary AWS discovery tool that inventories EBS volumes, EC2 instances, AMIs, snapshots, DLM policies, and AWS Backup plans across all accounts in an AWS Organization.

## Download

Pre-built binaries for Linux, macOS, and Windows are available on the [Releases](https://github.com/datafy-io/datafy-tools/releases) page.

## Build from source

```bash
cd scoping-tool/golang
go build -o discovery .
```

## Usage

```
./discovery [flags]

Flags:
  -profile    AWS named profile from ~/.aws/config (required if not using default credentials)
  -role       IAM role to assume in each child account (default: OrganizationAccountAccessRole)
  -setup-role Deploy a minimal read-only role via StackSet; always auto-removed after scan
  -ou         Limit scan to a specific Organizational Unit (ou-xxxx-xxxxxxxx)
  -include    Comma-separated list of account IDs to scan (skips org lookup)
  -exclude    Comma-separated list of account IDs to skip
  -output     Output file path (default: discovery_YYYYMMDD_HHMMSS.json)
```

### Standard scan (role already exists)

```bash
./discovery -profile myprofile
```

### Scan with auto-provisioned role

Use `--setup-role` when `OrganizationAccountAccessRole` does not exist in all accounts, or when you want a minimal ephemeral role instead.

```bash
./discovery -profile myprofile -setup-role
```

The tool creates a CloudFormation StackSet that deploys `DatafyDiscoveryRole` to every account in the organization, runs the scan, and **always removes the StackSet when finished** — even if the scan fails.

### Scan a specific OU

```bash
./discovery -profile myprofile -ou ou-ab12-xxxxxxxx
```

### Scan specific accounts

```bash
./discovery -profile myprofile -include 123456789012,234567890123
```

### Exclude accounts

```bash
./discovery -profile myprofile -exclude 999999999999
```

## IAM permissions required

The identity running this tool (your profile) needs:

```json
{
  "Effect": "Allow",
  "Action": [
    "organizations:ListAccounts",
    "organizations:ListAccountsForParent",
    "organizations:ListRoots",
    "sts:AssumeRole"
  ],
  "Resource": "*"
}
```

If using `--setup-role`, additionally:

```json
{
  "Effect": "Allow",
  "Action": [
    "cloudformation:CreateStackSet",
    "cloudformation:CreateStackInstances",
    "cloudformation:DeleteStackInstances",
    "cloudformation:DeleteStackSet",
    "cloudformation:DescribeStackSetOperation"
  ],
  "Resource": "*"
}
```

The role assumed in each child account needs:

```json
{
  "Effect": "Allow",
  "Action": [
    "ec2:DescribeVolumes",
    "ec2:DescribeInstances",
    "ec2:DescribeRegions",
    "ec2:DescribeImages",
    "ec2:DescribeSnapshots",
    "dlm:GetLifecyclePolicies",
    "backup:ListBackupPlans"
  ],
  "Resource": "*"
}
```

## Output format

One JSON object per line (JSONL), one per account × region:

```json
{
  "account_id": "123456789012",
  "region": "us-east-1",
  "scanned_at": "2026-06-10T14:30:00Z",
  "volumes": [
    {
      "VolumeId": "vol-0abc123",
      "Name": "my-volume",
      "Size": 100,
      "VolumeType": "gp3",
      "State": "in-use",
      "Iops": 3000,
      "Throughput": 125,
      "Encrypted": true,
      "AvailabilityZone": "us-east-1a",
      "SnapshotId": "snap-0def456",
      "InstanceId": "i-0ghi789",
      "Device": "/dev/sda1",
      "Tags": [{"Key": "Name", "Value": "my-volume"}]
    }
  ],
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

## Performance

The tool runs with 3 levels of parallelism:
- Up to 20 accounts concurrently
- Up to 10 regions per account concurrently
- All API calls within a region run concurrently

A 159-account organization with ~20 enabled regions scans in approximately 2–3 minutes.
