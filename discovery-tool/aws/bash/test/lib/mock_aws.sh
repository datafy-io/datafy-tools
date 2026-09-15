#!/usr/bin/env bash
# Mock AWS CLI for the bash-internal test cases.
#
# Installed onto PATH as `aws`. Dispatches on "<service> <operation>" and emits
# canned JSON shaped like the real API responses. It exists so a case can run
# discovery.sh to completion without an AWS account; the cases that assert on
# what the tool *produces* live in test/ at the repository root and run against
# a fake AWS endpoint that all three implementations share.
#
# Behaviour is driven by environment variables:
#
#   MOCK_CALLER_ACCOUNT  management account id                   (default 000000000000)
#   MOCK_ACCOUNTS        comma-separated account ids in the org
#   MOCK_REGIONS         comma-separated enabled regions
#   MOCK_VOLUMES         volumes returned per account x region   (default 0)
#   MOCK_INSTANCES       instances returned per account x region (default 0)
#   MOCK_SNAPSHOTS       snapshots returned per account x region (default 0)
#   MOCK_AMI_COUNT       distinct AMIs the instances reference   (default 3)
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

# Pull the value of a flag out of the argv the script passed us.
arg_value() {
  local want="$1"; shift
  while [[ $# -gt 0 ]]; do
    [[ "$1" == "$want" ]] && { echo "${2:-}"; return 0; }
    shift
  done
  echo ""
}

# ── Payload generators ─────────────────────────────────────────────────────────
# jq builds the arrays — a bash loop is far too slow at the sizes a case may ask
# for. Resource ids are built by zero-padding the index as a *string*: doing the
# arithmetic in jq instead (e.g. `. + 400000000000000000`) silently degrades to
# a double and renders as "4e+17", collapsing every id into one value.

# jq snippet: 17-character zero-padded index, prefixed. Usage: `pad_id("vol-")`
JQ_PAD_ID='def pad_id($prefix): ($prefix + ("00000000000000000" + (. | tostring) | .[-17:]));'

gen_volumes() {
  local n="${MOCK_VOLUMES:-0}" region="$1"
  jq -nc --argjson n "$n" --arg region "$region" "$JQ_PAD_ID"'
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
        { Key: "Name",        Value: "volume-\(.)" },
        { Key: "Environment", Value: "env-\(. % 7)" }
      ]
    }]'
}

gen_reservations() {
  local n="${MOCK_INSTANCES:-0}" region="$1" account="$2"
  local amis="${MOCK_AMI_COUNT:-3}"
  # One instance per reservation, matching how EC2 reports standalone launches.
  jq -nc --argjson n "$n" --argjson amis "$amis" \
         --arg region "$region" --arg account "$account" "$JQ_PAD_ID"'
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
        Tags: [{ Key: "Name", Value: "instance-\(.)" }]
      }]
    }]'
}

gen_snapshots() {
  local n="${MOCK_SNAPSHOTS:-0}"
  jq -nc --argjson n "$n" "$JQ_PAD_ID"'
    [range($n) | {
      SnapshotId: pad_id("snap-"),
      VolumeId: pad_id("vol-"),
      VolumeSize: (100 + (. % 900)),
      StartTime: "2026-01-01T00:00:00+00:00",
      State: "completed",
      Encrypted: true,
      Tags: [{ Key: "Name", Value: "snapshot-\(.)" }]
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

case "$SERVICE $OPERATION" in

  "sts get-caller-identity")
    jq -nc --arg a "$MOCK_CALLER_ACCOUNT" \
      '{Account: $a, Arn: ("arn:aws:iam::" + $a + ":user/mock"), UserId: "AIDAMOCK"}'
    ;;

  "sts assume-role")
    role_arn="$(arg_value --role-arn "$@")"
    target="${role_arn#arn:aws:iam::}"; target="${target%%:*}"
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
    echo "${MOCK_REGIONS:-}" | jq -Rc 'split(",") | map(select(length > 0))'
    ;;

  "ec2 describe-volumes")
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
