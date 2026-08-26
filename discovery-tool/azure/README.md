# Datafy Discovery Tool — Azure

Inventories managed disks, virtual machines, scale sets, snapshots, images and
backup policies across every subscription in an Azure tenant. Used to scope a
Datafy engagement before installation.

**Read-only. No writes, no mutations. Safe to run in production.**

The one exception is [`--setup-role`](#--setup-role-letting-the-tool-grant-its-own-access),
which is off by default. With it, the tool assigns itself the built-in **Reader**
role for the duration of the scan and always removes it again. Nothing else in
the tool writes anything, ever.

This is the Azure edition. See the [AWS edition](../aws/) for AWS Organizations,
or the [overview](../README.md) for what the two have in common.

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
account, which is why the AWS edition has `--role` and a CloudFormation StackSet
to provision one. Azure has none of that: a single identity holding **Reader** at
the tenant root management group reads every subscription directly, so there is
no `--role` here and no per-subscription bootstrapping.

`--setup-role` still exists, and does the same job the StackSet does — grant the
access, scan, always take it away again — but it is one PUT and one DELETE
rather than N stack instances, because Azure RBAC inherits down the management
group hierarchy.

**A record is a subscription, not a region.** AWS's EC2 APIs are regional, so the
AWS edition makes one set of calls per account × region and reports a status per
region. Azure Resource Manager list calls are scoped to a *subscription* and
return every region at once — `disks.list()` on a subscription returns its disks
in all locations in one paginated call. That means a denied read costs a whole
subscription rather than one region, so status lives on the subscription record
and each resource carries its own `location`. A `locations` array on each record
rolls up the locations that subscription actually has resources in.

The practical effect is that an Azure scan is far cheaper: roughly seven calls
per subscription, against the AWS edition's six calls per region per account.

## VM power state

A stopped VM still pays for its disks, so `power_state` is collected for every
virtual machine alongside the inventory.

It comes from a second ARM call — the run-time status pass — because Azure
returns a VM's run state separately from its configuration. If your identity can
list VMs but not their run-time status, every VM is still reported with
`power_state: null` and the subscription is marked `partial` with the reason, so
the missing field is always explained rather than silently absent.

## Implementations

Three implementations, one interface, one output format. All three read ARM
directly and produce byte-identical files — the [parity harness](#the-parity-harness)
diffs them line for line.

| | [Python](python/) | [Go](golang/) | [Bash](bash/) |
|---|---|---|---|
| **Requirements** | Python 3.9+, `azure-identity` | Pre-built binary, or Go 1.21+ | `curl`, `jq`, bash 3.2+ |
| **Best for** | Cloud Shell, quick runs | Speed, no runtime dependencies | Minimal or locked-down environments |
| **Sign-in methods** | Azure CLI, managed identity, service principal, `AZURE_ACCESS_TOKEN` | Same as Python | Azure CLI or `AZURE_ACCESS_TOKEN` |

Azure Cloud Shell has `azure-identity` preinstalled and is already signed in, so
the Python implementation needs nothing set up there.

The bash implementation talks to ARM with `curl` rather than shelling out to
`az` for each request: `az` pays Python interpreter startup on every
invocation, and a tenant-wide scan makes thousands of calls. It uses `az` once,
for a token, and not at all if `AZURE_ACCESS_TOKEN` is set — which is what lets
it run somewhere the CLI is not installed.

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

### `--setup-role`: letting the tool grant its own access

If you would rather not set anything up in advance, `--setup-role` does it for
you. It assigns Reader to the signed-in identity at the tenant root management
group (or at `--management-group`), **waits for the assignment to take effect**,
scans, and then always removes it — including when the scan fails, is
interrupted, or cannot write its output file.

```bash
python3 discovery.py --setup-role
```

This is the counterpart of the AWS edition's `--setup-role` StackSet, and the
only part of the tool that writes anything.

| | Without the flag (default) | With `--setup-role` |
|---|---|---|
| Writes to your tenant | Nothing, ever | One role assignment, removed afterwards |
| Permission needed | Reader, granted beforehand | Owner, User Access Administrator, or Role Based Access Control Administrator |
| Coverage | Whatever the identity can already see | Every subscription in the tenant |

Details worth knowing:

- **It waits for the assignment to take effect.** Azure role assignments are not
  usable the instant they are created; propagation can take a few minutes. The
  tool polls until the new access works, reporting progress as it goes, and
  stops waiting after `AZURE_PROPAGATION_TIMEOUT` (default 300s) rather than
  hanging. Anything still out of reach by then is recorded in the output with a
  reason, as usual.
- **A standing grant is never revoked.** If Reader is already assigned, the tool
  says so, leaves it alone, and does not remove it at the end. Only assignments
  this run created are torn down.
- **Cleanup runs on every exit path.** If it somehow cannot, the tool prints the
  exact `az role assignment delete` command to run.
- **Granting at a tenant root management group** additionally requires the Global
  Administrator to have elevated access at least once
  (`az rest --method post --url "/providers/Microsoft.Authorization/elevateAccess?api-version=2016-07-01"`).
  If that has not happened, `--setup-role` fails with a message saying so, and
  the scan can be re-run without the flag.

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

**Python** (recommended for Cloud Shell):

```bash
pip install azure-identity
az login
python3 python/discovery.py
```

**Go** (recommended for speed):

```bash
az login
cd golang && go build -o discovery . && ./discovery
```

**Bash** (needs only `curl` and `jq`):

```bash
az login
./bash/discovery.sh
```

All three accept the same flags.

## Scope options

By default the tool scans every subscription the signed-in identity can see. Use
these flags to narrow it:

| Flag | Description |
|---|---|
| `--tenant ID` | Limit to subscriptions in this Microsoft Entra tenant |
| `--management-group ID` | Limit to subscriptions beneath a management group, nested ones included |
| `--include IDS` | Scan only these subscription IDs (comma-separated) |
| `--exclude IDS` | Skip these subscription IDs (comma-separated) |
| `--setup-role` | Grant Reader for the duration of the scan, then remove it |

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
--setup-role             Assign Reader to the signed-in identity for the duration
                         of the scan; always removed afterwards
--tenant           ID    Limit to subscriptions in this Entra tenant
--management-group ID    Limit to subscriptions beneath this management group
--include          IDS   Comma-separated subscription IDs to scan
--exclude          IDS   Comma-separated subscription IDs to skip
--output           FILE  Output file (default: discovery_azure_<timestamp>.json)
--version                Print version and exit
```

| Variable | Default | Meaning |
|---|---|---|
| `AZURE_PROPAGATION_TIMEOUT` | `300` | With `--setup-role`, how long to wait for the assignment to take effect, in seconds |
| `AZURE_PROPAGATION_POLL` | `10` | How often to re-check, in seconds |

## Knowing what you did *not* scan

Azure lists the subscriptions an identity **can already see**. A subscription
that no role assignment reaches is not reported as denied — it is simply not
returned. On its own, that would make a partially-granted tenant look identical
to a fully-scanned smaller one.

So the tool does not treat that list as the last word on what your tenant
contains. It also asks the management group hierarchy, which lists subscriptions
by membership rather than by access, and reconciles the two:

- A subscription in the hierarchy that the identity cannot read is written to
  the file as `failed`, with a reason naming the missing role assignment, and
  counts towards `subscriptions_total`.
- If the hierarchy cannot be read either, the run has no way to confirm what it
  is missing. It says so on stderr and records `scope_verified: false` in the
  summary, with a `scope_note` explaining why.

```bash
# Can these totals be read as full tenant coverage?
tail -1 discovery_azure_*.json | jq '{scope_verified, scope_note, subscriptions_total}'
```

`scope_verified: true` means the totals describe your tenant. `false` means they
describe what this identity could see, which may be less.

Using [`--setup-role`](#--setup-role-letting-the-tool-grant-its-own-access)
avoids the question entirely: Reader is assigned at the tenant root before the
scan starts, so every subscription is visible.

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
  "scope_verified": true,
  "scope_note": "scope checked against the tenant root management group",
  "subscriptions_total": 140,
  "subscriptions_scanned": 132,
  "subscriptions_partial": 3,
  "subscriptions_failed": 2,
  "subscriptions_skipped": 3
}
```

The four status counts partition the total, so nothing is counted twice and
nothing goes missing between them.

`scope_verified` says whether that total can be trusted as the whole tenant —
see [Knowing what you did *not* scan](#knowing-what-you-did-not-scan). When it
is `false`, the totals describe what this identity could see, which may be less
than the tenant contains.

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

Three suites, none of which needs an Azure subscription or credentials.

```bash
./test/run_tests.sh                     # every case, on all three implementations
./test/run_tests.sh --impl go 02        # one implementation, one case
./test/parity/run_parity.sh             # all three, output diffed line for line
```

### The behavioural suite — `test/`

Each case in `test/cases/` describes the tenant it needs as a scenario —
subscriptions, resource counts, which providers are denied, whether ARM
throttles, whether a subscription is visible at all — and then asserts on what
came out, without naming any implementation. Every case runs **once per
implementation**.

They all talk to `test/lib/fake_arm.py`, a stand-in Azure Resource Manager
reached through `AZURE_ARM_ENDPOINT`, so each implementation's real HTTP stack
is exercised end to end — azure-core's pipeline for Python, `net/http` for Go,
`curl` for bash — including their pagination and their error handling. Mocking
any one of them instead would only ever test that one. It is served over HTTPS,
so no implementation's transport security is relaxed in order to test it.

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
| `13_power_state` | Run state comes from the status pass, and losing it costs one field rather than the fleet |
| `14_stress_large_subscription` | 4000 disks in one subscription arrive whole |
| `15_partial_grant` | A half-granted tenant cannot pass itself off as fully scanned |
| `16_scope_unverifiable` | With no denominator available, the file says so |
| `17_setup_role` | `--setup-role` grants, scans, and always cleans up |
| `18_setup_role_propagation` | The scan waits for RBAC to propagate, and bounds that wait |

### The parity harness

Where the behavioural suite asks whether each implementation is *correct*, the
parity harness asks whether they are *identical*: one scenario through all
three, output diffed line for line. That catches drift the per-case assertions
would not think to look for — a renamed field, a differently rounded number, a
reordered array, a null that became an empty string.

Only the wall-clock timestamp is excluded from the diff. Every field name, every
value and every error string has to match exactly.

### Requirements

`jq` and `curl`, plus the toolchain of each implementation under test: a Python
with `azure-identity` for the Python one, `go` for the Go one, nothing extra for
bash. The stand-in ARM is itself Python and generates a TLS certificate, so a
Python with `cryptography` is needed even to test only bash or Go.

Point `DISCOVERY_PYTHON` at a virtualenv if the default `python3` does not have
what is needed:

```bash
DISCOVERY_PYTHON=/path/to/venv/bin/python ./test/run_tests.sh
```

An implementation whose toolchain is missing is reported as skipped rather than
silently passing.

### Differences the suites deliberately allow

The three are held to the same output, the same statuses and the same exit
codes. What is left to differ follows from the runtime:

- **Sign-in methods.** Python and Go use `DefaultAzureCredential`, so they cover
  managed identity, workload identity and service principal environment
  variables. Bash uses the Azure CLI or `AZURE_ACCESS_TOKEN` — which is also
  what lets it run where neither an SDK nor the CLI is installed.
- **Private CA configuration.** Each stack has its own convention:
  `REQUESTS_CA_BUNDLE` for Python, `CURL_CA_BUNDLE` for bash, and
  `AZURE_CA_BUNDLE` or `SSL_CERT_FILE` for Go. Go reads it explicitly because on
  macOS it uses the platform verifier and would otherwise ignore it.

## Why raw ARM JSON

All three implementations call Azure Resource Manager directly and read the raw
JSON, rather than going through the `azure-mgmt-*` service libraries or the
generated Go packages. Two reasons:

- **Almost nothing to install.** The Python implementation needs one package;
  the bash one needs `curl` and `jq`; the Go one is a single static binary.
- **A stable output shape.** The field names in the output are fixed by the
  `api-version` this tool pins, so two runs are comparable regardless of which
  library versions happen to be installed — and the three implementations can be
  held to byte-identical output, which is what the parity harness checks.
