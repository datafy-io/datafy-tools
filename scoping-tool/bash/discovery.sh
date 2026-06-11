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

DEFAULT_ROLE="OrganizationAccountAccessRole"
DISCOVERY_ROLE="DatafyDiscoveryRole"
STACKSET_NAME="DatafyDiscovery"
MAX_ACCOUNT_JOBS=20

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
          "Statement": [{ "Effect": "Allow", "Resource": "*", "Action": [
            "ec2:DescribeVolumes", "ec2:DescribeInstances", "ec2:DescribeRegions",
            "ec2:DescribeImages", "ec2:DescribeSnapshots",
            "dlm:GetLifecyclePolicies", "backup:ListBackupPlans"
          ]}]
        }}]
      }
    }
  }
}'

# ── Helpers ────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --profile    NAME   AWS named profile (~/.aws/config)
  --role       NAME   IAM role to assume in child accounts (default: $DEFAULT_ROLE)
  --setup-role        Deploy a read-only role via StackSet; auto-removed after scan
  --ou         ID     Limit to this Organizational Unit (ou-xxxx-xxxxxxxx)
  --include    IDS    Comma-separated account IDs to scan
  --exclude    IDS    Comma-separated account IDs to skip
  --output     FILE   Output file (default: discovery_<timestamp>.json)
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

# Assume a role and print export statements the caller can eval.
assume_role_env() {
  local account_id="$1" role_name="$2"
  local role_arn="arn:aws:iam::${account_id}:role/${role_name}"
  local creds
  creds=$(aws_cmd sts assume-role \
    --role-arn "$role_arn" \
    --role-session-name "DatafyDiscovery" \
    --duration-seconds 3600 \
    --output json 2>/dev/null) || return 1
  echo "export AWS_ACCESS_KEY_ID=$(echo "$creds"     | jq -r '.Credentials.AccessKeyId')"
  echo "export AWS_SECRET_ACCESS_KEY=$(echo "$creds" | jq -r '.Credentials.SecretAccessKey')"
  echo "export AWS_SESSION_TOKEN=$(echo "$creds"     | jq -r '.Credentials.SessionToken')"
  echo "unset AWS_PROFILE"
}

# ── Per-region scan ────────────────────────────────────────────────────────────

scan_region() {
  local account_id="$1" region="$2"
  local scanned_at
  scanned_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Volumes
  local volumes
  volumes=$(aws ec2 describe-volumes \
    --region "$region" --output json \
    --query 'Volumes' 2>/dev/null || echo "[]")
  volumes=$(echo "${volumes:-[]}" | jq '[.[]? | {
    VolumeId,
    Name: (.Tags // [] | map(select(.Key=="Name")) | first | .Value),
    Size,
    VolumeType,
    State,
    Iops,
    Throughput,
    Encrypted,
    AvailabilityZone,
    SnapshotId,
    InstanceId: (.Attachments // [] | first | .InstanceId),
    Device:     (.Attachments // [] | first | .Device),
    Tags: (.Tags // [])
  }]')

  # Instances
  local reservations instances ami_ids
  reservations=$(aws ec2 describe-instances \
    --region "$region" --output json \
    --query 'Reservations' 2>/dev/null || echo "[]")
  instances=$(echo "${reservations:-[]}" | jq '[.[]? as $r | $r.Instances[]? | {
    InstanceId,
    Name: (.Tags // [] | map(select(.Key=="Name")) | first | .Value),
    InstanceType,
    State: .State.Name,
    Hypervisor,
    PlatformDetails,
    ImageId,
    AvailabilityZone: .Placement.AvailabilityZone,
    RootDeviceName,
    Architecture,
    OwnerId: $r.OwnerId,
    Tags: (.Tags // [])
  }]')

  # AMIs referenced by instances
  ami_ids=$(echo "${reservations:-[]}" | jq -r '[.[]? | .Instances[]? | .ImageId] | unique | @sh')
  local amis="[]"
  if [[ -n "$ami_ids" && "$ami_ids" != "''" ]]; then
    amis=$(eval "aws ec2 describe-images \
      --region \"$region\" --output json \
      --image-ids $ami_ids \
      --query 'Images'" 2>/dev/null || echo "[]")
    amis=$(echo "${amis:-[]}" | jq '[.[]? | {
      ImageId,
      Name,
      Description,
      Platform: (.Platform // ""),
      Architecture
    }]')
  fi

  # Snapshots
  local snapshots
  snapshots=$(aws ec2 describe-snapshots \
    --region "$region" --output json \
    --owner-ids self \
    --query 'Snapshots' 2>/dev/null || echo "[]")
  snapshots=$(echo "${snapshots:-[]}" | jq '[.[]? | {
    SnapshotId,
    VolumeId,
    VolumeSize,
    StartTime,
    State,
    Encrypted,
    Tags: (.Tags // [])
  }]')

  # DLM policies
  local dlm_policies
  dlm_policies=$(aws dlm get-lifecycle-policies \
    --region "$region" --output json \
    --query 'Policies' 2>/dev/null || echo "[]")
  dlm_policies=$(echo "${dlm_policies:-[]}" | jq '[.[]? | {
    PolicyId,
    Description,
    State,
    PolicyType
  }]')

  # AWS Backup plans
  local backup_plans
  backup_plans=$(aws backup list-backup-plans \
    --region "$region" --output json \
    --query 'BackupPlansList' 2>/dev/null || echo "[]")
  backup_plans=$(echo "${backup_plans:-[]}" | jq '[.[]? | {
    BackupPlanId,
    BackupPlanName,
    CreationDate
  }]')

  # Emit one JSON object
  jq -nc \
    --arg account_id    "$account_id" \
    --arg region        "$region" \
    --arg scanned_at    "$scanned_at" \
    --argjson volumes       "$volumes" \
    --argjson instances     "$instances" \
    --argjson amis          "$amis" \
    --argjson snapshots     "$snapshots" \
    --argjson dlm_policies  "$dlm_policies" \
    --argjson backup_plans  "$backup_plans" \
    '{account_id: $account_id, region: $region, scanned_at: $scanned_at,
      volumes: $volumes, instances: $instances, amis: $amis,
      snapshots: $snapshots, dlm_policies: $dlm_policies, backup_plans: $backup_plans}'
}

# ── Per-account scan ───────────────────────────────────────────────────────────

scan_account() {
  local account_id="$1" caller_account_id="$2" role_name="$3" output_file="$4"

  # Assume role in child accounts
  local role_env=""
  if [[ "$account_id" != "$caller_account_id" ]]; then
    role_env=$(assume_role_env "$account_id" "$role_name") || {
      log "  [fail] $account_id: cannot assume role $role_name"
      return 1
    }
  fi

  # List enabled regions in a subshell so assumed credentials don't escape
  local regions
  regions=$(
    [[ -n "$role_env" ]] && eval "$role_env"
    aws ec2 describe-regions \
      --region us-east-1 --output json \
      --query 'Regions[].RegionName' 2>/dev/null | jq -r '.[]'
  ) || {
    log "  [fail] $account_id: cannot list regions"
    return 1
  }

  # Scan each region in parallel, writing to a temp dir
  local tmp_dir
  tmp_dir=$(make_tmpdir)
  local region_pids=()

  for region in $regions; do
    (
      [[ -n "$role_env" ]] && eval "$role_env"
      result=$(scan_region "$account_id" "$region") && \
        echo "$result" > "${tmp_dir}/${region}.json" || true
    ) &
    region_pids+=($!)
  done

  # Wait for all region jobs (compatible with bash 3.2 — no wait -n needed here)
  local pid
  for pid in "${region_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # Atomically append results to the shared output file
  local count=0
  for f in "${tmp_dir}"/*.json; do
    [[ -f "$f" ]] || continue
    # flock for atomic append; fall back gracefully if flock unavailable (some macOS)
    if command -v flock &>/dev/null; then
      (flock 9; cat "$f" >> "$output_file") 9>>"${output_file}.lock"
    else
      cat "$f" >> "$output_file"
    fi
    (( count++ )) || true
  done
  rm -rf "$tmp_dir"

  log "  [done] $account_id — $count regions"
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

log "Running as:         $CALLER_ARN"
log "Management account: $CALLER_ACCOUNT"

# Deploy StackSet if requested; always tear it down on exit
if [[ "$SETUP_ROLE" == true ]]; then
  ROLE="$DISCOVERY_ROLE"
  deploy_stackset "$CALLER_ACCOUNT" "$OU" "$INCLUDE"
  trap 'teardown_stackset "$OU" "$INCLUDE"' EXIT
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
touch "${OUTPUT}.lock"
trap 'rm -f "${OUTPUT}.lock"' EXIT

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
  scan_account "$account" "$CALLER_ACCOUNT" "$ROLE" "$OUTPUT" &
  active_pids+=($!)
done

# Wait for all remaining jobs
for pid in "${active_pids[@]+"${active_pids[@]}"}"; do
  wait "$pid" 2>/dev/null || true
done

rm -f "${OUTPUT}.lock"

# Count results from output file
completed=$(grep -c '"account_id"' "$OUTPUT" 2>/dev/null || echo 0)

log ""
log "Regions scanned: $completed"
log "Output:          $OUTPUT"
