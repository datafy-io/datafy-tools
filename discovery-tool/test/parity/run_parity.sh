#!/usr/bin/env bash
# Cross-implementation parity harness.
#
# Starts a fake AWS endpoint, runs all three discovery implementations against
# it, and diffs their output. Because every client honours AWS_ENDPOINT_URL,
# this exercises the real AWS CLI, real boto3 and the real Go SDK — including
# their signing and pagination — rather than a stand-in for any one of them.
#
#   ./test/parity/run_parity.sh
#
# Requires: aws-cli v2, jq, python3 with boto3, go.
# Any implementation whose toolchain is missing is reported as skipped rather
# than silently passing.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/datafy-parity.XXXXXX")"

FAILURES=0
pass() { printf '  ✓ %s\n' "$1"; }
fail() {
  printf '  ✗ %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '    %s\n' "$2"
  FAILURES=$(( FAILURES + 1 ))
  return 0
}
skip() { printf '  - %s (skipped: %s)\n' "$1" "$2"; }

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null
    # Reap it, so the shell does not print a "Terminated" job notice.
    wait "$SERVER_PID" 2>/dev/null
  fi
  [[ -d "$WORK" ]] && rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

# ── Scenario ───────────────────────────────────────────────────────────────────
# Deliberately mixes healthy, denied and un-assumable cases: parity on the happy
# path is easy, parity on how failures are *reported* is the thing that drifts.
cat > "$WORK/scenario.json" <<'JSON'
{
  "caller_account": "000000000000",
  "accounts": ["000000000000", "111111111111", "222222222222"],
  "regions":  ["us-east-1", "eu-west-1"],
  "volumes": 3,
  "instances": 2,
  "snapshots": 2,
  "ami_count": 2,
  "deny_assume": ["222222222222"],
  "deny": { "111111111111/eu-west-1": ["DescribeVolumes"] }
}
JSON

# ── Fake AWS ───────────────────────────────────────────────────────────────────
echo "Starting fake AWS endpoint..."
FAKE_AWS_SCENARIO="$WORK/scenario.json" python3 "$ROOT/test/lib/fake_aws.py" > "$WORK/port.txt" 2>"$WORK/server.log" &
SERVER_PID=$!

PORT=""
for _ in $(seq 1 100); do
  PORT=$(head -1 "$WORK/port.txt" 2>/dev/null)
  [[ -n "$PORT" ]] && break
  sleep 0.1
done
if [[ -z "$PORT" ]]; then
  echo "Error: fake AWS endpoint did not start." >&2
  cat "$WORK/server.log" >&2
  exit 1
fi
echo "  listening on 127.0.0.1:$PORT"

export AWS_ENDPOINT_URL="http://127.0.0.1:${PORT}"
export AWS_ACCESS_KEY_ID="AKIAPARITYCALLER"
export AWS_SECRET_ACCESS_KEY="parity-secret"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_REGION="us-east-1"
export AWS_EC2_METADATA_DISABLED="true"
export AWS_PAGER=""
unset AWS_PROFILE

# ── Normalisation ──────────────────────────────────────────────────────────────
# Drop what legitimately differs between runs, and sort records so scheduling
# order cannot masquerade as a difference.
#
# Error prose is truncated to its leading "<api>:" / "cannot ..." token. The
# three SDKs word the same AWS error completely differently — the CLI says
# "An error occurred (AccessDenied) when calling...", the Go SDK says
# "operation error STS: AssumeRole, https response error StatusCode: 403..." —
# and demanding identical text would mean asserting on AWS's own wording.
# What must match is the classification, which is the part we generate. The
# error codes themselves are checked separately below.
normalize() {
  jq -S '
    del(.scanned_at) | del(.tool_version)
    | if .errors then .errors |= (map(split(": ")[0]) | unique) else . end
    | if .reason then .reason |= split(": ")[0] else . end
  ' "$1" 2>/dev/null \
    | jq -sS 'sort_by([.record_type, (.account_id // ""), (.region // "")])' 2>/dev/null
}

run_impl() {
  local name="$1" out="$WORK/${1}.json" status=0
  shift
  "$@" > "$WORK/${name}.stdout" 2>"$WORK/${name}.stderr" || status=$?
  if [[ "$status" -ne 0 ]]; then
    fail "$name ran to completion" "exit $status — $(tail -2 "$WORK/${name}.stderr" | head -1)"
    return 1
  fi
  if [[ ! -s "$out" ]]; then
    fail "$name produced output" "output file empty"
    return 1
  fi
  normalize "$out" > "$WORK/${name}.norm.json"
  if [[ ! -s "$WORK/${name}.norm.json" ]]; then
    fail "$name produced valid JSONL" "could not parse $out"
    return 1
  fi
  pass "$name produced valid output"
  return 0
}

echo
echo "Running implementations..."

IMPLS=()

# -- bash ----------------------------------------------------------------------
if command -v aws >/dev/null 2>&1; then
  run_impl bash bash "$ROOT/bash/discovery.sh" --output "$WORK/bash.json" && IMPLS+=(bash)
else
  skip "bash" "aws-cli not installed"
fi

# -- python --------------------------------------------------------------------
if python3 -c "import boto3" >/dev/null 2>&1; then
  run_impl python python3 "$ROOT/python/discovery.py" --output "$WORK/python.json" && IMPLS+=(python)
else
  skip "python" "boto3 not installed"
fi

# -- go ------------------------------------------------------------------------
if command -v go >/dev/null 2>&1; then
  if ( cd "$ROOT/golang" && go build -o "$WORK/discovery-go" . ) 2>"$WORK/go-build.log"; then
    run_impl go "$WORK/discovery-go" -output "$WORK/go.json" && IMPLS+=(go)
  else
    fail "go builds" "$(head -3 "$WORK/go-build.log")"
  fi
else
  skip "go" "go toolchain not installed"
fi

# ── Compare ────────────────────────────────────────────────────────────────────
echo
echo "Comparing output..."

if [[ ${#IMPLS[@]} -lt 2 ]]; then
  fail "at least two implementations ran" "only ${#IMPLS[@]} available — nothing to compare"
else
  base="${IMPLS[0]}"
  for other in "${IMPLS[@]:1}"; do
    if diff -u "$WORK/${base}.norm.json" "$WORK/${other}.norm.json" > "$WORK/diff-${base}-${other}.txt"; then
      pass "$base and $other produce identical output"
    else
      cp "$WORK/diff-${base}-${other}.txt" "./parity-diff-${base}-${other}.txt" 2>/dev/null
      fail "$base and $other produce identical output" \
           "$(grep -c '^[+-]' "$WORK/diff-${base}-${other}.txt") differing line(s); full diff: ./parity-diff-${base}-${other}.txt"
    fi
  done

  # Beyond byte equality, the semantics the ticket cares about must hold
  # everywhere: the denied region reported, the un-assumable account named.
  for impl in "${IMPLS[@]}"; do
    f="$WORK/${impl}.json"

    got=$(jq -r 'select(.record_type == "region" and .account_id == "111111111111"
                        and .region == "eu-west-1") | .status' "$f" 2>/dev/null | head -1)
    if [[ "$got" == "partial" ]]; then
      pass "$impl: denied region reported as partial"
    else
      fail "$impl: denied region reported as partial" "got '${got:-<missing>}'"
    fi

    got=$(jq -r 'select(.record_type == "account" and .account_id == "222222222222") | .status' \
          "$f" 2>/dev/null | head -1)
    if [[ "$got" == "skipped" ]]; then
      pass "$impl: un-assumable account reported as skipped"
    else
      fail "$impl: un-assumable account reported as skipped" "got '${got:-<missing>}'"
    fi

    got=$(jq -r 'select(.record_type == "summary") | .accounts_total' "$f" 2>/dev/null | head -1)
    if [[ "$got" == "3" ]]; then
      pass "$impl: summary counts all 3 accounts"
    else
      fail "$impl: summary counts all 3 accounts" "got '${got:-<missing>}'"
    fi

    # The SDK wording is normalised away above, so check here that each
    # implementation still surfaces the underlying AWS error code — that is
    # what tells a reader whether to fix IAM or something else.
    if jq -r 'select(.record_type == "region") | .errors[]?' "$f" 2>/dev/null \
       | grep -q 'UnauthorizedOperation'; then
      pass "$impl: region error carries the AWS error code"
    else
      fail "$impl: region error carries the AWS error code" \
           "no UnauthorizedOperation in any region's errors"
    fi

    if jq -r 'select(.record_type == "account") | .reason' "$f" 2>/dev/null \
       | grep -q 'AccessDenied'; then
      pass "$impl: skip reason carries the AWS error code"
    else
      fail "$impl: skip reason carries the AWS error code" \
           "no AccessDenied in any account reason"
    fi

    # Timestamps must be RFC3339 with a Z suffix in every implementation —
    # "+00:00" and "Z" are both valid but they are not interchangeable to a
    # consumer doing string comparison.
    bad=$(jq -r '[.. | strings | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T.*\\+00:00$"))] | length' \
          "$f" 2>/dev/null | awk '{s+=$1} END {print s+0}')
    if [[ "${bad:-0}" == "0" ]]; then
      pass "$impl: timestamps are Z-suffixed RFC3339"
    else
      fail "$impl: timestamps are Z-suffixed RFC3339" "$bad value(s) ended in +00:00"
    fi
  done
fi

echo
echo "─────────────────────────────────────"
if [[ "$FAILURES" -eq 0 ]]; then
  echo "Parity holds across: ${IMPLS[*]}"
  exit 0
fi
echo "$FAILURES parity check(s) failed."
exit 1
