#!/usr/bin/env bash
# Datafy Discovery Tool — Azure (bash)
#
# Inventories managed disks, virtual machines, scale sets, snapshots, images and
# backup policies across every subscription in an Azure tenant.
# Read-only, unless --setup-role is used. Safe to run in production.
#
# Output is identical to the Python and Go implementations.
#
# Requires: curl, jq. The Azure CLI is used once, if present, to obtain a token —
# never per call. Talking to ARM directly with curl rather than shelling out to
# `az` for every request is what makes this implementation usable on a real
# tenant: `az` pays Python interpreter startup on each invocation, and a
# tenant-wide scan makes thousands of calls.
#
#   ./discovery.sh
#   ./discovery.sh --management-group mg-production
#   ./discovery.sh --setup-role

set -uo pipefail

VERSION="0.1.0"

# ── Configuration ─────────────────────────────────────────────────────────────

MAX_SUBSCRIPTION_JOBS=20   # subscriptions scanned in parallel
MAX_CALL_JOBS=8            # independent ARM calls in flight per subscription
MAX_ERROR_CHARS=400        # keep error strings readable in the output file
MAX_PAGES=10000            # nextLink guard — a loop must fail, not spin forever

ARM_ENDPOINT="${AZURE_ARM_ENDPOINT:-https://management.azure.com}"
ARM_ENDPOINT="${ARM_ENDPOINT%/}"
ARM_SCOPE="${AZURE_ARM_SCOPE:-${ARM_ENDPOINT}/.default}"

# Retry policy. Pinned rather than left to the client default so a run is
# reproducible, and so this implementation rides out a burst the same way the
# other two do — 10 total attempts, exponential backoff with jitter, honouring
# Retry-After. AZURE_MAX_ATTEMPTS counts TOTAL attempts, the first included.
MAX_ATTEMPTS="${AZURE_MAX_ATTEMPTS:-10}"
RETRY_BACKOFF="${AZURE_RETRY_BACKOFF:-0.8}"
RETRY_BACKOFF_MAX="${AZURE_RETRY_BACKOFF_MAX:-120}"
PROPAGATION_TIMEOUT="${AZURE_PROPAGATION_TIMEOUT:-300}"
PROPAGATION_POLL="${AZURE_PROPAGATION_POLL:-10}"

# The built-in Reader role. This GUID is the same in every Azure cloud.
READER_ROLE_ID="acdd72a7-3385-48ef-bd42-f606fba81ae7"
ASSIGNMENT_NAMESPACE="6f9d3a1e-0b6c-5f8a-9c2d-4e7b1a3f5c80"

# ARM api-versions, pinned so the response shape is reproducible. Each is
# overridable from the environment, and must match the other implementations.
API_SUBSCRIPTIONS="${AZURE_API_SUBSCRIPTIONS:-2022-12-01}"
API_DESCENDANTS="${AZURE_API_DESCENDANTS:-2021-04-01}"
API_DISKS="${AZURE_API_DISKS:-2023-04-02}"
API_SNAPSHOTS="${AZURE_API_SNAPSHOTS:-2023-04-02}"
API_VIRTUAL_MACHINES="${AZURE_API_VIRTUAL_MACHINES:-2023-09-01}"
API_SCALE_SETS="${AZURE_API_SCALE_SETS:-2023-09-01}"
API_IMAGES="${AZURE_API_IMAGES:-2023-09-01}"
API_RSV_VAULTS="${AZURE_API_RSV_VAULTS:-2023-04-01}"
API_RSV_POLICIES="${AZURE_API_RSV_POLICIES:-2023-02-01}"
API_DP_VAULTS="${AZURE_API_DP_VAULTS:-2023-05-01}"
API_DP_POLICIES="${AZURE_API_DP_POLICIES:-2023-05-01}"
API_ROLE_ASSIGNMENTS="${AZURE_API_ROLE_ASSIGNMENTS:-2022-04-01}"

# ── Utilities ─────────────────────────────────────────────────────────────────

# Progress and diagnostics, on stderr.
#
# The tool has one product — the JSONL file named by --output — and stdout is
# left clean for the caller. An operator who redirects stdout must still see
# that subscriptions were skipped.
log() { printf '%s\n' "$*" >&2; }

die() { printf '%s\n' "$*" >&2; exit 1; }

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

for dep in curl jq; do
  command -v "$dep" >/dev/null 2>&1 || die "Error: '$dep' is required but not installed."
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/datafy-azure.XXXXXX")" || die \
  "Error: cannot create a temporary directory in '${TMPDIR:-/tmp}'. Set TMPDIR to a writable path."
cleanup() { [[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf "$TMP"; return 0; }

# ── jq helpers ────────────────────────────────────────────────────────────────
# Shared definitions, prepended to every shaping filter. These have to agree
# exactly with resource_group_of() / name_of() in the other implementations —
# the parity harness diffs all three line for line.

read -r -d '' JQ_PRELUDE <<'JQ'
def rgof:
  if . == null or . == "" then null
  else ((sub("^/+";"") | sub("/+$";"") | split("/")) as $p
        | ([range(0; ($p | length)) | select(($p[.] | ascii_downcase) == "resourcegroups")] | first) as $i
        | if $i == null or ($i + 1) >= ($p | length) then null else $p[$i + 1] end)
  end;
def nameof:
  if . == null or . == "" then null
  else ((sub("/+$";"") | split("/") | last) as $n
        | if $n == "" then null else $n end)
  end;
def powerstate:
  [ (.instanceView.statuses // [])[]
    | .code // ""
    | select(startswith("PowerState/"))
    | sub("^PowerState/";"") ] | first;
JQ

# ── ARM client ────────────────────────────────────────────────────────────────

TOKEN=""

# Obtain the management-plane token.
#
# AZURE_ACCESS_TOKEN is the escape hatch for environments where the tool cannot
# sign in for itself. Otherwise the Azure CLI is asked once, and only once — the
# token is reused for every call in the run.
get_token() {
  if [[ -n "${AZURE_ACCESS_TOKEN:-}" ]]; then
    log "Auth: using the token in AZURE_ACCESS_TOKEN"
    TOKEN="$AZURE_ACCESS_TOKEN"
    return 0
  fi
  command -v az >/dev/null 2>&1 || die "$(cat <<EOF
Error: no Azure credentials found.

Sign in using one of:
  az login                                     (Azure CLI — simplest)
  az login --tenant <tenant-id>                (a specific tenant)
  export AZURE_ACCESS_TOKEN=\$(az account get-access-token \\
           --query accessToken -o tsv)         (a token you already hold)

This implementation needs either the Azure CLI on PATH or AZURE_ACCESS_TOKEN.
The Python implementation additionally supports managed identity and service
principal environment variables.
EOF
)"
  local args=(account get-access-token --resource "$ARM_ENDPOINT" --query accessToken -o tsv)
  [[ -n "$TENANT" ]] && args+=(--tenant "$TENANT")
  TOKEN="$(az "${args[@]}" 2>"$TMP/az.err")" || die \
    "Error: could not obtain an Azure token — $(head -2 "$TMP/az.err" | tr '\n' ' ')

Run 'az login' first, or set AZURE_ACCESS_TOKEN."
  [[ -n "$TOKEN" ]] || die "Error: the Azure CLI returned an empty token. Run 'az login' first."
}

# _arm_call METHOD URL [BODY_FILE] — one request with the pinned retry policy.
# Writes the response body to $ARM_BODY_FILE and sets ARM_STATUS.
# Returns 0 on an HTTP response of any status, 1 if the request never completed.
ARM_BODY_FILE=""
ARM_STATUS=0
_arm_call() {
  local method="$1" url="$2" body_file="${3:-}"
  local attempt=1 status headers retry_after delay errfile
  # mktemp rather than a PID-derived name: calls run in parallel subshells, and
  # bash 3.2 — which is what macOS ships — has no BASHPID to tell them apart.
  ARM_BODY_FILE="$(mktemp "$TMP/body.XXXXXX")"
  headers="$(mktemp "$TMP/headers.XXXXXX")"
  errfile="$(mktemp "$TMP/curlerr.XXXXXX")"

  while :; do
    local -a curl_args=(
      -sS -X "$method"
      -H "Authorization: Bearer $TOKEN"
      -H "Accept: application/json"
      -o "$ARM_BODY_FILE" -D "$headers"
      -w '%{http_code}'
      --max-time 120
    )
    [[ -n "$body_file" ]] && curl_args+=(-H "Content-Type: application/json" --data-binary "@$body_file")

    status="$(curl "${curl_args[@]}" "$url" 2>"$errfile")"
    local curl_rc=$?

    if [[ "$curl_rc" -ne 0 || -z "$status" ]]; then
      if (( attempt >= MAX_ATTEMPTS )); then
        ARM_STATUS=0
        ARM_ERROR="RequestFailed: $(tr -d '\r' < "$errfile" | head -1)"
        rm -f "$headers" "$errfile"
        return 1
      fi
      _sleep_backoff "$attempt" ""
      attempt=$(( attempt + 1 ))
      continue
    fi

    if _is_retriable "$status" && (( attempt < MAX_ATTEMPTS )); then
      retry_after="$(grep -i '^retry-after:' "$headers" 2>/dev/null | head -1 | tr -d '\r' | awk '{print $2}')"
      _sleep_backoff "$attempt" "$retry_after"
      attempt=$(( attempt + 1 ))
      continue
    fi

    ARM_STATUS="$status"
    rm -f "$headers" "$errfile"
    return 0
  done
}

_is_retriable() {
  case "$1" in
    408|429|500|502|503|504) return 0 ;;
    *) return 1 ;;
  esac
}

_sleep_backoff() {
  local attempt="$1" retry_after="${2:-}" delay
  if [[ -n "$retry_after" && "$retry_after" =~ ^[0-9]+$ && "$retry_after" -gt 0 ]]; then
    delay="$retry_after"
  else
    # Exponential with jitter, so a fleet of parallel calls does not retry in
    # lockstep. awk rather than bash arithmetic, which is integer-only.
    delay="$(awk -v b="$RETRY_BACKOFF" -v a="$attempt" -v m="$RETRY_BACKOFF_MAX" -v r="$RANDOM" \
      'BEGIN { d = b * (2 ^ (a - 1)); if (d > m) d = m; printf "%.3f", d * (0.5 + (r % 1000) / 2000) }')"
  fi
  sleep "$delay"
}

# Turn the last response into an error message, the way the other two do.
_arm_error_text() {
  local code message
  code="$(jq -r '(.error.code // .code // empty)' "$ARM_BODY_FILE" 2>/dev/null)"
  message="$(jq -r '(.error.message // .message // empty)' "$ARM_BODY_FILE" 2>/dev/null)"
  [[ -z "$code" ]] && code="Http${ARM_STATUS}"
  [[ -z "$message" ]] && message="no message"
  printf '%s: %s' "$code" "$message" | tr '\n' ' ' | tr -s ' ' | cut -c1-"$MAX_ERROR_CHARS"
}

# arm_list_to OUTFILE PATH API_VERSION [EXTRA_QUERY] — every page, written to
# OUTFILE as one JSON array. Returns 1 and sets ARM_ERROR on failure.
#
# Writes to a file rather than to stdout so that callers do not have to wrap it
# in a command substitution: that would run it in a subshell, and ARM_ERROR set
# there would be lost the moment the substitution ended — leaving every failure
# recorded with an empty reason. It also keeps multi-megabyte result sets out of
# argv.
#
# ARM paginates by handing back an absolute nextLink that already carries its
# own api-version and continuation token, so following it means re-sending it
# verbatim — adding parameters to it is how a paginated scan silently returns
# only its first page.
ARM_ERROR=""
arm_list_to() {
  local outfile="$1" path="$2" api_version="$3" extra="${4:-}"
  local url="${ARM_ENDPOINT}${path}?api-version=${api_version}${extra:+&$extra}"
  local pages=0 acc
  acc="$(mktemp "$TMP/acc.XXXXXX")"

  while :; do
    if ! _arm_call GET "$url"; then
      return 1
    fi
    if [[ "$ARM_STATUS" -ge 400 ]]; then
      ARM_ERROR="$(_arm_error_text)"
      return 1
    fi
    if ! jq -e . "$ARM_BODY_FILE" >/dev/null 2>&1; then
      ARM_ERROR="InvalidResponse: ARM returned a body that is not JSON"
      return 1
    fi

    jq -c '(.value // [])[]' "$ARM_BODY_FILE" >> "$acc" 2>/dev/null
    pages=$(( pages + 1 ))

    url="$(jq -r '.nextLink // empty' "$ARM_BODY_FILE" 2>/dev/null)"
    [[ -z "$url" ]] && break
    if (( pages >= MAX_PAGES )); then
      ARM_ERROR="TooManyPages: list did not terminate after ${MAX_PAGES} pages"
      return 1
    fi
    case "$url" in
      http://*|https://*) ;;
      *) ARM_ERROR="InvalidNextLink: nextLink is not an http(s) URL: ${url:0:120}"; return 1 ;;
    esac
  done

  jq -s -c '.' "$acc" > "$outfile"
  rm -f "$acc" "$ARM_BODY_FILE"
  return 0
}

# ── Shaping ───────────────────────────────────────────────────────────────────
# Each filter turns the raw ARM array into the output shape. Absent fields
# become null rather than being dropped, so a record has the same keys whichever
# provider version answered.
#
# Note the deliberate absence of `// null` on scalar fields: in jq `false // x`
# yields x, so `.burstingEnabled // null` would turn a genuine `false` into
# null. Indexing a missing key already yields null, so the fallback is not only
# unnecessary but wrong.

SHAPE_DISKS='map({
  id: .id, name: .name, resource_group: (.id | rgof), location: .location,
  zones: (.zones // []),
  sku_name: .sku.name, sku_tier: .sku.tier,
  size_gb: .properties.diskSizeGB,
  state: .properties.diskState,
  provisioning_state: .properties.provisioningState,
  iops: .properties.diskIOPSReadWrite,
  mbps: .properties.diskMBpsReadWrite,
  performance_tier: .properties.tier,
  bursting_enabled: .properties.burstingEnabled,
  os_type: .properties.osType,
  encryption_type: .properties.encryption.type,
  create_option: .properties.creationData.createOption,
  source_resource_id: .properties.creationData.sourceResourceId,
  created_at: .properties.timeCreated,
  attached_to: .managedBy,
  attached_to_name: (.managedBy | nameof),
  tags: (.tags // {})
})'

SHAPE_VMS='map({
  id: .id, name: .name, resource_group: (.id | rgof), location: .location,
  zones: (.zones // []),
  vm_id: .properties.vmId,
  vm_size: .properties.hardwareProfile.vmSize,
  provisioning_state: .properties.provisioningState,
  power_state: (.properties | powerstate),
  os_type: .properties.storageProfile.osDisk.osType,
  license_type: .properties.licenseType,
  priority: .properties.priority,
  eviction_policy: .properties.evictionPolicy,
  availability_set_id: .properties.availabilitySet.id,
  scale_set_id: .properties.virtualMachineScaleSet.id,
  os_disk: (if (.properties.storageProfile.osDisk // null) == null then null else {
      name: .properties.storageProfile.osDisk.name,
      os_type: .properties.storageProfile.osDisk.osType,
      size_gb: .properties.storageProfile.osDisk.diskSizeGB,
      caching: .properties.storageProfile.osDisk.caching,
      create_option: .properties.storageProfile.osDisk.createOption,
      managed_disk_id: .properties.storageProfile.osDisk.managedDisk.id,
      storage_account_type: .properties.storageProfile.osDisk.managedDisk.storageAccountType,
      vhd_uri: .properties.storageProfile.osDisk.vhd.uri
    } end),
  data_disks: [ (.properties.storageProfile.dataDisks // [])[] | {
      lun: .lun, name: .name, size_gb: .diskSizeGB, caching: .caching,
      create_option: .createOption,
      managed_disk_id: .managedDisk.id,
      storage_account_type: .managedDisk.storageAccountType,
      vhd_uri: .vhd.uri
    } ],
  image_reference: (if (.properties.storageProfile.imageReference // null) == null then null else {
      publisher: .properties.storageProfile.imageReference.publisher,
      offer: .properties.storageProfile.imageReference.offer,
      sku: .properties.storageProfile.imageReference.sku,
      version: .properties.storageProfile.imageReference.version,
      exact_version: .properties.storageProfile.imageReference.exactVersion,
      id: .properties.storageProfile.imageReference.id,
      shared_gallery_image_id: .properties.storageProfile.imageReference.sharedGalleryImageId,
      community_gallery_image_id: .properties.storageProfile.imageReference.communityGalleryImageId
    } end),
  tags: (.tags // {})
})'

SHAPE_SCALE_SETS='map({
  id: .id, name: .name, resource_group: (.id | rgof), location: .location,
  zones: (.zones // []),
  sku_name: .sku.name, sku_tier: .sku.tier, capacity: .sku.capacity,
  orchestration_mode: .properties.orchestrationMode,
  provisioning_state: .properties.provisioningState,
  os_type: .properties.virtualMachineProfile.storageProfile.osDisk.osType,
  os_disk_size_gb: .properties.virtualMachineProfile.storageProfile.osDisk.diskSizeGB,
  os_disk_storage_account_type:
    .properties.virtualMachineProfile.storageProfile.osDisk.managedDisk.storageAccountType,
  data_disks: [ (.properties.virtualMachineProfile.storageProfile.dataDisks // [])[] | {
      lun: .lun, size_gb: .diskSizeGB, caching: .caching,
      storage_account_type: .managedDisk.storageAccountType
    } ],
  tags: (.tags // {})
})'

SHAPE_SNAPSHOTS='map({
  id: .id, name: .name, resource_group: (.id | rgof), location: .location,
  sku_name: .sku.name, sku_tier: .sku.tier,
  size_gb: .properties.diskSizeGB,
  state: .properties.diskState,
  incremental: .properties.incremental,
  os_type: .properties.osType,
  encryption_type: .properties.encryption.type,
  create_option: .properties.creationData.createOption,
  source_resource_id: .properties.creationData.sourceResourceId,
  source_disk_name: (.properties.creationData.sourceResourceId | nameof),
  created_at: .properties.timeCreated,
  tags: (.tags // {})
})'

SHAPE_IMAGES='map({
  id: .id, name: .name, resource_group: (.id | rgof), location: .location,
  provisioning_state: .properties.provisioningState,
  hyper_v_generation: .properties.hyperVGeneration,
  source_virtual_machine_id: .properties.sourceVirtualMachine.id,
  os_type: .properties.storageProfile.osDisk.osType,
  os_state: .properties.storageProfile.osDisk.osState,
  os_disk_size_gb: .properties.storageProfile.osDisk.diskSizeGB,
  data_disk_count: ((.properties.storageProfile.dataDisks // []) | length),
  tags: (.tags // {})
})'

shape() { jq -c "${JQ_PRELUDE} ${1}"; }

# ── Per-subscription scan ─────────────────────────────────────────────────────

# attempt DIR API_NAME OUTFILE SHAPE_VAR PATH API_VERSION [EXTRA_QUERY]
#
# Runs one ARM list call, recording its failure rather than propagating it, so
# the record can distinguish a subscription that is genuinely empty from one
# whose reads were denied. Counters live in files because each call runs in its
# own subshell; short appends to the same file are atomic.
attempt() {
  local dir="$1" api_name="$2" outfile="$3" shape="$4" path="$5" api_version="$6" extra="${7:-}"
  printf 'x\n' >> "$dir/calls"
  local raw
  raw="$(mktemp "$TMP/raw.XXXXXX")"
  if arm_list_to "$raw" "$path" "$api_version" "$extra"; then
    shape "$shape" < "$raw" > "$outfile" 2>/dev/null || printf '[]' > "$outfile"
    rm -f "$raw"
    return 0
  fi
  printf 'x\n' >> "$dir/failures"
  printf '%s: %s\n' "$api_name" "$ARM_ERROR" >> "$dir/errors"
  printf '[]' > "$outfile"
  rm -f "$raw"
  return 1
}

# Wait until fewer than $1 background jobs are running.
wait_for_slot() {
  local limit="$1"
  while (( $(jobs -rp 2>/dev/null | wc -l) >= limit )); do
    sleep 0.05
  done
}

# VMs, with run-time power state merged in from a second pass.
#
# power_state lives in the instance view, and ARM will not expand it inline at
# subscription scope — $expand=instanceView there is rejected outright, because
# the expand is only honoured for a scale-set-filtered query. The supported
# route for a whole subscription is a separate pass with statusOnly=true.
#
# So the inventory call goes out plain, and first: it is the one that must not
# be lost. If the status pass then fails, every VM is still reported with
# power_state null, and the subscription is marked partial.
scan_vms() {
  local dir="$1" sub="$2"
  local base="/subscriptions/${sub}/providers"
  local raw="$dir/vms.raw.json" statuses="$dir/vms.status.json"

  printf 'x\n' >> "$dir/calls"
  if ! arm_list_to "$raw" "${base}/Microsoft.Compute/virtualMachines" "$API_VIRTUAL_MACHINES"; then
    printf 'x\n' >> "$dir/failures"
    printf 'Microsoft.Compute/virtualMachines: %s\n' "$ARM_ERROR" >> "$dir/errors"
    printf '[]' > "$dir/virtual_machines.json"
    return 0
  fi

  if [[ "$(jq -r 'length' "$raw")" == "0" ]]; then
    printf '[]' > "$dir/virtual_machines.json"
    return 0
  fi

  printf 'x\n' >> "$dir/calls"
  if ! arm_list_to "$statuses" "${base}/Microsoft.Compute/virtualMachines" \
                   "$API_VIRTUAL_MACHINES" 'statusOnly=true'; then
    printf 'x\n' >> "$dir/failures"
    printf 'Microsoft.Compute/virtualMachines?statusOnly=true: %s\n' "$ARM_ERROR" >> "$dir/errors"
    printf '[]' > "$statuses"
  fi

  # Merge on resource id, compared case-insensitively: ARM echoes back whatever
  # casing a resource was created with, and the two passes need not agree.
  # A VM absent from the status pass keeps power_state null, which is exactly
  # what the other two implementations produce.
  # -n because every input arrives through --slurpfile: without it jq waits on
  # stdin, which in a background subshell is whatever the caller happened to
  # leave open.
  jq -c -n --slurpfile st "$statuses" --slurpfile vm "$raw" "${JQ_PRELUDE}"'
    ((($st[0] // [])
      | map({ key: ((.id // "") | ascii_downcase), value: (.properties | powerstate) })
      | from_entries)) as $power
    | ($vm[0] // [])
    | '"${SHAPE_VMS}"'
    | map(.power_state = $power[((.id // "") | ascii_downcase)])
  ' > "$dir/virtual_machines.json"
}

# Vaults and their policies, from both of Azure's backup families.
#
# Policies are vault-scoped in ARM — there is no subscription-wide list — so
# this is one call per vault. A vault whose policies are denied still appears in
# backup_vaults with the failure recorded against the subscription.
scan_backup() {
  local dir="$1" sub="$2"
  local base="/subscriptions/${sub}/providers"
  local vaults="$dir/backup_vaults.json" policies="$dir/backup_policies.json"
  : > "$dir/vaults.acc"
  : > "$dir/policies.acc"

  local family provider vaults_api policies_api
  for family in "RecoveryServices|Microsoft.RecoveryServices/vaults|${API_RSV_VAULTS}|${API_RSV_POLICIES}" \
                "DataProtection|Microsoft.DataProtection/backupVaults|${API_DP_VAULTS}|${API_DP_POLICIES}"; do
    IFS='|' read -r vault_type provider vaults_api policies_api <<< "$family"

    printf 'x\n' >> "$dir/calls"
    local found
    found="$(mktemp "$TMP/vaults.XXXXXX")"
    if ! arm_list_to "$found" "${base}/${provider}" "$vaults_api"; then
      printf 'x\n' >> "$dir/failures"
      printf '%s: %s\n' "$provider" "$ARM_ERROR" >> "$dir/errors"
      rm -f "$found"
      continue
    fi

    jq -c --arg t "$vault_type" "${JQ_PRELUDE}"'
      map({ id: .id, name: .name, resource_group: (.id | rgof), location: .location,
            vault_type: $t, sku_name: .sku.name, tags: (.tags // {}) })[]
    ' "$found" >> "$dir/vaults.acc" 2>/dev/null

    local vault_id vault_name vault_rg
    while IFS=$'\t' read -r vault_id vault_name vault_rg; do
      [[ -z "$vault_rg" || "$vault_rg" == "null" || -z "$vault_name" || "$vault_name" == "null" ]] && continue
      printf 'x\n' >> "$dir/calls"
      local policy_path="/subscriptions/${sub}/resourceGroups/${vault_rg}/providers/${provider}/${vault_name}/backupPolicies"
      local found_policies
      found_policies="$(mktemp "$TMP/policies.XXXXXX")"
      if ! arm_list_to "$found_policies" "$policy_path" "$policies_api"; then
        printf 'x\n' >> "$dir/failures"
        printf '%s/%s/backupPolicies: %s\n' "$provider" "$vault_name" "$ARM_ERROR" >> "$dir/errors"
        rm -f "$found_policies"
        continue
      fi
      jq -c \
        --arg t "$vault_type" --arg vid "$vault_id" --arg vname "$vault_name" "${JQ_PRELUDE}"'
        map({ id: .id, name: .name, vault_id: $vid, vault_name: $vname, vault_type: $t,
              resource_group: (.id | rgof),
              backup_management_type: .properties.backupManagementType,
              datasource_types: .properties.datasourceTypes,
              policy_type: (if .properties.policyType == null then .properties.objectType
                            else .properties.policyType end),
              protected_items_count: .properties.protectedItemsCount })[]
      ' "$found_policies" >> "$dir/policies.acc" 2>/dev/null
      rm -f "$found_policies"
    done < <(jq -r "${JQ_PRELUDE}"'.[] | [.id, .name, (.id | rgof)] | @tsv' "$found")
    rm -f "$found"
  done

  jq -s -c '.' "$dir/vaults.acc" > "$vaults"
  jq -s -c '.' "$dir/policies.acc" > "$policies"
}

# Collect all discovery data for one subscription, writing its record to stdout.
#
# Azure differs from AWS in where a failure lands. ARM list calls are scoped to a
# subscription and return every region at once, so a denied read costs a whole
# subscription rather than one region — which is why the record is per
# subscription, and why each resource carries its own location.
scan_subscription() {
  local sub="$1" name="$2" state="$3" tenant_id="$4" dir="$5"
  local base="/subscriptions/${sub}/providers"
  mkdir -p "$dir"
  : > "$dir/calls"; : > "$dir/failures"; : > "$dir/errors"

  # The resource lists are independent of one another, so they go out together
  # rather than one at a time.
  attempt "$dir" "Microsoft.Compute/disks" "$dir/disks.json" "$SHAPE_DISKS" \
    "${base}/Microsoft.Compute/disks" "$API_DISKS" &
  attempt "$dir" "Microsoft.Compute/snapshots" "$dir/snapshots.json" "$SHAPE_SNAPSHOTS" \
    "${base}/Microsoft.Compute/snapshots" "$API_SNAPSHOTS" &
  attempt "$dir" "Microsoft.Compute/images" "$dir/images.json" "$SHAPE_IMAGES" \
    "${base}/Microsoft.Compute/images" "$API_IMAGES" &
  attempt "$dir" "Microsoft.Compute/virtualMachineScaleSets" "$dir/scale_sets.json" "$SHAPE_SCALE_SETS" \
    "${base}/Microsoft.Compute/virtualMachineScaleSets" "$API_SCALE_SETS" &
  scan_vms "$dir" "$sub" &
  scan_backup "$dir" "$sub" &
  wait

  local calls failures status
  calls="$(wc -l < "$dir/calls" | tr -d ' ')"
  failures="$(wc -l < "$dir/failures" | tr -d ' ')"
  if (( failures == 0 )); then
    status="ok"
  elif (( failures >= calls )); then
    status="failed"
  else
    status="partial"
  fi

  local f
  for f in disks virtual_machines scale_sets snapshots images backup_vaults backup_policies; do
    [[ -s "$dir/$f.json" ]] || printf '[]' > "$dir/$f.json"
  done

  jq -c -n \
    --arg sub "$sub" --arg status "$status" --arg scanned_at "$(now_utc)" \
    --argjson name "$(json_or_null "$name")" \
    --argjson state "$(json_or_null "$state")" \
    --argjson tenant "$(json_or_null "$tenant_id")" \
    --slurpfile disks "$dir/disks.json" \
    --slurpfile vms "$dir/virtual_machines.json" \
    --slurpfile scale_sets "$dir/scale_sets.json" \
    --slurpfile snapshots "$dir/snapshots.json" \
    --slurpfile images "$dir/images.json" \
    --slurpfile vaults "$dir/backup_vaults.json" \
    --slurpfile policies "$dir/backup_policies.json" \
    --rawfile errors_raw "$dir/errors" '
    {
      record_type: "subscription",
      subscription_id: $sub,
      subscription_name: $name,
      tenant_id: $tenant,
      subscription_state: $state,
      status: $status,
      reason: null,
      scanned_at: $scanned_at,
      errors: ($errors_raw | split("\n") | map(select(length > 0)) | unique),
      locations: ([ ($disks[0] // [])[], ($vms[0] // [])[], ($scale_sets[0] // [])[],
                    ($snapshots[0] // [])[], ($images[0] // [])[], ($vaults[0] // [])[] ]
                  | map(.location // empty) | unique),
      disks: ($disks[0] // []),
      virtual_machines: ($vms[0] // []),
      scale_sets: ($scale_sets[0] // []),
      snapshots: ($snapshots[0] // []),
      images: ($images[0] // []),
      backup_vaults: ($vaults[0] // []),
      backup_policies: ($policies[0] // [])
    }'
}

# A JSON string, or null for an empty value.
json_or_null() {
  if [[ -z "${1:-}" ]]; then printf 'null'; else jq -c -n --arg v "$1" '$v'; fi
}

# A subscription record for one that was never scanned.
subscription_record() {
  local sub="$1" status="$2" reason="$3" name="${4:-}" state="${5:-}" tenant_id="${6:-}"
  jq -c -n \
    --arg sub "$sub" --arg status "$status" --arg scanned_at "$(now_utc)" \
    --argjson reason "$(json_or_null "$reason")" \
    --argjson name "$(json_or_null "$name")" \
    --argjson state "$(json_or_null "$state")" \
    --argjson tenant "$(json_or_null "$tenant_id")" '
    {
      record_type: "subscription", subscription_id: $sub, subscription_name: $name,
      tenant_id: $tenant, subscription_state: $state, status: $status, reason: $reason,
      scanned_at: $scanned_at, errors: [], locations: [],
      disks: [], virtual_machines: [], scale_sets: [], snapshots: [], images: [],
      backup_vaults: [], backup_policies: []
    }'
}

# ── Subscription list ─────────────────────────────────────────────────────────

# Subscription ids anywhere beneath a management group.
#
# /descendants walks the whole subtree, so a nested management group's
# subscriptions are included. The response mixes child management groups in with
# subscriptions, hence the type filter.
management_group_subscriptions() {
  local group="$1" outfile="$2" raw
  raw="$(mktemp "$TMP/descendants.XXXXXX")"
  if ! arm_list_to "$raw" "/providers/Microsoft.Management/managementGroups/${group}/descendants" \
                   "$API_DESCENDANTS"; then
    rm -f "$raw"
    return 1
  fi
  jq -r '
    .[] | select((.type // "") | ascii_downcase | endswith("/subscriptions"))
        | .name // empty' "$raw" | sort > "$outfile"
  rm -f "$raw"
  return 0
}

# What to scan, what is known to be missing, and whether that is knowable.
#
# The hard part in Azure is the denominator. GET /subscriptions returns only the
# subscriptions the identity can already see — a subscription no role assignment
# reaches is not listed as denied, it is simply absent. So unlike AWS, where
# organizations:ListAccounts names every account whether or not it can be
# assumed into, this call cannot on its own tell a complete scan from a
# half-granted one.
#
# The management group hierarchy is the denominator, because it lists
# subscriptions by membership rather than by access.
SCOPE_VERIFIED="false"
SCOPE_NOTE=""
list_subscriptions() {
  local body
  body="$(mktemp "$TMP/subs.XXXXXX")"
  if ! arm_list_to "$body" "/subscriptions" "$API_SUBSCRIPTIONS"; then
    if [[ -z "$INCLUDE" ]]; then
      die "Error: could not determine which subscriptions to scan — $ARM_ERROR

The identity needs Reader on the subscriptions you want scanned, and on the
management group if --management-group was used — see README.md, 'Permissions'."
    fi
    log "  [warn] could not list subscriptions ($ARM_ERROR); scanning the --include ids without their names"
    printf '%s' "$INCLUDE" | tr ',' '\n' | jq -R -s -c '
      split("\n") | map(select(length > 0))
      | map({subscriptionId: ., displayName: null, state: null, tenantId: null})' > "$body"
  fi

  # visible.tsv: id, name, state, tenant
  jq -r --arg tenant "$TENANT" '
    .[]
    | select($tenant == "" or (.tenantId // "") == "" or .tenantId == $tenant)
    | [ .subscriptionId, (.displayName // ""), (.state // ""), (.tenantId // "") ] | @tsv
  ' "$body" | sort > "$TMP/visible.tsv"
  cut -f1 "$TMP/visible.tsv" > "$TMP/visible.ids"

  : > "$TMP/unreachable.tsv"
  cp "$TMP/visible.tsv" "$TMP/scannable.tsv"

  if [[ -n "$MANAGEMENT_GROUP" ]]; then
    # The group is the scope, so it is also the denominator.
    if ! management_group_subscriptions "$MANAGEMENT_GROUP" "$TMP/ingroup.ids"; then
      die "Error: could not determine which subscriptions to scan — $ARM_ERROR

The identity needs Reader on the subscriptions you want scanned, and on the
management group if --management-group was used — see README.md, 'Permissions'."
    fi
    awk -F'\t' 'NR==FNR { want[$0]=1; next } ($1 in want)' "$TMP/ingroup.ids" "$TMP/visible.tsv" \
      > "$TMP/scannable.tsv"
    comm -23 "$TMP/ingroup.ids" "$TMP/visible.ids" | while read -r missing; do
      [[ -n "$missing" ]] && printf '%s\tin management group %s, but not visible to this identity — no role assignment reaches it\n' \
        "$missing" "$MANAGEMENT_GROUP" >> "$TMP/unreachable.tsv"
    done
    SCOPE_VERIFIED="true"
    SCOPE_NOTE="scope checked against management group ${MANAGEMENT_GROUP}"

  elif [[ -n "$INCLUDE" ]]; then
    # An explicit list is its own denominator: the operator said what they
    # expected, so anything they named and we cannot see is a gap.
    SCOPE_VERIFIED="true"
    SCOPE_NOTE="scope checked against --include"

  else
    local roots root failures="" checked=0
    roots="$(_tenant_roots)"
    : > "$TMP/expected.ids"
    while read -r root; do
      [[ -z "$root" ]] && continue
      if management_group_subscriptions "$root" "$TMP/root.ids"; then
        cat "$TMP/root.ids" >> "$TMP/expected.ids"
        checked=$(( checked + 1 ))
      else
        failures="${failures:+$failures; }tenant ${root}: ${ARM_ERROR}"
      fi
    done <<< "$roots"
    sort -u -o "$TMP/expected.ids" "$TMP/expected.ids"

    comm -23 "$TMP/expected.ids" "$TMP/visible.ids" | while read -r missing; do
      [[ -n "$missing" ]] && printf '%s\tin the tenant hierarchy, but not visible to this identity — no role assignment reaches it\n' \
        "$missing" >> "$TMP/unreachable.tsv"
    done

    if (( checked > 0 )) && [[ -z "$failures" ]]; then
      SCOPE_VERIFIED="true"
      SCOPE_NOTE="scope checked against the tenant root management group"
    else
      SCOPE_VERIFIED="false"
      [[ -z "$failures" ]] && failures="no tenant could be determined from the subscription list"
      SCOPE_NOTE="scope NOT checked against the tenant root management group (${failures}). Subscriptions this identity cannot see are absent from this file and are not counted below — do not read these totals as full tenant coverage."
    fi
  fi

  if [[ -n "$INCLUDE" ]]; then
    printf '%s' "$INCLUDE" | tr ',' '\n' | sed '/^$/d' | sort > "$TMP/wanted.ids"
    awk -F'\t' 'NR==FNR { want[$0]=1; next } ($1 in want)' "$TMP/wanted.ids" "$TMP/scannable.tsv" \
      > "$TMP/scannable.filtered.tsv"
    mv "$TMP/scannable.filtered.tsv" "$TMP/scannable.tsv"
    # Named and not visible. Recorded, not merely warned about: a warning on
    # stderr is gone the moment the operator redirects it, and the file is the
    # only thing that gets sent to us.
    cut -f1 "$TMP/unreachable.tsv" | sort -u > "$TMP/already.ids"
    comm -23 "$TMP/wanted.ids" "$TMP/visible.ids" | comm -23 - "$TMP/already.ids" | while read -r missing; do
      [[ -n "$missing" ]] && printf '%s\tnamed by --include, but not visible to this identity — no role assignment reaches it\n' \
        "$missing" >> "$TMP/unreachable.tsv"
    done
  fi

  if [[ -n "$EXCLUDE" ]]; then
    printf '%s' "$EXCLUDE" | tr ',' '\n' | sed '/^$/d' | sort > "$TMP/excluded.ids"
    awk -F'\t' 'NR==FNR { skip[$0]=1; next } !($1 in skip)' "$TMP/excluded.ids" "$TMP/scannable.tsv" \
      > "$TMP/s.tsv" && mv "$TMP/s.tsv" "$TMP/scannable.tsv"
    awk -F'\t' 'NR==FNR { skip[$0]=1; next } !($1 in skip)' "$TMP/excluded.ids" "$TMP/unreachable.tsv" \
      > "$TMP/u.tsv" && mv "$TMP/u.tsv" "$TMP/unreachable.tsv"
  fi

  sort -o "$TMP/scannable.tsv" "$TMP/scannable.tsv"
  sort -o "$TMP/unreachable.tsv" "$TMP/unreachable.tsv"
}

# Tenant ids whose hierarchy is worth asking about.
#
# The token's tenant covers the case that matters most and is easiest to miss:
# an identity that can see no subscriptions at all has no tenant to derive from
# them, which is exactly when knowing what it is missing is worth the most.
_tenant_roots() {
  if [[ -n "$TENANT" ]]; then
    printf '%s\n' "$TENANT"
    return
  fi
  local from_subs
  from_subs="$(cut -f4 "$TMP/visible.tsv" | sed '/^$/d' | sort -u)"
  if [[ -n "$from_subs" ]]; then
    printf '%s\n' "$from_subs"
    return
  fi
  local hint
  hint="$(_token_claim tid)"
  [[ -n "$hint" ]] && printf '%s\n' "$hint"
}

# One claim from the access token, without verifying it.
#
# Only ever used to read our own token's oid and tid. The token was just handed
# to us and is about to be sent back to the issuer, which does verify it;
# nothing here is a trust decision.
_token_claim() {
  local claim="$1" payload
  payload="$(printf '%s' "$TOKEN" | cut -d. -f2)"
  [[ -z "$payload" ]] && return 1
  # base64url, re-padded.
  payload="$(printf '%s' "$payload" | tr '_-' '/+')"
  while (( ${#payload} % 4 )); do payload="${payload}="; done
  printf '%s' "$payload" | base64 -d 2>/dev/null | jq -r --arg c "$claim" '.[$c] // empty' 2>/dev/null
}

# ── Reader access setup (--setup-role) ────────────────────────────────────────
# The Azure counterpart of the AWS edition's CloudFormation StackSet. Same
# contract: grant the access the scan needs, scan, then always take it away
# again — including when the scan fails.
#
# One PUT and one DELETE, rather than N stack instances, because Azure RBAC
# inherits down the management group hierarchy. This is the only part of the
# tool that writes anything.

GRANTED_SCOPES=()
GRANTED_PRINCIPAL=""

# A deterministic UUIDv5 for a (scope, principal) pair, so re-running
# --setup-role after a crash lands on the assignment the previous run left
# behind instead of stacking up a second one.
_assignment_name() {
  local scope="$1" principal="$2" ns_hex hash
  ns_hex="$(printf '%s' "$ASSIGNMENT_NAMESPACE" | tr -d '-')"
  hash="$( { printf '%s' "$ns_hex" | xxd -r -p; printf '%s|%s' "$scope" "$principal"; } \
           | shasum -a 1 2>/dev/null | cut -d' ' -f1 )"
  [[ -z "$hash" ]] && hash="$( { printf '%s' "$ns_hex" | xxd -r -p; printf '%s|%s' "$scope" "$principal"; } \
           | sha1sum | cut -d' ' -f1 )"
  # Stamp version 5 and the RFC 4122 variant, exactly as uuid5 does.
  local b6 b8
  b6="$(printf '%02x' $(( (0x${hash:12:2} & 0x0f) | 0x50 )))"
  b8="$(printf '%02x' $(( (0x${hash:16:2} & 0x3f) | 0x80 )))"
  printf '%s-%s-%s%s-%s%s-%s\n' \
    "${hash:0:8}" "${hash:8:4}" "$b6" "${hash:14:2}" "$b8" "${hash:18:2}" "${hash:20:12}"
}

# Assign Reader to a principal at a scope.
#
# Returns 0 if this call created the assignment, 2 if an equivalent one was
# already there. The distinction is load-bearing: teardown removes only what
# this run created, so a standing grant that happens to match is never revoked
# out from under the customer.
grant_reader() {
  local scope="$1" principal="$2" name body_file
  name="$(_assignment_name "$scope" "$principal")"
  body_file="$TMP/assignment.json"
  jq -c -n --arg role "/providers/Microsoft.Authorization/roleDefinitions/${READER_ROLE_ID}" \
           --arg pid "$principal" \
    '{properties: {roleDefinitionId: $role, principalId: $pid}}' > "$body_file"

  local url="${ARM_ENDPOINT}${scope}/providers/Microsoft.Authorization/roleAssignments/${name}?api-version=${API_ROLE_ASSIGNMENTS}"
  if ! _arm_call PUT "$url" "$body_file"; then
    ARM_ERROR="${ARM_ERROR:-RequestFailed: the role assignment request did not complete}"
    return 1
  fi
  if [[ "$ARM_STATUS" -lt 400 ]]; then
    return 0
  fi
  local code
  code="$(jq -r '.error.code // empty' "$ARM_BODY_FILE" 2>/dev/null)"
  if [[ "$code" == "RoleAssignmentExists" || "$code" == "RoleAssignmentUpdateNotPermitted" ]]; then
    log "  Reader is already assigned at ${scope} — leaving it alone."
    return 2
  fi
  ARM_ERROR="$(_arm_error_text)"
  return 1
}

revoke_reader() {
  local scope="$1" principal="$2" name
  name="$(_assignment_name "$scope" "$principal")"
  _arm_call DELETE \
    "${ARM_ENDPOINT}${scope}/providers/Microsoft.Authorization/roleAssignments/${name}?api-version=${API_ROLE_ASSIGNMENTS}" \
    || return 1
  [[ "$ARM_STATUS" -lt 400 || "$ARM_STATUS" == "204" ]] && return 0
  ARM_ERROR="$(_arm_error_text)"
  return 1
}

# Block until the new access is usable, or the timeout expires.
#
# Azure does not make a role assignment effective the moment it is written.
# Scanning straight away would miss precisely the subscriptions --setup-role was
# used to reach, and would report them unreachable — a failure that looks exactly
# like the flag not working, immediately after it did.
wait_for_propagation() {
  local expected_file="$1" total deadline now missing
  total="$(wc -l < "$expected_file" | tr -d ' ')"
  (( total == 0 )) && return 0
  deadline="$(awk -v t="$PROPAGATION_TIMEOUT" 'BEGIN { srand(); print srand() + t }' 2>/dev/null)"
  deadline=$(( $(date +%s) + ${PROPAGATION_TIMEOUT%.*} ))

  while :; do
    local body
    body="$(mktemp "$TMP/recheck.XXXXXX")"
    if arm_list_to "$body" "/subscriptions" "$API_SUBSCRIPTIONS"; then
      jq -r '.[].subscriptionId // empty' "$body" | sort > "$TMP/nowvisible.ids"
    else
      log "  [warn] could not re-check visible subscriptions: $ARM_ERROR"
      : > "$TMP/nowvisible.ids"
    fi
    rm -f "$body"
    missing="$(comm -23 "$expected_file" "$TMP/nowvisible.ids" | grep -c . || true)"
    if [[ "${missing:-0}" -eq 0 ]]; then
      log "  Reader is in effect across ${total} subscription(s)."
      return 0
    fi
    now="$(date +%s)"
    if (( now >= deadline )); then
      log "  [warn] ${missing} subscription(s) still not visible after ${PROPAGATION_TIMEOUT%.*}s. Scanning anyway — every one of them is recorded in the output with a reason."
      return 0
    fi
    log "  Waiting for the role assignment to take effect ($(( total - missing ))/${total} visible)..."
    sleep "$PROPAGATION_POLL"
  done
}

# Grant Reader everywhere this run needs it.
#
# The scope is always a management group, never a subscription, and that is the
# point: assigning at a tenant root covers every subscription beneath it, so a
# subscription the identity could not previously see becomes readable without
# having to be enumerated first. It could not have been enumerated — a
# subscription no assignment reaches is absent from /subscriptions entirely.
setup_reader_access() {
  local principal group scope rc
  principal="$(_token_claim oid)"
  [[ -n "$principal" ]] || _setup_failed \
    "the access token carries no 'oid' claim, so the identity to grant Reader to cannot be determined. Sign in as a user or service principal, or grant Reader yourself and run without --setup-role"
  GRANTED_PRINCIPAL="$principal"
  log "Granting Reader to principal ${principal}..."

  if [[ -n "$MANAGEMENT_GROUP" ]]; then
    group="$MANAGEMENT_GROUP"
  else
    # --tenant first if given, then the token's own tenant. Deliberately not the
    # subscription list: an identity with no assignments anywhere sees nothing
    # there, and that is the case this flag is for.
    group="${TENANT:-$(_token_claim tid)}"
    [[ -n "$group" ]] || _setup_failed \
      "no tenant could be determined to grant Reader in — the access token carries no 'tid' claim. Pass --tenant, or --management-group, to name the scope explicitly"
  fi

  scope="/providers/Microsoft.Management/managementGroups/${group}"
  grant_reader "$scope" "$principal"
  rc=$?
  case "$rc" in
    0) GRANTED_SCOPES+=("$scope"); log "  Reader assigned at ${scope}" ;;
    2) ;;
    *) _setup_failed "$ARM_ERROR" ;;
  esac

  if ! management_group_subscriptions "$group" "$TMP/granted_expected.ids"; then
    log "  [warn] could not read the hierarchy under ${scope}: $ARM_ERROR"
    : > "$TMP/granted_expected.ids"
  fi

  if (( ${#GRANTED_SCOPES[@]} > 0 )); then
    wait_for_propagation "$TMP/granted_expected.ids"
  fi
}

_setup_failed() {
  log "Error: --setup-role could not grant Reader — $1"
  log ""
  log "Creating a role assignment needs Owner, User Access Administrator or"
  log "Role Based Access Control Administrator at the scope. Assigning at a"
  log "tenant root management group additionally needs the Global Administrator"
  log "to have elevated access at least once — see README.md, 'Permissions'."
  log ""
  log "Run without --setup-role to scan with the access you already have."
  teardown_reader_access
  cleanup
  exit 1
}

# Remove every assignment this run created. Never fails the run: a failure to
# clean up has to be shouted about rather than raised, since raising here would
# replace the real error with this one.
teardown_reader_access() {
  local scope
  (( ${#GRANTED_SCOPES[@]} == 0 )) && return 0
  for scope in "${GRANTED_SCOPES[@]}"; do
    if revoke_reader "$scope" "$GRANTED_PRINCIPAL"; then
      log "Reader assignment removed from ${scope}"
    else
      log "  [warn] could not remove the Reader assignment at ${scope}: $ARM_ERROR"
      log "  Remove it by hand: az role assignment delete --assignee ${GRANTED_PRINCIPAL} --role Reader --scope ${scope}"
    fi
  done
  GRANTED_SCOPES=()
  return 0
}

# ── Entry point ───────────────────────────────────────────────────────────────

SETUP_ROLE="false"
TENANT=""
MANAGEMENT_GROUP=""
INCLUDE=""
EXCLUDE=""
OUTPUT=""

usage() {
  cat <<EOF
Datafy Discovery Tool (Azure) v${VERSION} — inventories managed disks, virtual
machines, snapshots, images and backup policies across an Azure tenant.
Read-only, unless --setup-role is used. Safe to run in production.

  --setup-role             Assign Reader to the signed-in identity for the
                           duration of the scan; always removed afterwards
  --tenant           ID    Limit to subscriptions in this Entra tenant
  --management-group ID    Limit to subscriptions beneath this management group
  --include          IDS   Comma-separated subscription IDs to scan
  --exclude          IDS   Comma-separated subscription IDs to skip
  --output           FILE  Output file (default: discovery_azure_<timestamp>.json)
  --version                Print version and exit
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --setup-role)         SETUP_ROLE="true"; shift ;;
    --tenant)             TENANT="${2:-}"; shift 2 ;;
    --tenant=*)           TENANT="${1#--tenant=}"; shift ;;
    --management-group)   MANAGEMENT_GROUP="${2:-}"; shift 2 ;;
    --management-group=*) MANAGEMENT_GROUP="${1#--management-group=}"; shift ;;
    --include)            INCLUDE="${2:-}"; shift 2 ;;
    --include=*)          INCLUDE="${1#--include=}"; shift ;;
    --exclude)            EXCLUDE="${2:-}"; shift 2 ;;
    --exclude=*)          EXCLUDE="${1#--exclude=}"; shift ;;
    --output)             OUTPUT="${2:-}"; shift 2 ;;
    --output=*)           OUTPUT="${1#--output=}"; shift ;;
    # --version is the exception to the stderr rule: there the version *is* the
    # output, so it goes to stdout where a caller can capture it.
    --version)            printf 'Datafy Discovery Tool (Azure) v%s\n' "$VERSION"; cleanup; exit 0 ;;
    -h|--help)            usage; cleanup; exit 0 ;;
    *)                    log "Error: unknown argument '$1'"; usage >&2; cleanup; exit 1 ;;
  esac
done

# Route SIGTERM through the same path as Ctrl+C, so a run killed by a timeout or
# a supervisor still writes out what it has collected. Which signal arrived is
# remembered so the process can exit 128+signal: a supervising script has to be
# able to tell an interrupted run from a clean one, and exiting 0 after an
# interrupt claims coverage the scan never had.
INTERRUPTED="false"
INTERRUPT_SIGNAL=2
on_interrupt() {
  INTERRUPT_SIGNAL="$1"
  INTERRUPTED="true"
  log ""
  log "Interrupted — writing out the results collected so far..."
  # Stop the workers, but leave this shell alive to finish writing the file.
  # A subscription killed mid-scan leaves a truncated result file behind, which
  # is why the emit loop below only accepts one that parses as JSON.
  local job
  for job in $(jobs -p 2>/dev/null); do
    kill "$job" 2>/dev/null || true
  done
  pkill -P $$ curl 2>/dev/null || true
}
trap 'on_interrupt 2' INT
trap 'on_interrupt 15' TERM
trap 'teardown_reader_access; cleanup' EXIT

log "Datafy Discovery Tool (Azure) v${VERSION}"
[[ "$ARM_ENDPOINT" != "https://management.azure.com" ]] && log "ARM endpoint:        ${ARM_ENDPOINT}"

get_token

# --setup-role is the only path that writes anything. Whatever happens
# afterwards, the assignment it created has to come back off — which is what the
# EXIT trap above guarantees.
[[ "$SETUP_ROLE" == "true" ]] && setup_reader_access

list_subscriptions

# A subscription Azure does not report as Enabled cannot be read, and saying so
# up front is more useful than six identical AuthorizationFailed errors.
awk -F'\t' '$3 == "" || $3 == "Enabled"' "$TMP/scannable.tsv" > "$TMP/enabled.tsv"
awk -F'\t' '$3 != "" && $3 != "Enabled"' "$TMP/scannable.tsv" > "$TMP/disabled.tsv"

TOTAL_SCANNABLE="$(grep -c . "$TMP/enabled.tsv" || true)"
TOTAL_DISABLED="$(grep -c . "$TMP/disabled.tsv" || true)"
TOTAL_UNREACHABLE="$(grep -c . "$TMP/unreachable.tsv" || true)"
TOTAL_IN_SCOPE=$(( TOTAL_SCANNABLE + TOTAL_DISABLED + TOTAL_UNREACHABLE ))

log ""
log "Subscriptions to scan: ${TOTAL_SCANNABLE}"
(( TOTAL_DISABLED > 0 )) && log "Subscriptions not enabled, recorded as skipped: ${TOTAL_DISABLED}"
if (( TOTAL_UNREACHABLE > 0 )); then
  log "Subscriptions this identity cannot read, recorded as failed: ${TOTAL_UNREACHABLE}"
  while IFS=$'\t' read -r sub reason; do
    [[ -n "$sub" ]] && log "  [gap] ${sub}: ${reason}"
  done < "$TMP/unreachable.tsv"
  log "  Grant Reader at the tenant root management group to cover them — see README.md, 'Permissions'."
fi
if [[ "$SCOPE_VERIFIED" != "true" ]]; then
  # Loud, because it is the one thing that cannot be recovered from the file
  # afterwards: what is absent is absent without trace.
  log ""
  log "  [warn] ${SCOPE_NOTE}"
fi

OUTPUT="${OUTPUT:-discovery_azure_$(date -u +%Y%m%d_%H%M%S).json}"

# Checked up front — a scan that cannot write its results is worth failing
# immediately, not after an hour of API calls. The message names the path: an
# opaque redirection error tells the operator the tool broke, not that their
# --output argument is wrong.
if ! : > "$OUTPUT" 2>/dev/null; then
  log "Error: cannot write output file '${OUTPUT}' — no such file or directory. Check the directory exists and is writable."
  exit 1
fi

OK=0; PARTIAL=0; FAILED=0; SKIPPED=0

emit() {
  printf '%s\n' "$1" >> "$OUTPUT"
  case "$(printf '%s' "$1" | jq -r '.status')" in
    ok)      OK=$(( OK + 1 )) ;;
    partial) PARTIAL=$(( PARTIAL + 1 )) ;;
    failed)  FAILED=$(( FAILED + 1 )) ;;
    skipped) SKIPPED=$(( SKIPPED + 1 )) ;;
  esac
}

while IFS=$'\t' read -r sub name state tenant_id; do
  [[ -z "$sub" ]] && continue
  emit "$(subscription_record "$sub" "skipped" "subscription state is '${state}', not 'Enabled'" \
          "$name" "$state" "$tenant_id")"
done < "$TMP/disabled.tsv"

# Subscriptions the hierarchy says exist but this identity cannot read. Recorded
# rather than dropped: an unreachable subscription that leaves no trace in the
# file is the one failure the customer cannot see.
while IFS=$'\t' read -r sub reason; do
  [[ -z "$sub" ]] && continue
  emit "$(subscription_record "$sub" "failed" "$reason" "" "" "$TENANT")"
done < "$TMP/unreachable.tsv"

# Records are written as each subscription completes, rather than all at the end,
# so an interrupted run keeps everything already collected — a large tenant can
# easily be Ctrl+C'd or killed by a timeout. Each worker writes its record and
# then touches a .done marker; drain() appends the ones that are complete.
DONE=0
: > "$TMP/recorded.ids"
RESULTS="$TMP/results"; mkdir -p "$RESULTS"

drain() {
  local f sub record
  for f in "$RESULTS"/*.json; do
    [[ -e "$f" ]] || continue
    sub="$(basename "$f" .json)"
    grep -qxF "$sub" "$TMP/recorded.ids" 2>/dev/null && continue
    # The marker is what says the worker finished writing. Without it a record
    # could be read half-written; and a subscription killed mid-scan never gets
    # one, so its truncated file is skipped and it is reported interrupted
    # instead.
    [[ -e "$RESULTS/$sub.done" ]] || continue
    jq -e . "$f" >/dev/null 2>&1 || continue

    record="$(cat "$f")"
    emit "$record"
    printf '%s\n' "$sub" >> "$TMP/recorded.ids"
    DONE=$(( DONE + 1 ))
    log "  [${DONE}/${TOTAL_SCANNABLE}] ${sub} — $(printf '%s' "$record" | jq -r '.status'), $(printf '%s' "$record" | jq -r '.disks | length') disks, $(printf '%s' "$record" | jq -r '.virtual_machines | length') VMs"
    printf '%s' "$record" | jq -r '.errors[]?' | while read -r err; do
      [[ -n "$err" ]] && log "         ${sub}: ${err}"
    done
  done
}

while IFS=$'\t' read -r sub name state tenant_id; do
  [[ -z "$sub" ]] && continue
  [[ "$INTERRUPTED" == "true" ]] && break
  wait_for_slot "$MAX_SUBSCRIPTION_JOBS"
  (
    scan_subscription "$sub" "$name" "$state" "$tenant_id" "$TMP/sub.$sub" > "$RESULTS/$sub.json"
    touch "$RESULTS/$sub.done"
  ) &
  drain
done < "$TMP/enabled.tsv"

# Keep draining while work remains, so records keep landing in the file rather
# than waiting on the slowest subscription.
while [[ "$INTERRUPTED" != "true" ]] && (( $(jobs -rp 2>/dev/null | wc -l) > 0 )); do
  sleep 0.05
  drain
done
wait 2>/dev/null || true
drain

# Subscriptions that never produced a record are still named, so the gap is
# visible in the file rather than only in the tallies.
if [[ "$INTERRUPTED" == "true" ]]; then
  sort -u -o "$TMP/recorded.ids" "$TMP/recorded.ids" 2>/dev/null || : > "$TMP/recorded.ids"
  while IFS=$'\t' read -r sub name state tenant_id; do
    [[ -z "$sub" ]] && continue
    grep -qxF "$sub" "$TMP/recorded.ids" 2>/dev/null && continue
    emit "$(subscription_record "$sub" "failed" "run interrupted before this subscription finished" \
            "$name" "$state" "$tenant_id")"
  done < "$TMP/enabled.tsv"
fi

# Always the last line, so a truncated upload is obvious and coverage is
# answerable from the shared file alone.
jq -c -n \
  --arg version "$VERSION" --arg scanned_at "$(now_utc)" \
  --argjson interrupted "$([[ "$INTERRUPTED" == "true" ]] && echo true || echo false)" \
  --argjson scope_verified "$([[ "$SCOPE_VERIFIED" == "true" ]] && echo true || echo false)" \
  --argjson scope_note "$(json_or_null "$SCOPE_NOTE")" \
  --argjson total "$TOTAL_IN_SCOPE" \
  --argjson ok "$OK" --argjson partial "$PARTIAL" --argjson failed "$FAILED" --argjson skipped "$SKIPPED" '
  {
    record_type: "summary", tool_version: $version, cloud: "azure",
    scanned_at: $scanned_at, interrupted: $interrupted,
    scope_verified: $scope_verified, scope_note: $scope_note,
    subscriptions_total: $total,
    subscriptions_scanned: $ok,
    subscriptions_partial: $partial,
    subscriptions_failed: $failed,
    subscriptions_skipped: $skipped
  }' >> "$OUTPUT"

[[ "$INTERRUPTED" == "true" ]] && { log ""; log "Run was interrupted — the results below are partial."; }
log ""
log "Subscriptions: ${TOTAL_IN_SCOPE} total, ${OK} scanned, ${PARTIAL} partial, ${FAILED} failed, ${SKIPPED} skipped"
log "Output:   ${OUTPUT}"
if (( PARTIAL + FAILED + SKIPPED > 0 )); then
  log ""
  log "Some subscriptions were not fully scanned. Every one is recorded in"
  log "${OUTPUT} with a status and a reason — send the file as-is."
fi
if [[ "$SCOPE_VERIFIED" != "true" ]]; then
  log ""
  log "Coverage could not be verified: the totals above count only what this"
  log "identity can see, which may be less than the tenant contains. The summary"
  log "record carries scope_verified=false so the file says so too."
fi

# Conventional 128+signal, matching the other implementations, so a wrapper can
# tell an interrupted run from a complete one.
if [[ "$INTERRUPTED" == "true" ]]; then
  exit $(( 128 + INTERRUPT_SIGNAL ))
fi
exit 0
