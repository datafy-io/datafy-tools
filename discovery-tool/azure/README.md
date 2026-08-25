# Datafy Discovery Tool — Azure

Inventories managed disks, virtual machines, scale sets, snapshots, images and
backup policies across every subscription in an Azure tenant. Used to scope a
Datafy engagement before installation.

**Read-only. No writes, no mutations. Safe to run in production.**

This is the Azure edition. The [AWS edition](../README.md) lives alongside it and
collects the equivalent data from an AWS Organization.

## What it collects

| Data | Fields |
|---|---|
| Managed disks | ID, name, resource group, location, zones, SKU, size, state, IOPS, MB/s, performance tier, bursting, OS type, encryption, create option, source, creation time, attached VM, tags |
| Virtual machines | ID, name, resource group, location, zones, VM size, VM ID, provisioning state, **power state**, OS type, licence type, priority, availability set, scale set, OS disk, data disks, image reference, tags |
| Scale sets | ID, name, resource group, location, zones, SKU, capacity, orchestration mode, OS/data disk profile, tags |
| Snapshots | ID, name, resource group, location, SKU, size, incremental flag, OS type, encryption, source disk, creation time, tags |
| Images | ID, name, resource group, location, Hyper-V generation, source VM, OS type and state, disk sizes, tags |
| Backup vaults | Recovery Services vaults and Data Protection backup vaults |
| Backup policies | Policy name, vault, management type, datasource types, protected item count |

Output is one JSON object per subscription (JSONL format), followed by a summary
record. Subscriptions that could not be scanned are recorded in the file with a
reason — see [Output format](#output-format).

## How this differs from the AWS edition

Two things about Azure change the shape of the tool, and both are visible in the
output.

**There is no role to assume.** AWS needs `sts:AssumeRole` into each member
account, which is why the AWS edition has `--role` and `--setup-role` and a
CloudFormation StackSet to provision one. Azure has none of that: a single
identity holding **Reader** at the tenant root management group reads every
subscription directly. So there is no role setup step, nothing is created in
your tenant, and nothing has to be cleaned up afterwards.

**A record is a subscription, not a region.** AWS's EC2 APIs are regional, so the
AWS edition makes one set of calls per account × region and reports a status per
region. Azure Resource Manager list calls are scoped to a *subscription* and
return every region at once — `disks.list()` on a subscription returns its disks
in all locations in one paginated call. That means a denied read costs a whole
subscription rather than one region, so status lives on the subscription record
and each resource carries its own `location`. A `locations` array on each record
rolls up the locations that subscription actually has resources in.

The practical effect is that an Azure scan is far cheaper: roughly six calls per
subscription, against the AWS edition's six calls per region per account.

## Prerequisites

- **Python 3.9+**
- **`pip install azure-identity`** — the only dependency. It brings `azure-core`,
  which carries the HTTP pipeline the tool uses.
- An Azure identity with Reader on the subscriptions you want scanned.

Azure Cloud Shell has `azure-identity` preinstalled and is already signed in, so
there is nothing to set up there.

## Signing in

The tool uses `DefaultAzureCredential`, so any of the usual ways of being signed
in works:

```bash
az login                            # Azure CLI — simplest
az login --tenant <tenant-id>       # a specific tenant
```

```bash
export AZURE_TENANT_ID=...          # service principal
export AZURE_CLIENT_ID=...
export AZURE_CLIENT_SECRET=...
```

Inside Azure Cloud Shell, or on a VM or AKS pod with a managed identity, no
sign-in step is needed at all.

If the tool cannot sign in for itself — a CI job handed a token, a restricted
jump host, or you would simply rather do the authenticating yourself — hand it a
token directly:

```bash
export AZURE_ACCESS_TOKEN=$(az account get-access-token \
  --resource https://management.azure.com --query accessToken -o tsv)
```

The token is used as given and never refreshed, so a scan that outlives it fails
loudly rather than quietly losing subscriptions.

## Permissions

The identity needs **Reader** on everything you want scanned. Reader is a
built-in role and grants no write access of any kind.

### Grant it once, for the whole tenant

Assigning Reader at the tenant root management group covers every current and
future subscription beneath it:

```bash
az role assignment create \
  --assignee <user-or-service-principal-object-id> \
  --role Reader \
  --scope /providers/Microsoft.Management/managementGroups/<tenant-root-group-id>
```

> Granting a role at the root management group requires the **Global
> Administrator** to have elevated access at least once
> (`az rest --method post --url "/providers/Microsoft.Authorization/elevateAccess?api-version=2016-07-01"`),
> or an existing User Access Administrator at that scope.

### Or per subscription

If tenant-wide Reader is more than you want to grant, assign it per
subscription. Anything not covered still appears in the output, marked `failed`
with the RBAC error — coverage gaps are never silent.

```bash
az role assignment create \
  --assignee <object-id> --role Reader \
  --scope /subscriptions/<subscription-id>
```

### What Reader is used for

The tool calls only these, all reads:

| Operation | Purpose |
|---|---|
| `Microsoft.Resources/subscriptions/read` | Enumerate subscriptions |
| `Microsoft.Management/managementGroups/descendants/read` | Only with `--management-group` |
| `Microsoft.Compute/disks/read` | Managed disk inventory |
| `Microsoft.Compute/virtualMachines/read` | VM inventory and power state |
| `Microsoft.Compute/virtualMachineScaleSets/read` | Scale set inventory |
| `Microsoft.Compute/snapshots/read` | Snapshot inventory |
| `Microsoft.Compute/images/read` | Managed image inventory |
| `Microsoft.RecoveryServices/vaults/read` and `.../backupPolicies/read` | Classic backup policies |
| `Microsoft.DataProtection/backupVaults/read` and `.../backupPolicies/read` | Disk backup policies |

## Quick start

```bash
pip install azure-identity
az login
python3 discovery.py
```

## Scope options

By default the tool scans every subscription the signed-in identity can see. Use
these flags to narrow it:

| Flag | Description |
|---|---|
| `--tenant ID` | Limit to subscriptions in this Microsoft Entra tenant |
| `--management-group ID` | Limit to subscriptions beneath a management group, nested ones included |
| `--include IDS` | Scan only these subscription IDs (comma-separated) |
| `--exclude IDS` | Skip these subscription IDs (comma-separated) |

An `--include` id the identity cannot see is called out in a warning rather than
quietly producing a shorter run.

## Rate limits and retries

Azure Resource Manager enforces per-subscription read quotas, and a tenant-wide
scan runs into them. A throttled call comes back `429` with a `Retry-After`
header. The tool pins its retry policy — **10 total attempts**, exponential
backoff with jitter, honouring `Retry-After` — rather than leaving it to the
client default, so a run is reproducible and rides out a burst the same way the
AWS edition does.

| Variable | Default | Meaning |
|---|---|---|
| `AZURE_MAX_ATTEMPTS` | `10` | **Total** attempts per call, the first one included |
| `AZURE_RETRY_BACKOFF` | `0.8` | Backoff factor, in seconds |
| `AZURE_RETRY_BACKOFF_MAX` | `120` | Backoff ceiling, in seconds |

`AZURE_MAX_ATTEMPTS` counts *attempts*, matching `AWS_MAX_ATTEMPTS` in the AWS
edition. azure-core's own `retry_total` counts *retries* and is therefore one
lower; the tool converts, so the same number means the same thing in both
editions.

If a call does exhaust its attempts, the subscription is recorded as `partial` or
`failed` with the Azure error code in `errors` — never as an empty subscription.
So throttling costs coverage visibly, and `tail -1` on the output tells you it
happened.

## Sovereign clouds and pinned API versions

The tool talks to `https://management.azure.com` and pins an api-version per
resource type, so the response shape is reproducible rather than whatever the
provider currently defaults to.

For Azure Government, Azure China or a private ARM endpoint:

```bash
export AZURE_ARM_ENDPOINT=https://management.usgovcloudapi.net
```

`AZURE_ARM_SCOPE` follows the endpoint automatically, so overriding one does not
leave the other pointing at the public cloud.

Every pinned api-version is individually overridable, for the case where a
provider in your cloud does not offer the version pinned here —
`AZURE_API_DISKS`, `AZURE_API_VIRTUAL_MACHINES`, `AZURE_API_SNAPSHOTS`,
`AZURE_API_IMAGES`, `AZURE_API_SCALE_SETS`, `AZURE_API_RSV_VAULTS`,
`AZURE_API_RSV_POLICIES`, `AZURE_API_DP_VAULTS`, `AZURE_API_DP_POLICIES`,
`AZURE_API_SUBSCRIPTIONS`, `AZURE_API_DESCENDANTS`. A version a provider rejects
is reported as an error against the subscription, never as an empty result.

## All flags

```
--tenant           ID    Limit to subscriptions in this Entra tenant
--management-group ID    Limit to subscriptions beneath this management group
--include          IDS   Comma-separated subscription IDs to scan
--exclude          IDS   Comma-separated subscription IDs to skip
--output           FILE  Output file (default: discovery_azure_<timestamp>.json)
--version                Print version and exit
```

## Output format

One JSON object per line. Every line carries a `record_type` — `subscription` or
`summary`.

The file named by `--output` is the tool's only product. Progress, warnings and
the closing tallies go to **stderr**, so stdout stays clean for the caller and an
operator who redirects it still sees which subscriptions were skipped.
(`--version` is the exception: there the version *is* the output, so it goes to
stdout.)

### Subscription records

One per subscription:

```json
{
  "record_type": "subscription",
  "subscription_id": "aaaaaaaa-0000-0000-0000-000000000001",
  "subscription_name": "Production",
  "tenant_id": "11111111-1111-1111-1111-111111111111",
  "subscription_state": "Enabled",
  "status": "ok",
  "reason": null,
  "scanned_at": "2026-08-25T14:30:00Z",
  "errors": [],
  "locations": ["eastus", "westeurope"],
  "disks": [...],
  "virtual_machines": [...],
  "scale_sets": [...],
  "snapshots": [...],
  "images": [...],
  "backup_vaults": [...],
  "backup_policies": [...]
}
```

`status` tells you whether the data is trustworthy — an empty subscription and an
inaccessible one are never indistinguishable:

| `status` | Meaning |
|---|---|
| `ok` | Every ARM call succeeded. Empty arrays mean the subscription really is empty. |
| `partial` | Some calls were denied or failed. The data is incomplete; `errors` says which calls and why. |
| `failed` | The subscription could not be read at all. All arrays are empty and `errors` explains why. |
| `skipped` | Azure does not report the subscription as `Enabled`, so it was never scanned. `reason` says which state it is in. |

`errors` entries name the provider and the reason, e.g.
`"Microsoft.Compute/disks: AuthorizationFailed: The client does not have authorization to perform action..."`.

### Summary record

Always the **last** line, so a truncated upload is obvious and coverage is
answerable from the shared file alone:

```json
{
  "record_type": "summary",
  "tool_version": "0.1.0",
  "cloud": "azure",
  "scanned_at": "2026-08-25T14:35:00Z",
  "interrupted": false,
  "subscriptions_total": 140,
  "subscriptions_scanned": 132,
  "subscriptions_partial": 3,
  "subscriptions_failed": 2,
  "subscriptions_skipped": 3
}
```

The four status counts partition the total, so nothing is counted twice and
nothing goes missing between them.

`interrupted` is `true` when the run was stopped by Ctrl+C, a timeout or a
supervisor. The tool writes out everything it had already collected and exits
`128 + signal` (143 for SIGTERM), so a partial file is still useful and a
wrapper can tell it apart from a clean run — just don't read it as full
coverage.

All timestamps are RFC3339 UTC with a `Z` suffix.

### Checking coverage

```bash
# Did the run cover everything?
tail -1 discovery_azure_*.json | jq

# Which subscriptions were not fully scanned, and why?
jq -r 'select(.record_type == "subscription" and .status != "ok")
       | "\(.subscription_id)\t\(.status)\t\(.reason // (.errors | join("; ")))"' discovery_azure_*.json

# How much unattached disk is sitting there?
jq -r 'select(.record_type == "subscription")
       | .disks[] | select(.state == "Unattached") | .size_gb' discovery_azure_*.json \
  | awk '{n++; total += $1} END {printf "%d unattached disks, %d GB\n", n, total}'

# Which VMs are stopped but still holding disks?
jq -r 'select(.record_type == "subscription")
       | .virtual_machines[] | select(.power_state == "deallocated")
       | "\(.name)\t\(.vm_size)"' discovery_azure_*.json
```

Concatenate output from multiple runs (each run keeps its own summary line):

```bash
cat run1.json run2.json > combined.json
```

## Tests

```bash
./test/run_tests.sh          # every case
./test/run_tests.sh 02 08    # cases matching these patterns
```

Each case in `test/cases/` describes the tenant it needs as a scenario —
subscriptions, resource counts, which providers are denied, whether ARM
throttles — and then asserts on what came out.

They all talk to `test/lib/fake_arm.py`, a fake Azure Resource Manager reached
through `AZURE_ARM_ENDPOINT`, so the real `azure-core` pipeline is exercised:
its credential policy, its retry policy and its `nextLink` pagination all run
exactly as they would against Azure. The fake speaks **HTTPS** with a
certificate it generates at startup, because azure-core refuses to attach a
bearer token to an unencrypted URL — weakening that in the tool to make it
testable would mean testing a tool nobody runs.

| Case | Covers |
|---|---|
| `00_smoke` | A healthy small tenant produces the documented records |
| `01_pagination` | Multi-page result sets arrive whole, and distinct |
| `02_denied_vs_empty` | An empty subscription is distinguishable from a denied one |
| `03_scope_flags` | `--include` / `--exclude`, and an id the identity cannot see |
| `04_management_group` | Nested subtree scoping; an empty and an unknown group |
| `05_disabled_subscription` | A non-Enabled subscription is recorded as skipped |
| `06_summary_record` | Coverage is answerable from the output alone |
| `07_interrupt_preserves_data` | A killed run keeps what it collected, and exits 143 |
| `08_throttling_retried` | A throttled call is retried, and reported if it runs out |
| `09_unwritable_output` | An unwritable `--output` path fails loudly and early |
| `10_diagnostics_on_stderr` | The file is the only product; stdout stays clean |
| `11_corrupt_payload` | An unparseable response is reported, not read as empty |
| `12_concurrency_ceiling` | Peak parallelism stays within the documented cap |
| `13_expand_rejected` | A rejected `$expand` costs power state, not the VM list |
| `14_stress_large_subscription` | 4000 disks in one subscription arrive whole |

### Requirements

`jq` and `curl`, plus a Python that has `azure-identity` installed. Point
`DISCOVERY_PYTHON` at a virtualenv if the default `python3` does not have it:

```bash
DISCOVERY_PYTHON=/path/to/venv/bin/python ./test/run_tests.sh
```

## Why raw ARM JSON rather than the management SDKs

The tool calls ARM through `azure-core`'s pipeline and reads the raw JSON,
rather than using `azure-mgmt-compute` and friends. Two reasons:

- **One dependency instead of seven.** A design partner running this in Cloud
  Shell installs `azure-identity` and nothing else.
- **A stable output shape.** The generated SDK models reshape between major
  versions — v38 of `azure-mgmt-compute` moved every property under
  `.properties`, renamed `diskMBpsReadWrite` to `disk_m_bps_read_write`, and
  renders enums as `DiskState.ATTACHED` rather than `Attached`. A discovery file
  whose field names depend on which SDK version the customer happened to install
  is not comparable between runs. The ARM wire format is versioned by the
  `api-version` this tool pins.
