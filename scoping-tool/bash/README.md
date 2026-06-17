# Datafy Discovery Tool — Bash

A portable bash implementation of the discovery tool.

See the [main README](../README.md) for what the tool collects, how it accesses accounts, IAM requirements, and output format.

## Requirements

- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
- [jq](https://stedolan.github.io/jq/) (`brew install jq` / `apt install jq`)
- bash 4.3+ (macOS ships with bash 3 — see note below)

## Usage

### Scan all accounts (role already exists in all accounts)

```bash
chmod +x discovery.sh
./discovery.sh --profile myprofile
```

### Scan with auto-provisioned role

```bash
./discovery.sh --profile myprofile --setup-role
```

### Limit to an OU

```bash
./discovery.sh --profile myprofile --ou ou-ab12-xxxxxxxx
```

### Specific or excluded accounts

```bash
./discovery.sh --profile myprofile --include 123456789012,234567890123
./discovery.sh --profile myprofile --exclude 999999999999
```

### Custom role name

```bash
./discovery.sh --profile myprofile --role MyReadOnlyRole
```

## All flags

```
--profile    NAME   AWS named profile (~/.aws/config)
--role       NAME   IAM role to assume in child accounts (default: OrganizationAccountAccessRole)
--setup-role        Deploy a minimal read-only role via StackSet; auto-removed after scan
--ou         ID     Limit to this Organizational Unit (ou-xxxx-xxxxxxxx)
--include    IDS    Comma-separated account IDs to scan
--exclude    IDS    Comma-separated account IDs to skip
--output     FILE   Output file (default: discovery_<timestamp>.json)
```

## macOS note

macOS ships with bash 3.2, which does not support `mapfile` or associative arrays. Install a modern bash:

```bash
brew install bash
/opt/homebrew/bin/bash discovery.sh --profile myprofile
```
