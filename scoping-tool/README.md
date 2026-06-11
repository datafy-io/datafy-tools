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
