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

**Most of the coverage for this implementation lives in `test/` at the
repository root**, not here. That suite runs every behavioural case against
bash, Python and Go alike, driving the real AWS CLI against a fake AWS endpoint:

```bash
../test/run_tests.sh --impl bash        # every case, bash only
../test/run_tests.sh --impl bash 01 04  # only cases matching these patterns
../test/run_tests.sh                    # all three implementations
```

What lives here is the handful of checks that are properties of `discovery.sh`
itself rather than of the records it produces, and so have no Python or Go
counterpart:

```bash
./test/run_tests.sh          # all cases
./test/run_tests.sh 00       # only cases matching these patterns
```

| Case | Covers |
|---|---|
| `00_pagination_flags` | Nothing disables or caps AWS CLI pagination |
| `01_tmpdir_failure` | An unwritable `$TMPDIR` fails loudly, and names the variable to change |

`--no-paginate`, `--max-items` and `--page-size` each make the CLI return a
prefix of the data and exit 0, which looks exactly like a small account rather
than a truncated scan. Python and Go have no equivalent — their paginators are
types, not flags. `$TMPDIR` matters here because only the bash implementation
stages its records through it, writing a file per region and per account and
concatenating them at the end.

`test/lib/mock_aws.sh` is installed on `PATH` as `aws` and is driven by `MOCK_*`
environment variables (account list, region list, resource counts), so these
cases need neither `python3` nor `go`.

## macOS note

macOS ships with bash 3.2, which does not support `mapfile` or associative arrays. Install a modern bash:

```bash
brew install bash
/opt/homebrew/bin/bash discovery.sh --profile myprofile
```
