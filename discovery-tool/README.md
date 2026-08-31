# Datafy Discovery Tool

Inventories the block storage and compute footprint of a cloud estate, so a
Datafy engagement can be scoped before installation.

**Read-only. Safe to run in production.**

Pick the edition for your cloud:

| | [**AWS**](aws/) | [**Azure**](azure/) |
|---|---|---|
| **Scope** | Every account in an AWS Organization | Every subscription in an Azure tenant |
| **Collects** | EBS volumes, EC2 instances, AMIs, snapshots, DLM policies, AWS Backup plans | Managed disks, VMs, scale sets, snapshots, images, backup vaults and policies |
| **Run it from** | The management (root) account | Any identity with Reader across the tenant |
| **Implementations** | Python, Go, Bash | Python, Go, Bash |
| **Requires** | Python 3.8+ and boto3, a prebuilt binary, or aws-cli v2 + jq | Python 3.9+ and `azure-identity`, a prebuilt binary, or curl + jq |

## Quick start

**AWS** — see [aws/README.md](aws/README.md) for role setup and IAM policies.

```bash
cd aws/python && pip install boto3 && python3 discovery.py --profile myprofile
```

**Azure** — see [azure/README.md](azure/README.md) for permissions.

```bash
cd azure/python && pip install azure-identity && az login && python3 discovery.py
```

## What the two editions have in common

Both are read-only, both write a single JSONL file, and both are built so that
**a gap in coverage is always visible in that file** rather than showing up as a
smaller result that looks complete.

- **One record per unit of scope**, plus a `summary` record as the last line —
  so a truncated upload is obvious.
- **A `status` on every record.** An empty account or subscription and an
  inaccessible one are never indistinguishable: `ok`, `partial`, `failed` and
  `skipped` each mean something specific, and failures carry the cloud
  provider's own error code.
- **Results are written as work completes**, so an interrupted run keeps
  everything already collected, marks itself interrupted, and exits `128+signal`
  rather than claiming success.
- **The output file is the only product.** Progress and warnings go to stderr,
  so stdout stays clean and anything that went wrong is still recorded in the
  file you send us.
- **Pinned retry behaviour**, because a large estate will be throttled. A call
  that runs out of attempts costs coverage *visibly*.

Send the file as-is, including partial runs — the statuses are what let us tell
a gap from an empty environment.

## Where the editions differ

The two clouds are not symmetrical, and the tools follow their cloud rather than
pretending otherwise. The main differences:

| | AWS | Azure |
|---|---|---|
| **Reaching each account** | Assumes an IAM role per account | One Reader assignment covers the tenant |
| **Unit of a record** | Account × region | Subscription (each resource carries its own location) |
| **Cost of a denied read** | One region | One subscription |

Each edition's README explains its own model in full.

## Tests

Neither suite needs a cloud account or credentials.

```bash
# AWS
./aws/test/run_tests.sh             # every case, on all three implementations
./aws/test/parity/run_parity.sh     # all three, output diffed line for line
./aws/bash/test/run_tests.sh        # bash-internal checks

# Azure
./azure/test/run_tests.sh           # every case, on all three implementations
./azure/test/parity/run_parity.sh   # all three, output diffed line for line
```

Each edition holds its three implementations to one output format, checked by
its own parity harness.
