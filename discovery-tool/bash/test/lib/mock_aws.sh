#!/usr/bin/env bash
# Mock AWS CLI for discovery.sh tests.
#
# Installed onto PATH as `aws`. Dispatches on "<service> <operation>" and emits
# canned JSON shaped like the real API responses. Behaviour is driven entirely by
# environment variables so each test case can describe the org it wants:
#
#   MOCK_CALLER_ACCOUNT      management account id                  (default 000000000000)
#   MOCK_ACCOUNTS            comma-separated account ids in the org
#   MOCK_REGIONS             comma-separated enabled regions
#   MOCK_VOLUMES             volumes returned per account x region   (default 0)
#   MOCK_INSTANCES           instances returned per account x region (default 0)
#   MOCK_SNAPSHOTS           snapshots returned per account x region (default 0)
#   MOCK_AMI_COUNT           distinct AMIs the instances reference    (default 3)
#   MOCK_TAG_PAD             bytes of filler per tag value           (default 0)
#   MOCK_DENY_ASSUME         accounts where sts:AssumeRole fails
#   MOCK_DENY_LIST_REGIONS   accounts where ec2:DescribeRegions fails
#   MOCK_DENY_VOLUMES        "<account>/<region>" pairs where ec2:DescribeVolumes fails
#   MOCK_DENY_ALL            "<account>/<region>" pairs where every data call fails
#                            (models an opted-out or auth-blocked region)
#   MOCK_STATE_DIR           directory for cross-process bookkeeping, set by the
#                            harness; required by the options below
#   MOCK_DELAY_SECONDS       sleep this long before answering a data call
#   MOCK_DELAY_ACCOUNTS      accounts the delay applies to (default: all)
#   MOCK_EXPIRE_AFTER        after this many data calls org-wide, every further
#                            data call fails with ExpiredToken — models the 1h
#                            assume-role session outliving a long scan
#   MOCK_CORRUPT_OPS         operations that return truncated, unparseable JSON
#   MOCK_CORRUPT_REGIONS     regions the corruption applies to (default: all)
#
# The mock learns which account it is impersonating from AWS_ACCESS_KEY_ID:
# assume-role hands back the sentinel key "AKIAMOCK<account-id>", mirroring how
# the real script propagates credentials into its region subshells.

set -uo pipefail

MOCK_CALLER_ACCOUNT="${MOCK_CALLER_ACCOUNT:-000000000000}"

# ── Which account are we acting as? ────────────────────────────────────────────
current_account() {
  local key="${AWS_ACCESS_KEY_ID:-}"
  case "$key" in
    AKIAMOCK*) echo "${key#AKIAMOCK}" ;;
    *)         echo "$MOCK_CALLER_ACCOUNT" ;;
  esac
}

# csv_contains "a,b,c" "b" → 0 (true)
csv_contains() {
  local haystack="$1" needle="$2" item
  local IFS=','
  for item in $haystack; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# Pull the value of a flag out of the argv the script passed us.
arg_value() {
  local want="$1"; shift
  while [[ $# -gt 0 ]]; do
    [[ "$1" == "$want" ]] && { echo "${2:-}"; return 0; }
    shift
  done
  echo ""
}

die_access_denied() {
  echo "An error occurred (AccessDenied) when calling the $1 operation: mock denial" >&2
  exit 254
}

# ── Payload generators ─────────────────────────────────────────────────────────
# jq builds the arrays — a bash loop is far too slow at the sizes the stress
# test needs (tens of thousands of records).
#
# Resource ids are built by zero-padding the index as a *string*. Doing the
# arithmetic in jq instead (e.g. `. + 400000000000000000`) silently degrades to
# a double and renders as "4e+17", collapsing every id into one value.

# jq snippet: 17-character zero-padded index, prefixed. Usage: `pad_id("vol-")`
JQ_PAD_ID='def pad_id($prefix): ($prefix + ("00000000000000000" + (. | tostring) | .[-17:]));'

pad_value() {
  local n="${MOCK_TAG_PAD:-0}"
  (( n <= 0 )) && { echo ""; return; }
  printf '%*s' "$n" '' | tr ' ' 'x'
}

gen_volumes() {
  local n="${MOCK_VOLUMES:-0}" region="$1" pad
  pad=$(pad_value)
  jq -nc --argjson n "$n" --arg region "$region" --arg pad "$pad" "$JQ_PAD_ID"'
    [range($n) | {
      VolumeId: pad_id("vol-"),
      Size: (100 + (. % 900)),
      VolumeType: "gp3",
      State: "in-use",
      Iops: 3000,
      Throughput: 125,
      Encrypted: true,
      AvailabilityZone: ($region + "a"),
      SnapshotId: pad_id("snap-"),
      Attachments: [{ InstanceId: pad_id("i-"), Device: "/dev/xvda" }],
      Tags: [
        { Key: "Name",        Value: ("volume-\(.)-" + $pad) },
        { Key: "Environment", Value: ("env-\(. % 7)-" + $pad) },
        { Key: "Owner",       Value: ("team-\(. % 13)-" + $pad) }
      ]
    }]'
}

gen_reservations() {
  local n="${MOCK_INSTANCES:-0}" region="$1" account="$2" pad
  local amis="${MOCK_AMI_COUNT:-3}"
  pad=$(pad_value)
  # One instance per reservation, matching how EC2 reports standalone launches.
  # Instances cycle through MOCK_AMI_COUNT distinct AMIs, so a case can dial the
  # AMI cardinality independently of the instance count.
  jq -nc --argjson n "$n" --argjson amis "$amis" \
         --arg region "$region" --arg account "$account" --arg pad "$pad" "$JQ_PAD_ID"'
    [range($n) | {
      OwnerId: $account,
      Instances: [{
        InstanceId: pad_id("i-"),
        InstanceType: "m5.large",
        State: { Name: "running" },
        Hypervisor: "xen",
        PlatformDetails: "Linux/UNIX",
        ImageId: ((. % $amis) | pad_id("ami-")),
        Placement: { AvailabilityZone: ($region + "a") },
        RootDeviceName: "/dev/xvda",
        Architecture: "x86_64",
        Tags: [
          { Key: "Name",        Value: ("instance-\(.)-" + $pad) },
          { Key: "Environment", Value: ("env-\(. % 7)-" + $pad) }
        ]
      }]
    }]'
}

gen_snapshots() {
  local n="${MOCK_SNAPSHOTS:-0}" pad
  pad=$(pad_value)
  jq -nc --argjson n "$n" --arg pad "$pad" "$JQ_PAD_ID"'
    [range($n) | {
      SnapshotId: pad_id("snap-"),
      VolumeId: pad_id("vol-"),
      VolumeSize: (100 + (. % 900)),
      StartTime: "2026-01-01T00:00:00+00:00",
      State: "completed",
      Encrypted: true,
      Tags: [{ Key: "Name", Value: ("snapshot-\(.)-" + $pad) }]
    }]'
}

# describe-images is called with an explicit --image-ids list; echo back one
# image per id so the caller can verify nothing was dropped during batching.
gen_images() {
  printf '%s\n' "$@" | jq -Rc --slurp '
    [ split("\n") | .[] | select(length > 0) | {
      ImageId: .,
      Name: ("image-" + .),
      Description: ("mock image " + .),
      Platform: "",
      Architecture: "x86_64"
    }]'
}

# ── Dispatch ───────────────────────────────────────────────────────────────────

ARGS=("$@")

# Strip global flags the script may prepend so $1/$2 are always service/operation.
while [[ ${#ARGS[@]} -gt 0 ]]; do
  case "${ARGS[0]}" in
    --profile) ARGS=("${ARGS[@]:2}") ;;
    --region)  ARGS=("${ARGS[@]:2}") ;;
    --*)       ARGS=("${ARGS[@]:1}") ;;
    *)         break ;;
  esac
done

SERVICE="${ARGS[0]:-}"
OPERATION="${ARGS[1]:-}"
ACCOUNT="$(current_account)"
REGION="$(arg_value --region "$@")"

# A region listed in MOCK_DENY_ALL rejects every data call, the way an opted-out
# or auth-blocked region behaves. describe-regions is exempt: it is always
# answered from us-east-1 and is what enumerates the region in the first place.
if [[ "$SERVICE" != "sts" && "$SERVICE" != "organizations" \
      && "$OPERATION" != "describe-regions" ]] \
   && csv_contains "${MOCK_DENY_ALL:-}" "${ACCOUNT}/${REGION}"; then
  die_access_denied "$OPERATION"
fi

# ── Data-call behaviours ───────────────────────────────────────────────────────
# The inventory calls are the ones worth instrumenting: they are what runs
# concurrently, what a long scan outlives, and what returns bulk payloads.

is_data_call() {
  case "$SERVICE $OPERATION" in
    "ec2 describe-volumes"|"ec2 describe-instances"|"ec2 describe-snapshots"|\
    "ec2 describe-images"|"dlm get-lifecycle-policies"|"backup list-backup-plans")
      return 0 ;;
    *) return 1 ;;
  esac
}

if is_data_call && [[ -n "${MOCK_STATE_DIR:-}" ]]; then
  # Concurrency accounting: register while in flight and record how many other
  # data calls were live at that moment, so a test can assert the peak.
  mkdir -p "$MOCK_STATE_DIR/live" 2>/dev/null || true
  : > "$MOCK_STATE_DIR/live/$$" 2>/dev/null || true
  trap 'rm -f "$MOCK_STATE_DIR/live/$$" 2>/dev/null' EXIT
  ls "$MOCK_STATE_DIR/live" 2>/dev/null | grep -c . >> "$MOCK_STATE_DIR/peak.log" 2>/dev/null || true
fi

if is_data_call; then
  # Hold the call open, so a test can act while the scan is genuinely in flight.
  if [[ -n "${MOCK_DELAY_SECONDS:-}" ]] \
     && { [[ -z "${MOCK_DELAY_ACCOUNTS:-}" ]] || csv_contains "${MOCK_DELAY_ACCOUNTS}" "$ACCOUNT"; }; then
    sleep "$MOCK_DELAY_SECONDS"
  fi

  # Session expiry. Assumed credentials last an hour; a 900-account scan can
  # outlive that, after which every call fails for the rest of the run.
  if [[ -n "${MOCK_EXPIRE_AFTER:-}" && -n "${MOCK_STATE_DIR:-}" ]]; then
    printf 'x' >> "$MOCK_STATE_DIR/calls"
    calls_made=$(wc -c < "$MOCK_STATE_DIR/calls" 2>/dev/null || echo 0)
    if (( calls_made > MOCK_EXPIRE_AFTER )); then
      echo "An error occurred (ExpiredToken) when calling the $OPERATION operation: The security token included in the request is expired" >&2
      exit 254
    fi
  fi

  # A response that exits 0 but is not parseable JSON — a truncated read, a
  # proxy error page, a connection cut mid-body.
  if csv_contains "${MOCK_CORRUPT_OPS:-}" "$OPERATION" \
     && { [[ -z "${MOCK_CORRUPT_REGIONS:-}" ]] || csv_contains "${MOCK_CORRUPT_REGIONS}" "$REGION"; }; then
    printf '[{"VolumeId":"vol-00000000000000001","Size":100,"Tags":[{"Key":"Na'
    exit 0
  fi
fi

case "$SERVICE $OPERATION" in

  "sts get-caller-identity")
    jq -nc --arg a "$MOCK_CALLER_ACCOUNT" \
      '{Account: $a, Arn: ("arn:aws:iam::" + $a + ":user/mock"), UserId: "AIDAMOCK"}'
    ;;

  "sts assume-role")
    role_arn="$(arg_value --role-arn "$@")"
    target="${role_arn#arn:aws:iam::}"; target="${target%%:*}"
    if csv_contains "${MOCK_DENY_ASSUME:-}" "$target"; then
      die_access_denied AssumeRole
    fi
    jq -nc --arg t "$target" '{
      Credentials: {
        AccessKeyId:     ("AKIAMOCK" + $t),
        SecretAccessKey: "mock-secret",
        SessionToken:    "mock-token",
        Expiration:      "2099-01-01T00:00:00Z"
      }
    }'
    ;;

  "organizations list-accounts"|"organizations list-accounts-for-parent")
    # The script asks for Accounts[?Status==`ACTIVE`].Id, i.e. a flat id array.
    echo "${MOCK_ACCOUNTS:-}" | jq -Rc 'split(",") | map(select(length > 0))'
    ;;

  "organizations list-roots")
    echo '"r-mock"'
    ;;

  "ec2 describe-regions")
    if csv_contains "${MOCK_DENY_LIST_REGIONS:-}" "$ACCOUNT"; then
      die_access_denied DescribeRegions
    fi
    echo "${MOCK_REGIONS:-}" | jq -Rc 'split(",") | map(select(length > 0))'
    ;;

  "ec2 describe-volumes")
    if csv_contains "${MOCK_DENY_VOLUMES:-}" "${ACCOUNT}/${REGION}"; then
      die_access_denied DescribeVolumes
    fi
    gen_volumes "$REGION"
    ;;

  "ec2 describe-instances")
    gen_reservations "$REGION" "$ACCOUNT"
    ;;

  "ec2 describe-snapshots")
    gen_snapshots
    ;;

  "ec2 describe-images")
    # Collect every token that follows --image-ids until the next flag.
    ids=(); collecting=false
    for a in "$@"; do
      if [[ "$a" == "--image-ids" ]]; then collecting=true; continue; fi
      if [[ "$collecting" == true ]]; then
        [[ "$a" == --* ]] && break
        ids+=("$a")
      fi
    done
    gen_images "${ids[@]+"${ids[@]}"}"
    ;;

  "dlm get-lifecycle-policies")
    echo '[]'
    ;;

  "backup list-backup-plans")
    echo '[]'
    ;;

  *)
    echo "mock aws: unhandled command: $*" >&2
    exit 1
    ;;
esac
