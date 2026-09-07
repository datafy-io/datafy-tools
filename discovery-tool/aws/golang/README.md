# Datafy Discovery Tool — Go

A fast, single-binary implementation of the discovery tool.

See the [main README](../README.md) for what the tool collects, how it accesses accounts, IAM requirements, and output format.

## Download

Pre-built binaries for Linux, macOS, and Windows are available on the [Releases](https://github.com/datafy-io/datafy-tools/releases) page.

## Build from source

```bash
cd golang
go build -o discovery .
```

## Usage

### Scan all accounts (role already exists in all accounts)

```bash
./discovery -profile myprofile
```

### Scan with auto-provisioned role

```bash
./discovery -profile myprofile -setup-role
```

### Limit to an OU

```bash
./discovery -profile myprofile -ou ou-ab12-xxxxxxxx
```

### Specific or excluded accounts

```bash
./discovery -profile myprofile -include 123456789012,234567890123
./discovery -profile myprofile -exclude 999999999999
```

### Custom role name

```bash
./discovery -profile myprofile -role MyReadOnlyRole
```

## All flags

```
-profile    AWS named profile from ~/.aws/config
-role       IAM role to assume in each child account (default: OrganizationAccountAccessRole)
-setup-role Deploy a minimal read-only role via StackSet; always auto-removed after scan
-ou         Limit scan to a specific Organizational Unit (ou-xxxx-xxxxxxxx)
-include    Comma-separated list of account IDs to scan
-exclude    Comma-separated list of account IDs to skip
-output     Output file path (default: discovery_YYYYMMDD_HHMMSS.json)
```

## Performance

The tool runs with three levels of parallelism:
- Up to 20 accounts concurrently
- Up to 10 regions per account concurrently
- All API calls within a region run concurrently

A 159-account organization with ~20 enabled regions scans in approximately 2–3 minutes.
