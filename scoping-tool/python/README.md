# Datafy Discovery Tool — Python

See the [main README](../README.md) for what the tool collects, how it accesses accounts, IAM requirements, and output format.

## Requirements

- Python 3.9+
- `boto3` — ships with AWS CloudShell and AWS CLI v2, or `pip install boto3`
- AWS credentials with access to the management account

## Usage

### Scan all accounts (role already exists in all accounts)

```bash
python3 discovery.py --profile myprofile
```

### Scan with auto-provisioned role

```bash
python3 discovery.py --profile myprofile --setup-role
```

### Limit to an OU

```bash
python3 discovery.py --profile myprofile --ou ou-ab12-xxxxxxxx
```

### Specific or excluded accounts

```bash
python3 discovery.py --profile myprofile --include 111111111111,222222222222
python3 discovery.py --profile myprofile --exclude 999999999999
```

### Custom role name

```bash
python3 discovery.py --profile myprofile --role MyReadOnlyRole
```

## All flags

| Flag | Description |
|---|---|
| `--profile NAME` | AWS named profile (~/.aws/config) |
| `--role NAME` | Role to assume in child accounts (default: `OrganizationAccountAccessRole`) |
| `--setup-role` | Deploy read-only role via StackSet, auto-removed after scan |
| `--ou ID` | Limit to a specific Organizational Unit |
| `--include IDS` | Scan only these account IDs (comma-separated) |
| `--exclude IDS` | Skip these account IDs (comma-separated) |
| `--output FILE` | Output file path (default: `discovery_<timestamp>.json`) |
