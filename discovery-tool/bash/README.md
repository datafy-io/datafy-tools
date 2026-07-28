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

## Tests

The bash implementation has a test suite that runs `discovery.sh` end to end
against a mock AWS CLI — no AWS account or credentials needed:

```bash
./test/run_tests.sh          # all cases
./test/run_tests.sh 01 04    # only cases matching these patterns
```

`test/lib/mock_aws.sh` is installed on `PATH` as `aws` and is driven entirely by
`MOCK_*` environment variables (account list, region list, resource counts, and
which calls should be denied), so a case can describe the org it needs — from a
two-account smoke test to a region holding 4000 volumes.

Cases live in `test/cases/`:

| Case | Covers |
|---|---|
| `00_smoke` | A healthy small org produces the documented records |
| `01_stress_large_region` | 4000 volumes — the `jq: Argument list too long` crash |
| `02_stress_many_accounts` | 12 accounts × 4 regions — no lost or duplicated records |
| `03_stress_many_amis` | 3000 distinct AMIs — the `describe-images` argv overflow |
| `04_region_failure_vs_empty` | An empty region is distinguishable from a denied one |
| `05_account_skipped_reported` | Unreachable accounts appear in the file, with a reason |
| `06_summary_record` | Coverage is answerable from the output alone |
| `07_interrupt_preserves_data` | A killed run keeps what it already collected |
| `08_credential_expiry` | An expired session is reported, never shown as empty |
| `09_concurrency_ceiling` | Peak parallel calls stay within the RAM-derived cap |
| `10_corrupt_payload` | An unparseable response is reported, not read as empty |
| `11_pagination_not_capped` | Nothing disables or caps AWS CLI pagination |
| `12_write_failures` | An unwritable output or temp dir fails loudly |

For cross-implementation coverage see `test/parity/` in the repository root,
which runs bash, Python and Go against a shared fake AWS endpoint and diffs
their output.

## macOS note

macOS ships with bash 3.2, which does not support `mapfile` or associative arrays. Install a modern bash:

```bash
brew install bash
/opt/homebrew/bin/bash discovery.sh --profile myprofile
```
