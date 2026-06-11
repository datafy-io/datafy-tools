# Datafy Discovery Tool — Bash

A portable bash script that inventories EBS volumes, EC2 instances, AMIs, snapshots, DLM policies, and AWS Backup plans across all accounts in an AWS Organization.

## Requirements

- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
- [jq](https://stedolan.github.io/jq/) (`brew install jq` / `apt install jq`)
- bash 4.3+ (macOS ships with bash 3 — install via `brew install bash`)

## Usage

```bash
chmod +x discovery.sh
./discovery.sh [options]

Options:
  --profile    NAME   AWS named profile (~/.aws/config)
  --role       NAME   IAM role to assume in child accounts (default: OrganizationAccountAccessRole)
  --setup-role        Deploy a minimal read-only role via StackSet; auto-removed after scan
  --ou         ID     Limit to this Organizational Unit (ou-xxxx-xxxxxxxx)
  --include    IDS    Comma-separated account IDs to scan
  --exclude    IDS    Comma-separated account IDs to skip
  --output     FILE   Output file (default: discovery_<timestamp>.json)
```

### Standard scan

```bash
./discovery.sh --profile myprofile
```

### Scan with auto-provisioned role

```bash
./discovery.sh --profile myprofile --setup-role
```

Deploys `DatafyDiscoveryRole` to every account via CloudFormation StackSet and **always removes it when done**, even if the scan fails.

### Limit to an OU

```bash
./discovery.sh --profile myprofile --ou ou-ab12-xxxxxxxx
```

### Specific accounts

```bash
./discovery.sh --profile myprofile --include 123456789012,234567890123
```

## Output format

Same JSONL format as the Python and Go versions — one JSON object per line, one per account × region:

```json
{"account_id":"123456789012","region":"us-east-1","scanned_at":"2026-06-10T14:30:00Z","volumes":[...],"instances":[...],...}
```

Concatenate output from multiple runs:

```bash
cat run1.json run2.json > combined.json
```

## macOS note

macOS ships with bash 3.2, which does not support `mapfile` or associative arrays. Install a modern bash:

```bash
brew install bash
# Then run with:
/opt/homebrew/bin/bash discovery.sh --profile myprofile
```
