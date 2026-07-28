#!/usr/bin/env bash
# Datafy Discovery Tool
# Inventories EBS volumes, EC2 instances, AMIs, snapshots, DLM policies,
# and AWS Backup plans across all accounts in an AWS Organization.
# Requires: aws-cli v2, jq
# Compatible with: bash 3.2+ (macOS default), bash 4/5, zsh
set -euo pipefail

# Disable AWS CLI v2 pager — prevents interactive prompts in scripts
export AWS_PAGER=""

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
  # variable or passed through argv.
  jq '[.[]? | {
    VolumeId,
    Name: (.Tags // [] | map(select(.Key=="Name")) | first | .Value),
    Size, VolumeType, State, Iops, Throughput, Encrypted, AvailabilityZone, SnapshotId,
    InstanceId: (.Attachments // [] | first | .InstanceId),
    Device:     (.Attachments // [] | first | .Device),
    Tags: (.Tags // [])
  }]' "$tmp/volumes.json" > "$tmp/out_volumes.json" 2>/dev/null \
    || echo "[]" > "$tmp/out_volumes.json"

  jq '[.[]? as $r | $r.Instances[]? | {
    InstanceId,
    Name: (.Tags // [] | map(select(.Key=="Name")) | first | .Value),
    InstanceType, State: .State.Name, Hypervisor, PlatformDetails, ImageId,
    AvailabilityZone: .Placement.AvailabilityZone,
    RootDeviceName, Architecture, OwnerId: $r.OwnerId,
    Tags: (.Tags // [])
  }]' "$tmp/reservations.json" > "$tmp/out_instances.json" 2>/dev/null \
    || echo "[]" > "$tmp/out_instances.json"

  jq '[.[]? | {
    ImageId, Name, Description,
    Platform: (.Platform // ""),
    Architecture
  }]' "$tmp/amis.json" > "$tmp/out_amis.json" 2>/dev/null \
    || echo "[]" > "$tmp/out_amis.json"

  jq '[.[]? | {
    SnapshotId, VolumeId, VolumeSize, StartTime, State, Encrypted,
    Tags: (.Tags // [])
  }]' "$tmp/snapshots.json" > "$tmp/out_snapshots.json" 2>/dev/null \
    || echo "[]" > "$tmp/out_snapshots.json"

  jq '[.[]? | {PolicyId, Description, State, PolicyType}]' "$tmp/dlm.json" \
    > "$tmp/out_dlm.json" 2>/dev/null || echo "[]" > "$tmp/out_dlm.json"

  jq '[.[]? | {BackupPlanId, BackupPlanName, CreationDate}]' "$tmp/backup.json" \
    > "$tmp/out_backup.json" 2>/dev/null || echo "[]" > "$tmp/out_backup.json"

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
  : > "$result_file"

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
      if result=$(scan_region "$account_id" "$region"); then
        printf '%s\n' "$result" > "${tmp_dir}/${region}.json"
      else
        region_failure_record "$account_id" "$region" \
          "region scan failed unexpectedly" > "${tmp_dir}/${region}.json"
      fi
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

  local count=0 f name failed_regions="" partial_regions=""
  for f in "${tmp_dir}"/*.json; do
    [[ -f "$f" ]] || continue
    cat "$f" >> "$result_file"
    count=$(( count + 1 ))
    name=$(basename "$f" .json)
    if grep -q '"status":"failed"' "$f"; then
      failed_regions="${failed_regions:+$failed_regions }$name"
    elif grep -q '"status":"partial"' "$f"; then
      partial_regions="${partial_regions:+$partial_regions }$name"
    fi
  done
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

# Ctrl+C / SIGTERM: kill all background jobs then exit (EXIT trap handles the rest)
handle_interrupt() {
  log ""
  log "Interrupted — stopping all scans..."
  local pids
  pids=$(jobs -p 2>/dev/null) || true
  [[ -n "$pids" ]] && echo "$pids" | xargs kill -TERM 2>/dev/null || true
  wait 2>/dev/null || true
  exit 130
}
trap handle_interrupt INT TERM

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

# Output file
[[ -z "$OUTPUT" ]] && OUTPUT="discovery_$(date -u +%Y%m%d_%H%M%S).json"
> "$OUTPUT"

# Per-account result files, concatenated into $OUTPUT once every job is done.
RESULT_DIR=$(make_tmpdir)

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

# Assemble the output file from the per-account results.
find "$RESULT_DIR" -type f -name '*.jsonl' -exec cat {} + >> "$OUTPUT" 2>/dev/null || true

# Any account that produced no file at all was killed before it could report.
for account in "${ACCOUNTS[@]+"${ACCOUNTS[@]}"}"; do
  [[ -s "${RESULT_DIR}/${account}.jsonl" ]] && continue
  account_record "$account" "failed" "account scan produced no result (process terminated)" \
    >> "$OUTPUT"
done

# ── Summary ────────────────────────────────────────────────────────────────────
# Tally in one streaming pass — the output can be gigabytes, so it is never
# slurped into memory.
TALLY=$(jq -r '"\(.record_type // "region"):\(.status // "-")"' "$OUTPUT" 2>/dev/null \
        | sort | uniq -c | awk '{ print $2 "=" $1 }') || TALLY=""

tally_get() {
  local v
  v=$(printf '%s\n' "$TALLY" | grep "^$1=" | head -1 | cut -d= -f2)
  echo "${v:-0}"
}

ACCOUNTS_TOTAL=${#ACCOUNTS[@]}
ACCOUNTS_SKIPPED=$(tally_get "account:skipped")
ACCOUNTS_FAILED=$(tally_get "account:failed")
ACCOUNTS_SCANNED=$(( ACCOUNTS_TOTAL - ACCOUNTS_SKIPPED - ACCOUNTS_FAILED ))
REGIONS_SCANNED=$(tally_get "region:ok")
REGIONS_PARTIAL=$(tally_get "region:partial")
REGIONS_FAILED=$(tally_get "region:failed")

# Last line of the file, so a truncated upload is obvious and coverage is
# answerable from the shared file alone.
jq -nc \
  --arg     tool_version      "$VERSION" \
  --arg     scanned_at        "$(now_utc)" \
  --argjson accounts_total    "$ACCOUNTS_TOTAL" \
  --argjson accounts_scanned  "$ACCOUNTS_SCANNED" \
  --argjson accounts_skipped  "$ACCOUNTS_SKIPPED" \
  --argjson accounts_failed   "$ACCOUNTS_FAILED" \
  --argjson regions_scanned   "$REGIONS_SCANNED" \
  --argjson regions_partial   "$REGIONS_PARTIAL" \
  --argjson regions_failed    "$REGIONS_FAILED" \
  '{record_type: "summary", tool_version: $tool_version, scanned_at: $scanned_at,
    accounts_total: $accounts_total, accounts_scanned: $accounts_scanned,
    accounts_skipped: $accounts_skipped, accounts_failed: $accounts_failed,
    regions_scanned: $regions_scanned, regions_partial: $regions_partial,
    regions_failed: $regions_failed}' >> "$OUTPUT"

log ""
log "Accounts: $ACCOUNTS_TOTAL total, $ACCOUNTS_SCANNED scanned, $ACCOUNTS_SKIPPED skipped, $ACCOUNTS_FAILED failed"
log "Regions:  $REGIONS_SCANNED scanned, $REGIONS_PARTIAL partial, $REGIONS_FAILED failed"
log "Output:   $OUTPUT"
if (( ACCOUNTS_SKIPPED > 0 || ACCOUNTS_FAILED > 0 || REGIONS_PARTIAL > 0 || REGIONS_FAILED > 0 )); then
  log ""
  log "Some accounts or regions were not fully scanned. Every one is recorded in"
  log "$OUTPUT with a status and a reason — send the file as-is."
fi
