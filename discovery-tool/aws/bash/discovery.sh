#!/usr/bin/env bash
# Datafy Discovery Tool
# Inventories EBS volumes, EC2 instances, AMIs, snapshots, DLM policies,
# and AWS Backup plans across all accounts in an AWS Organization.
# Requires: aws-cli v2, jq
# Compatible with: bash 3.2+ (macOS default), bash 4/5, zsh
set -euo pipefail

# Disable AWS CLI v2 pager — prevents interactive prompts in scripts
export AWS_PAGER=""

# Retry policy. A 900-account scan makes tens of thousands of API calls and AWS
# will throttle it; "standard" retries the throttling codes with exponential
# backoff and jitter. Pinned here rather than left to the client default,
# because the three implementations ship different defaults and a call that
# runs out of retries costs a region — reported as degraded, but still a gap.
#
# Not "adaptive": that mode keeps a client-side rate limiter in memory, and this
# implementation spawns a fresh CLI process per call, so it would have nothing
# to carry between them and would quietly mean less here than in Python or Go.
#
# An operator can still override either from the environment.
export AWS_RETRY_MODE="${AWS_RETRY_MODE:-standard}"
export AWS_MAX_ATTEMPTS="${AWS_MAX_ATTEMPTS:-10}"

# ── Constants ──────────────────────────────────────────────────────────────────

VERSION="0.2.0"
DEFAULT_ROLE="OrganizationAccountAccessRole"
DISCOVERY_ROLE="DatafyDiscoveryRole"
STACKSET_NAME="DatafyDiscovery"
# Parallelism — sized dynamically at runtime from available RAM (see set_job_limits below).
MAX_ACCOUNT_JOBS=3
MAX_REGION_JOBS=4
# ec2:DescribeImages is called with an explicit id list. AWS caps the number of
# ids per request, and a single call covering a whole region also overflows the
# exec argument list, so the lookup is split into batches of this size.
AMI_BATCH_SIZE=100

DISCOVERY_ROLE_TEMPLATE='{
  "AWSTemplateFormatVersion": "2010-09-09",
  "Description": "Datafy Discovery Role — minimal read-only role for EBS/EC2 inventory. Auto-deleted after scan.",
  "Parameters": {
    "ManagementAccountId": { "Type": "String" }
  },
  "Resources": {
    "DatafyDiscoveryRole": {
      "Type": "AWS::IAM::Role",
      "Properties": {
        "RoleName": "DatafyDiscoveryRole",
        "AssumeRolePolicyDocument": {
          "Version": "2012-10-17",
          "Statement": [{ "Effect": "Allow",
            "Principal": { "AWS": { "Fn::Sub": "arn:aws:iam::${ManagementAccountId}:root" } },
            "Action": "sts:AssumeRole" }]
        },
        "Policies": [{ "PolicyName": "DatafyDiscovery", "PolicyDocument": {
          "Version": "2012-10-17",
          "Statement": [
            {
              "Sid": "EC2DescribeReadOnly",
              "Effect": "Allow",
              "Resource": "*",
              "Action": [
                "ec2:DescribeVolumes", "ec2:DescribeInstances", "ec2:DescribeRegions",
                "ec2:DescribeImages", "ec2:DescribeSnapshots"
              ]
            },
            {
              "Sid": "DLMPoliciesReadOnly",
              "Effect": "Allow",
              "Resource": "arn:aws:dlm:*:*:policy/*",
              "Action": ["dlm:GetLifecyclePolicies"]
            },
            {
              "Sid": "BackupPlansReadOnly",
              "Effect": "Allow",
              "Resource": "arn:aws:backup:*:*:backup-plan:*",
              "Action": ["backup:ListBackupPlans"]
            }
          ]
        }}]
      }
    }
  }
}'

# ── Helpers ────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Datafy Discovery Tool v${VERSION}

Usage: $(basename "$0") [options]

Options:
  --profile    NAME   AWS named profile (~/.aws/config)
  --role       NAME   IAM role to assume in child accounts (default: $DEFAULT_ROLE)
  --setup-role        Deploy a read-only role via StackSet; auto-removed after scan
  --ou         ID     Limit to this Organizational Unit (ou-xxxx-xxxxxxxx)
  --include    IDS    Comma-separated account IDs to scan
  --exclude    IDS    Comma-separated account IDs to skip
  --output     FILE   Output file (default: discovery_<timestamp>.json)
  --version           Show version
  --help              Show this help
EOF
  exit 0
}

log()  { echo "$*" >&2; }
fail() { echo "Error: $*" >&2; exit 1; }

# Portable mktemp: works on macOS (BSD) and Linux (GNU)
make_tmpfile() {
  mktemp "${TMPDIR:-/tmp}/datafy.XXXXXX"
}
make_tmpdir() {
  mktemp -d "${TMPDIR:-/tmp}/datafy.XXXXXX"
}

# Portable read-lines-into-array: works on bash 3.2, bash 4/5, and zsh
read_lines_into_array() {
  # Usage: read_lines_into_array ARRAY_NAME < <(command)
  # We can't use mapfile (bash 4+) so we use a while-read loop
  local _arr_name="$1"
  local _line
  local _i=0
  while IFS= read -r _line; do
    eval "${_arr_name}[$_i]=\"\$_line\""
    (( _i++ )) || true
  done
}

# Run an AWS CLI command, optionally with a specific profile
aws_cmd() {
  if [[ -n "${AWS_PROFILE:-}" ]]; then
    aws --profile "$AWS_PROFILE" "$@"
  else
    aws "$@"
  fi
}

# Set MAX_ACCOUNT_JOBS and MAX_REGION_JOBS using 70% of available RAM.
# Each aws CLI v2 process uses ~125MB. Peak = MAX_ACCOUNT_JOBS × MAX_REGION_JOBS processes.
set_job_limits() {
  local free_mb=0

  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: use vm_stat to get free+inactive pages (4KB each)
    local pages
    pages=$(vm_stat 2>/dev/null | awk '
      /Pages free/      { gsub(/\./, "", $3); free += $3 }
      /Pages inactive/  { gsub(/\./, "", $3); free += $3 }
      END { print free }')
    free_mb=$(( ${pages:-0} * 4 / 1024 ))
  elif [[ -f /proc/meminfo ]]; then
    # Linux: MemAvailable is the most accurate "usable" figure
    free_mb=$(awk '/MemAvailable/ { printf "%d", $2/1024 }' /proc/meminfo)
  fi

  if (( free_mb > 0 )); then
    local budget_mb=$(( free_mb * 70 / 100 ))
    local total_jobs=$(( budget_mb / 125 ))
    (( total_jobs < 2  )) && total_jobs=2
    (( total_jobs > 40 )) && total_jobs=40
    # Split evenly: account jobs ≈ sqrt(total), region jobs fills the rest
    MAX_ACCOUNT_JOBS=$(( total_jobs / 4 ))
    (( MAX_ACCOUNT_JOBS < 1 )) && MAX_ACCOUNT_JOBS=1
    MAX_REGION_JOBS=$(( total_jobs / MAX_ACCOUNT_JOBS ))
    (( MAX_REGION_JOBS < 1 )) && MAX_REGION_JOBS=1
    log "Available RAM: ${free_mb}MB  Budget (70%): ${budget_mb}MB  Jobs: ${MAX_ACCOUNT_JOBS} accounts × ${MAX_REGION_JOBS} regions"
  else
    log "Could not detect available RAM — using defaults (${MAX_ACCOUNT_JOBS} accounts × ${MAX_REGION_JOBS} regions)"
  fi
}

# Condense a captured stderr file into a single line suitable for a JSON field.
# AWS error text can be long and multi-line; the reason field only needs enough
# for the reader to know what to fix.
error_message() {
  local msg
  msg=$(tr '\n\r\t' '   ' < "$1" 2>/dev/null | sed 's/  */ /g; s/^ *//; s/ *$//')
  [[ -z "$msg" ]] && msg="unknown error"
  printf '%.400s' "$msg"
}

# Run an AWS call, writing its JSON to OUT_FILE.
# On failure OUT_FILE gets "[]" and the reason is appended to ERR_LOG as
# "<api>: <message>", so the caller can report *why* data is missing instead of
# reporting an empty region.
# Usage: fetch_json OUT_FILE ERR_LOG API_NAME <aws args...>
fetch_json() {
  local out_file="$1" err_log="$2" api="$3"
  shift 3
  local stderr_file="${out_file}.stderr"

  if aws "$@" >"$out_file" 2>"$stderr_file"; then
    # A --query that matches nothing yields empty output, not "[]".
    [[ -s "$out_file" ]] || echo "[]" > "$out_file"
    rm -f "$stderr_file"
    return 0
  fi

  echo "[]" > "$out_file"
  printf '%s: %s\n' "$api" "$(error_message "$stderr_file")" >> "$err_log"
  rm -f "$stderr_file"
  return 1
}

# Reshape a raw payload with jq, recording a failure rather than silently
# falling back to an empty array.
#
# A call can exit 0 and still return a body we cannot parse — a truncated read,
# a proxy error page, a connection cut mid-response. Treating that as "[]" makes
# a damaged region indistinguishable from an empty one, which is the same
# failure that made DT-11095 so hard to diagnose.
# Usage: transform_json SRC DST ERR_LOG LABEL FILTER
transform_json() {
  local src="$1" dst="$2" err_log="$3" label="$4" filter="$5"
  local stderr_file="${dst}.stderr"

  if jq "$filter" "$src" > "$dst" 2>"$stderr_file"; then
    rm -f "$stderr_file"
    return 0
  fi

  echo "[]" > "$dst"
  printf '%s: %s\n' "$label" "$(error_message "$stderr_file")" >> "$err_log"
  rm -f "$stderr_file"
  return 1
}

# Assume a role and print export statements the caller can eval.
# stderr is deliberately left alone so the caller can capture the AWS error and
# report it as the skip reason.
assume_role_env() {
  local account_id="$1" role_name="$2"
  local role_arn="arn:aws:iam::${account_id}:role/${role_name}"
  local creds
  creds=$(aws_cmd sts assume-role \
    --role-arn "$role_arn" \
    --role-session-name "DatafyDiscovery" \
    --duration-seconds 3600 \
    --output json) || return 1
  echo "export AWS_ACCESS_KEY_ID=$(echo "$creds"     | jq -r '.Credentials.AccessKeyId')"
  echo "export AWS_SECRET_ACCESS_KEY=$(echo "$creds" | jq -r '.Credentials.SecretAccessKey')"
  echo "export AWS_SESSION_TOKEN=$(echo "$creds"     | jq -r '.Credentials.SessionToken')"
  echo "unset AWS_PROFILE"
}

# ── Output records ─────────────────────────────────────────────────────────────

now_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# An account that was never scanned. status is "skipped" (the role could not be
# assumed) or "failed" (assumed, but the scan could not start). Without this the
# account leaves no trace in the file the customer sends us — only in stderr,
# which is not part of what gets shared.
account_record() {
  local account_id="$1" status="$2" reason="$3"
  jq -nc \
    --arg account_id "$account_id" \
    --arg status     "$status" \
    --arg reason     "$reason" \
    --arg scanned_at "$(now_utc)" \
    '{record_type: "account", account_id: $account_id, status: $status,
      reason: $reason, scanned_at: $scanned_at}'
}

# A region we could not produce any inventory for.
region_failure_record() {
  local account_id="$1" region="$2" reason="$3"
  jq -nc \
    --arg account_id "$account_id" \
    --arg region     "$region" \
    --arg reason     "$reason" \
    --arg scanned_at "$(now_utc)" \
    '{record_type: "region", account_id: $account_id, region: $region,
      status: "failed", scanned_at: $scanned_at, errors: [$reason],
      volumes: [], instances: [], amis: [], snapshots: [],
      dlm_policies: [], backup_plans: []}'
}

# Assemble a region record from the transformed arrays on disk.
#
# The payload is read from files via --slurpfile rather than passed as
# --argjson arguments. A busy region produces megabytes of JSON and exec(2)
# caps the argument list (~1MB total on macOS, 128KB per argument on Linux),
# so the old form died with "jq: Argument list too long" and — because the
# failure was swallowed by the region subshell — took the whole region out of
# the output with no error recorded anywhere. (DT-11095)
region_record() {
  local account_id="$1" region="$2" status="$3" scanned_at="$4" tmp="$5" err_log="$6"
  jq -nc \
    --arg       account_id   "$account_id" \
    --arg       region       "$region" \
    --arg       status       "$status" \
    --arg       scanned_at   "$scanned_at" \
    --rawfile   errors_raw   "$err_log" \
    --slurpfile volumes      "$tmp/out_volumes.json" \
    --slurpfile instances    "$tmp/out_instances.json" \
    --slurpfile amis         "$tmp/out_amis.json" \
    --slurpfile snapshots    "$tmp/out_snapshots.json" \
    --slurpfile dlm_policies "$tmp/out_dlm.json" \
    --slurpfile backup_plans "$tmp/out_backup.json" \
    '{record_type: "region",
      account_id: $account_id, region: $region, status: $status, scanned_at: $scanned_at,
      errors: ($errors_raw | split("\n") | map(select(length > 0)) | unique),
      volumes: $volumes[0], instances: $instances[0], amis: $amis[0],
      snapshots: $snapshots[0], dlm_policies: $dlm_policies[0],
      backup_plans: $backup_plans[0]}'
}

# ── Per-region scan ────────────────────────────────────────────────────────────

# Look up every AMI referenced by the instances in this region, in batches.
# Writes the combined Images array to $tmp/amis.json. Returns non-zero if any
# batch failed.
fetch_amis() {
  local region="$1" tmp="$2" err_log="$3"
  local batch batch_ids failed=0

  echo "[]" > "$tmp/amis.json"
  [[ -s "$tmp/ami_ids.txt" ]] || return 0

  mkdir -p "$tmp/ami_batches" "$tmp/ami_results"
  split -l "$AMI_BATCH_SIZE" "$tmp/ami_ids.txt" "$tmp/ami_batches/batch."

  for batch in "$tmp"/ami_batches/batch.*; do
    [[ -f "$batch" ]] || continue
    batch_ids=()
    read_lines_into_array batch_ids < "$batch"
    [[ ${#batch_ids[@]} -gt 0 ]] || continue
    fetch_json "$tmp/ami_results/$(basename "$batch").json" "$err_log" "ec2:DescribeImages" \
      ec2 describe-images --region "$region" --output json \
      --image-ids "${batch_ids[@]}" --query 'Images' \
      || failed=1
  done

  jq -s 'add // []' "$tmp"/ami_results/*.json > "$tmp/amis.json" 2>/dev/null \
    || echo "[]" > "$tmp/amis.json"

  return "$failed"
}

scan_region() {
  local account_id="$1" region="$2"
  local scanned_at tmp err_log
  scanned_at=$(now_utc)
  tmp=$(make_tmpdir)
  err_log="$tmp/errors.log"
  : > "$err_log"

  # Every call is counted so the record can distinguish a region that is empty
  # (calls succeeded, nothing to report) from one that was denied or unreachable.
  local calls=0 failures=0

  # API calls are sequential within a region — parallelism happens at the region/account level.
  # Running them in parallel here multiplied peak process count by 5x and exhausted RAM.
  calls=$(( calls + 1 ))
  fetch_json "$tmp/volumes.json" "$err_log" "ec2:DescribeVolumes" \
    ec2 describe-volumes --region "$region" --output json --query 'Volumes' \
    || failures=$(( failures + 1 ))

  calls=$(( calls + 1 ))
  fetch_json "$tmp/reservations.json" "$err_log" "ec2:DescribeInstances" \
    ec2 describe-instances --region "$region" --output json --query 'Reservations' \
    || failures=$(( failures + 1 ))

  calls=$(( calls + 1 ))
  fetch_json "$tmp/snapshots.json" "$err_log" "ec2:DescribeSnapshots" \
    ec2 describe-snapshots --region "$region" --output json --owner-ids self --query 'Snapshots' \
    || failures=$(( failures + 1 ))

  calls=$(( calls + 1 ))
  fetch_json "$tmp/dlm.json" "$err_log" "dlm:GetLifecyclePolicies" \
    dlm get-lifecycle-policies --region "$region" --output json --query 'Policies' \
    || failures=$(( failures + 1 ))

  calls=$(( calls + 1 ))
  fetch_json "$tmp/backup.json" "$err_log" "backup:ListBackupPlans" \
    backup list-backup-plans --region "$region" --output json --query 'BackupPlansList' \
    || failures=$(( failures + 1 ))

  jq -r '[.[]? | .Instances[]? | .ImageId | select(. != null)] | unique | .[]' \
    "$tmp/reservations.json" > "$tmp/ami_ids.txt" 2>/dev/null || : > "$tmp/ami_ids.txt"
  if [[ -s "$tmp/ami_ids.txt" ]]; then
    calls=$(( calls + 1 ))
    fetch_amis "$region" "$tmp" "$err_log" || failures=$(( failures + 1 ))
  else
    echo "[]" > "$tmp/amis.json"
  fi

  # Transform each payload straight to disk — nothing is held in a shell
  # variable or passed through argv. A parse failure counts as a failed call,
  # so a damaged payload cannot masquerade as an empty region.
  transform_json "$tmp/volumes.json" "$tmp/out_volumes.json" "$err_log" \
    "parse ec2:DescribeVolumes" '[.[]? | {
      VolumeId,
      Name: (.Tags // [] | map(select(.Key=="Name")) | first | .Value),
      Size, VolumeType, State, Iops, Throughput, Encrypted, AvailabilityZone, SnapshotId,
      InstanceId: (.Attachments // [] | first | .InstanceId),
      Device:     (.Attachments // [] | first | .Device),
      Tags: (.Tags // [])
    }]' || failures=$(( failures + 1 ))

  transform_json "$tmp/reservations.json" "$tmp/out_instances.json" "$err_log" \
    "parse ec2:DescribeInstances" '[.[]? as $r | $r.Instances[]? | {
      InstanceId,
      Name: (.Tags // [] | map(select(.Key=="Name")) | first | .Value),
      InstanceType, State: .State.Name, Hypervisor, PlatformDetails, ImageId,
      AvailabilityZone: .Placement.AvailabilityZone,
      RootDeviceName, Architecture, OwnerId: $r.OwnerId,
      Tags: (.Tags // [])
    }]' || failures=$(( failures + 1 ))

  transform_json "$tmp/amis.json" "$tmp/out_amis.json" "$err_log" \
    "parse ec2:DescribeImages" '[.[]? | {
      ImageId, Name, Description,
      Platform: (.Platform // ""),
      Architecture
    }]' || failures=$(( failures + 1 ))

  transform_json "$tmp/snapshots.json" "$tmp/out_snapshots.json" "$err_log" \
    "parse ec2:DescribeSnapshots" '[.[]? | {
      SnapshotId, VolumeId, VolumeSize,
      StartTime: (.StartTime // "" | sub("\\+00:00$"; "Z")),
      State, Encrypted,
      Tags: (.Tags // [])
    }]' || failures=$(( failures + 1 ))

  transform_json "$tmp/dlm.json" "$tmp/out_dlm.json" "$err_log" \
    "parse dlm:GetLifecyclePolicies" \
    '[.[]? | {PolicyId, Description, State, PolicyType}]' || failures=$(( failures + 1 ))

  transform_json "$tmp/backup.json" "$tmp/out_backup.json" "$err_log" \
    "parse backup:ListBackupPlans" \
    '[.[]? | {BackupPlanId, BackupPlanName,
      CreationDate: (.CreationDate // "" | sub("\\+00:00$"; "Z"))}]' || failures=$(( failures + 1 ))

  local status="ok"
  if (( failures > 0 )); then
    if (( failures >= calls )); then status="failed"; else status="partial"; fi
  fi

  local rc=0
  region_record "$account_id" "$region" "$status" "$scanned_at" "$tmp" "$err_log" || rc=$?
  # Cleanup happens after the record is emitted — the old order deleted the
  # temp dir first and only worked because the payload was already in memory.
  rm -rf "$tmp"
  return "$rc"
}

# ── Per-account scan ───────────────────────────────────────────────────────────

# Scan one account into its own result file. Every account gets a private file,
# so parallel accounts never append to the same fd — a torn multi-megabyte
# record would silently corrupt the JSONL the customer sends us. The parent
# concatenates the files once all jobs have finished.
#
# Always returns 0: an unreachable account is reported as a record, not as a
# non-zero status that the caller would have to guess the meaning of.
scan_account() {
  local account_id="$1" caller_account_id="$2" role_name="$3" result_file="$4"

  # Assume role in child accounts
  local role_env="" assume_err reason
  if [[ "$account_id" != "$caller_account_id" ]]; then
    assume_err=$(make_tmpfile)
    role_env=$(assume_role_env "$account_id" "$role_name" 2>"$assume_err") || {
      reason="cannot assume role ${role_name}: $(error_message "$assume_err")"
      rm -f "$assume_err"
      account_record "$account_id" "skipped" "$reason" > "$result_file"
      log "  [skip] $account_id: $reason"
      return 0
    }
    rm -f "$assume_err"
  fi

  # List enabled regions in a subshell so assumed credentials don't escape
  local regions regions_err region_list
  regions_err=$(make_tmpfile)
  regions=$(
    [[ -n "$role_env" ]] && eval "$role_env"
    aws ec2 describe-regions \
      --region us-east-1 --output json \
      --query 'Regions[].RegionName' 2>"$regions_err"
  ) || {
    reason="cannot list regions: $(error_message "$regions_err")"
    rm -f "$regions_err"
    account_record "$account_id" "failed" "$reason" > "$result_file"
    log "  [fail] $account_id: $reason"
    return 0
  }
  rm -f "$regions_err"

  region_list=$(printf '%s' "$regions" | jq -r '.[]?' 2>/dev/null) || region_list=""
  if [[ -z "$region_list" ]]; then
    reason="ec2:DescribeRegions returned no enabled regions"
    account_record "$account_id" "failed" "$reason" > "$result_file"
    log "  [fail] $account_id: $reason"
    return 0
  fi

  # Scan regions in parallel, capped at MAX_REGION_JOBS
  local tmp_dir
  tmp_dir=$(make_tmpdir)
  local region_pids=()

  throttle_region_jobs() {
    local live=()
    local p
    for p in "${region_pids[@]+"${region_pids[@]}"}"; do
      kill -0 "$p" 2>/dev/null && live+=("$p") || true
    done
    region_pids=("${live[@]+"${live[@]}"}")
    while (( ${#region_pids[@]} >= MAX_REGION_JOBS )); do
      sleep 0.3
      live=()
      for p in "${region_pids[@]+"${region_pids[@]}"}"; do
        kill -0 "$p" 2>/dev/null && live+=("$p") || true
      done
      region_pids=("${live[@]+"${live[@]}"}")
    done
  }

  local region
  for region in $region_list; do
    throttle_region_jobs
    (
      [[ -n "$role_env" ]] && eval "$role_env"
      # Write under a staging name and rename into place. A job killed mid-write
      # then leaves a .partial file that the collector ignores, instead of a
      # truncated record that would corrupt the JSONL.
      if result=$(scan_region "$account_id" "$region"); then
        printf '%s\n' "$result" > "${tmp_dir}/${region}.partial"
      else
        region_failure_record "$account_id" "$region" \
          "region scan failed unexpectedly" > "${tmp_dir}/${region}.partial"
      fi
      mv -f "${tmp_dir}/${region}.partial" "${tmp_dir}/${region}.json"
    ) &
    region_pids+=($!)
  done

  # Wait for all remaining region jobs
  local pid
  for pid in "${region_pids[@]+"${region_pids[@]}"}"; do
    wait "$pid" 2>/dev/null || true
  done

  # Account for every enumerated region. A subshell that was killed (OOM, signal)
  # would otherwise drop its region from the output with no trace — the exact
  # symptom reported in DT-11095.
  for region in $region_list; do
    [[ -f "${tmp_dir}/${region}.json" ]] && continue
    region_failure_record "$account_id" "$region" \
      "region scan produced no result (process terminated)" > "${tmp_dir}/${region}.json"
  done

  # Assemble under a staging name too, so the collector only ever sees accounts
  # that finished. An account still in flight when the run is interrupted
  # contributes nothing rather than a half-written fragment.
  local count=0 f name failed_regions="" partial_regions=""
  : > "${result_file}.partial"
  for f in "${tmp_dir}"/*.json; do
    [[ -f "$f" ]] || continue
    cat "$f" >> "${result_file}.partial"
    count=$(( count + 1 ))
    name=$(basename "$f" .json)
    if grep -q '"status":"failed"' "$f"; then
      failed_regions="${failed_regions:+$failed_regions }$name"
    elif grep -q '"status":"partial"' "$f"; then
      partial_regions="${partial_regions:+$partial_regions }$name"
    fi
  done
  mv -f "${result_file}.partial" "$result_file"
  rm -rf "$tmp_dir"

  # Name the regions, not just the count — "3 failed" gives the operator nothing
  # to act on, and this is the only signal they see while the scan is running.
  log "  [done] $account_id — $count regions"
  [[ -n "$partial_regions" ]] && log "         partial: $partial_regions"
  [[ -n "$failed_regions"  ]] && log "         failed:  $failed_regions"
  return 0
}

# ── Account list ───────────────────────────────────────────────────────────────

list_accounts() {
  local ou="$1" include="$2" exclude="$3"

  if [[ -n "$include" ]]; then
    tr ',' '\n' <<< "$include" | sed 's/[[:space:]]//g'
    return
  fi

  local all_accounts
  if [[ -n "$ou" ]]; then
    all_accounts=$(aws_cmd organizations list-accounts-for-parent \
      --parent-id "$ou" --output json \
      --query 'Accounts[?Status==`ACTIVE`].Id' | jq -r '.[]')
  else
    all_accounts=$(aws_cmd organizations list-accounts \
      --output json \
      --query 'Accounts[?Status==`ACTIVE`].Id' | jq -r '.[]')
  fi

  if [[ -n "$exclude" ]]; then
    local exclude_pattern
    exclude_pattern=$(tr ',' '|' <<< "$exclude" | sed 's/[[:space:]]//g')
    echo "$all_accounts" | grep -Ev "^(${exclude_pattern})$" || true
  else
    echo "$all_accounts"
  fi
}

# ── StackSet lifecycle ─────────────────────────────────────────────────────────

stackset_targets_args() {
  local ou="$1" include="$2"
  if [[ -n "$include" ]]; then
    local accts
    accts=$(tr ',' ' ' <<< "$include")
    echo "--accounts $accts"
  else
    local ou_id="$ou"
    if [[ -z "$ou_id" ]]; then
      ou_id=$(aws_cmd organizations list-roots \
        --output json --query 'Roots[0].Id' | jq -r '.')
    fi
    echo "--deployment-targets OrganizationalUnitIds=$ou_id"
  fi
}

wait_for_stackset_op() {
  local op_id="$1"
  while true; do
    local status
    status=$(aws_cmd cloudformation describe-stack-set-operation \
      --stack-set-name "$STACKSET_NAME" \
      --operation-id "$op_id" \
      --output json \
      --query 'StackSetOperation.Status' | jq -r '.')
    case "$status" in
      SUCCEEDED) return 0 ;;
      FAILED|STOPPED) fail "StackSet operation $op_id ended with status: $status" ;;
      *) log "  Waiting for StackSet operation ($status)..."; sleep 15 ;;
    esac
  done
}

deploy_stackset() {
  local mgmt_account_id="$1" ou="$2" include="$3"
  log "Creating StackSet '$STACKSET_NAME'..."

  # Write template to a temp file — portable mktemp (no --suffix)
  local tmpl
  tmpl=$(make_tmpfile)
  echo "$DISCOVERY_ROLE_TEMPLATE" > "$tmpl"

  aws_cmd cloudformation create-stack-set \
    --stack-set-name "$STACKSET_NAME" \
    --description "Datafy Discovery — read-only role. Auto-deleted after scan." \
    --template-body "file://${tmpl}" \
    --parameters "ParameterKey=ManagementAccountId,ParameterValue=${mgmt_account_id}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --permission-model SERVICE_MANAGED \
    --auto-deployment Enabled=false \
    --output json 2>/dev/null || log "  StackSet '$STACKSET_NAME' already exists — reusing it."

  rm -f "$tmpl"

  local targets_args
  targets_args=$(stackset_targets_args "$ou" "$include")

  log "Deploying role to accounts (this may take a few minutes)..."
  local op_id
  op_id=$(eval aws_cmd cloudformation create-stack-instances \
    --stack-set-name "\"$STACKSET_NAME\"" \
    "$targets_args" \
    --regions us-east-1 \
    --operation-preferences MaxConcurrentPercentage=100,FailureTolerancePercentage=50 \
    --output json \
    --query 'OperationId' | jq -r '.')

  wait_for_stackset_op "$op_id"
  log "Role deployed."
}

teardown_stackset() {
  local ou="$1" include="$2"
  log "Removing StackSet '$STACKSET_NAME'..."

  local targets_args
  targets_args=$(stackset_targets_args "$ou" "$include") || {
    log "  [warn] Could not determine targets — delete StackSet '$STACKSET_NAME' manually."
    return
  }

  local op_id
  op_id=$(eval aws_cmd cloudformation delete-stack-instances \
    --stack-set-name "\"$STACKSET_NAME\"" \
    "$targets_args" \
    --regions us-east-1 \
    --no-retain-stacks \
    --operation-preferences MaxConcurrentPercentage=100,FailureTolerancePercentage=100 \
    --output json \
    --query 'OperationId' | jq -r '.') || {
    log "  [warn] Could not delete stack instances — delete StackSet '$STACKSET_NAME' manually."
    return
  }

  wait_for_stackset_op "$op_id" || {
    log "  [warn] Teardown operation failed — delete StackSet '$STACKSET_NAME' manually."
    return
  }

  aws_cmd cloudformation delete-stack-set \
    --stack-set-name "$STACKSET_NAME" || \
    log "  [warn] Could not delete StackSet '$STACKSET_NAME' — delete it manually."

  log "StackSet removed."
}

# ── Argument parsing ───────────────────────────────────────────────────────────

PROFILE=""
ROLE="$DEFAULT_ROLE"
SETUP_ROLE=false
OU=""
INCLUDE=""
EXCLUDE=""
OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)    PROFILE="$2";     shift 2 ;;
    --role)       ROLE="$2";        shift 2 ;;
    --setup-role) SETUP_ROLE=true;  shift   ;;
    --ou)         OU="$2";          shift 2 ;;
    --include)    INCLUDE="$2";     shift 2 ;;
    --exclude)    EXCLUDE="$2";     shift 2 ;;
    --output)     OUTPUT="$2";      shift 2 ;;
    --version)    echo "Datafy Discovery Tool v${VERSION}"; exit 0 ;;
    --help|-h)    usage ;;
    *) fail "Unknown option: $1" ;;
  esac
done

[[ -n "$PROFILE" ]] && export AWS_PROFILE="$PROFILE"

# ── Dependency check ───────────────────────────────────────────────────────────

for dep in aws jq; do
  command -v "$dep" &>/dev/null || fail "'$dep' is required but not installed."
done

# ── Main ───────────────────────────────────────────────────────────────────────

IDENTITY=$(aws_cmd sts get-caller-identity --output json 2>/dev/null) || \
  fail "Cannot authenticate. Ensure credentials are configured (--profile, AWS_PROFILE, or aws configure)."

CALLER_ACCOUNT=$(echo "$IDENTITY" | jq -r '.Account')
CALLER_ARN=$(echo "$IDENTITY"     | jq -r '.Arn')

log "Datafy Discovery Tool v${VERSION}"
log "Running as:         $CALLER_ARN"
log "Management account: $CALLER_ACCOUNT"

set_job_limits

# Single EXIT trap — handles StackSet teardown and temp cleanup.
# It must end with an explicit success: under `set -e` a trailing test that
# evaluates false becomes the script's exit status, which made every successful
# run exit 1.
TEARDOWN_STACKSET=false
RESULT_DIR=""
cleanup() {
  [[ -n "$RESULT_DIR" && -d "$RESULT_DIR" ]] && rm -rf "$RESULT_DIR"
  if [[ "$TEARDOWN_STACKSET" == true ]]; then
    teardown_stackset "$OU" "$INCLUDE"
  fi
  return 0
}
trap cleanup EXIT

# Ctrl+C / SIGTERM: stop the scans, then still write out everything already
# collected. A large org can easily be interrupted or hit a session limit — the
# customer's first run timed out — and the accounts that already finished are
# the most valuable thing on disk. Discarding them was a real data-loss bug.
INTERRUPTED=false

# TERM a job and everything below it. `jobs -p` only names the per-account
# subshells; their region children — and the aws processes those are blocked on
# — would otherwise keep running and stall the shutdown.
kill_tree() {
  local pid="$1" child
  if command -v pgrep >/dev/null 2>&1; then
    for child in $(pgrep -P "$pid" 2>/dev/null); do
      kill_tree "$child"
    done
  fi
  kill -TERM "$pid" 2>/dev/null || true
}

handle_interrupt() {
  local signal="${1:-INT}"
  log ""
  log "Interrupted (SIG${signal}) — stopping all scans..."
  INTERRUPTED=true

  local pid
  for pid in $(jobs -p 2>/dev/null); do
    kill_tree "$pid"
  done

  # Give them a few seconds to die, then write out regardless. An API call that
  # refuses to return must not cost us the results we already have.
  local waited=0
  while (( waited < 50 )) && [[ -n "$(jobs -p 2>/dev/null)" ]]; do
    sleep 0.1
    waited=$(( waited + 1 ))
  done

  finalize_output
  # Conventional 128+signal, so a supervising script can tell the two apart.
  case "$signal" in
    TERM) exit 143 ;;
    *)    exit 130 ;;
  esac
}
trap 'handle_interrupt INT'  INT
trap 'handle_interrupt TERM' TERM

# Deploy StackSet if requested
if [[ "$SETUP_ROLE" == true ]]; then
  ROLE="$DISCOVERY_ROLE"
  deploy_stackset "$CALLER_ACCOUNT" "$OU" "$INCLUDE"
  TEARDOWN_STACKSET=true
fi

# Collect accounts into ACCOUNTS array (portable — no mapfile)
ACCOUNTS=()
read_lines_into_array ACCOUNTS < <(list_accounts "$OU" "$INCLUDE" "$EXCLUDE")

log ""
log "Accounts to scan: ${#ACCOUNTS[@]}"
[[ ${#ACCOUNTS[@]} -eq 0 ]] && fail "No accounts found to scan."

# Output file. Checked up front — a scan that cannot write its results is worth
# failing immediately, not after an hour of API calls.
[[ -z "$OUTPUT" ]] && OUTPUT="discovery_$(date -u +%Y%m%d_%H%M%S).json"
: > "$OUTPUT" 2>/dev/null || \
  fail "cannot write output file '$OUTPUT' — check the directory exists and is writable."

# Per-account result files, concatenated into $OUTPUT once every job is done.
RESULT_DIR=$(make_tmpdir 2>/dev/null) || \
  fail "cannot create a temp directory under '${TMPDIR:-/tmp}' — set TMPDIR to a writable location."

# Collect the per-account results into $OUTPUT and close the file with a summary.
# Called on the normal path and from the interrupt handler, so an interrupted
# run still yields everything that finished. Idempotent — whichever path gets
# there first wins.
FINALIZED=false
finalize_output() {
  [[ "$FINALIZED" == true ]] && return 0
  FINALIZED=true
  [[ -n "$RESULT_DIR" && -d "$RESULT_DIR" ]] || return 0

  # Only completed accounts have a .jsonl; anything still staging is a .partial
  # and is ignored, so the file is never left with a torn record.
  find "$RESULT_DIR" -type f -name '*.jsonl' -exec cat {} + >> "$OUTPUT" 2>/dev/null || true

  local reason="account scan produced no result (process terminated)"
  [[ "$INTERRUPTED" == true ]] && reason="run interrupted before this account finished"

  local account
  for account in "${ACCOUNTS[@]+"${ACCOUNTS[@]}"}"; do
    [[ -s "${RESULT_DIR}/${account}.jsonl" ]] && continue
    account_record "$account" "failed" "$reason" >> "$OUTPUT"
  done

  # Tally in one streaming pass — the output can be gigabytes, so it is never
  # slurped into memory.
  local tally
  tally=$(jq -r '"\(.record_type // "region"):\(.status // "-")"' "$OUTPUT" 2>/dev/null \
          | sort | uniq -c | awk '{ print $2 "=" $1 }') || tally=""

  tally_get() {
    local v
    v=$(printf '%s\n' "$tally" | grep "^$1=" | head -1 | cut -d= -f2)
    echo "${v:-0}"
  }

  local total skipped failed scanned ok partial region_failed
  total=${#ACCOUNTS[@]}
  skipped=$(tally_get "account:skipped")
  failed=$(tally_get "account:failed")
  scanned=$(( total - skipped - failed ))
  ok=$(tally_get "region:ok")
  partial=$(tally_get "region:partial")
  region_failed=$(tally_get "region:failed")

  # Last line of the file, so a truncated upload is obvious and coverage is
  # answerable from the shared file alone.
  jq -nc \
    --arg     tool_version      "$VERSION" \
    --arg     scanned_at        "$(now_utc)" \
    --argjson interrupted       "$INTERRUPTED" \
    --argjson accounts_total    "$total" \
    --argjson accounts_scanned  "$scanned" \
    --argjson accounts_skipped  "$skipped" \
    --argjson accounts_failed   "$failed" \
    --argjson regions_scanned   "$ok" \
    --argjson regions_partial   "$partial" \
    --argjson regions_failed    "$region_failed" \
    '{record_type: "summary", tool_version: $tool_version, scanned_at: $scanned_at,
      interrupted: $interrupted,
      accounts_total: $accounts_total, accounts_scanned: $accounts_scanned,
      accounts_skipped: $accounts_skipped, accounts_failed: $accounts_failed,
      regions_scanned: $regions_scanned, regions_partial: $regions_partial,
      regions_failed: $regions_failed}' >> "$OUTPUT"

  log ""
  [[ "$INTERRUPTED" == true ]] && log "Run was interrupted — the results below are partial."
  log "Accounts: $total total, $scanned scanned, $skipped skipped, $failed failed"
  log "Regions:  $ok scanned, $partial partial, $region_failed failed"
  log "Output:   $OUTPUT"
  if (( skipped > 0 || failed > 0 || partial > 0 || region_failed > 0 )); then
    log ""
    log "Some accounts or regions were not fully scanned. Every one is recorded in"
    log "$OUTPUT with a status and a reason — send the file as-is."
  fi
  return 0
}

# Scan accounts in parallel, capped at MAX_ACCOUNT_JOBS.
# Uses only plain arrays and per-PID wait — compatible with bash 3.2 and zsh.
active_pids=()

throttle_jobs() {
  # Remove finished PIDs from active_pids
  local remaining=()
  local pid
  for pid in "${active_pids[@]+"${active_pids[@]}"}"; do
    kill -0 "$pid" 2>/dev/null && remaining+=("$pid") || true
  done
  active_pids=("${remaining[@]+"${remaining[@]}"}")

  # Block until a slot is free
  while (( ${#active_pids[@]} >= MAX_ACCOUNT_JOBS )); do
    sleep 0.5
    remaining=()
    for pid in "${active_pids[@]+"${active_pids[@]}"}"; do
      kill -0 "$pid" 2>/dev/null && remaining+=("$pid") || true
    done
    active_pids=("${remaining[@]+"${remaining[@]}"}")
  done
}

for account in "${ACCOUNTS[@]+"${ACCOUNTS[@]}"}"; do
  throttle_jobs
  scan_account "$account" "$CALLER_ACCOUNT" "$ROLE" "${RESULT_DIR}/${account}.jsonl" &
  active_pids+=($!)
done

# Wait for all remaining jobs
for pid in "${active_pids[@]+"${active_pids[@]}"}"; do
  wait "$pid" 2>/dev/null || true
done

finalize_output
