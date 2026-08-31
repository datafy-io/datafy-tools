#!/usr/bin/env bash
# Cross-implementation parity harness for the Azure discovery tool.
#
# Where the behavioural suite asks whether each implementation is *correct*,
# this asks whether they are *identical*: it runs one scenario through all three
# and diffs the normalised output line for line. That catches drift the per-case
# assertions would not think to look for — a renamed field, a differently
# rounded number, a reordered array, a null that became an empty string.
#
#   ./azure/test/parity/run_parity.sh
#
# Requires: jq, curl, a Python with azure-identity (for the Python
# implementation) and cryptography (for the fake ARM), and go.
# Any implementation whose toolchain is missing is reported as skipped rather
# than silently passing.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT="$(dirname "$HERE")"
AZURE_ROOT="$(dirname "$TEST_ROOT")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/datafy-azure-parity.XXXXXX")"

PYTHON_BIN="${DISCOVERY_PYTHON:-python3}"

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

for dep in jq curl; do
  command -v "$dep" >/dev/null 2>&1 || { echo "Error: '$dep' is required." >&2; exit 1; }
done
"$PYTHON_BIN" -c "import cryptography" >/dev/null 2>&1 || {
  echo "Error: the fake ARM endpoint needs the 'cryptography' package for '$PYTHON_BIN'." >&2
  exit 1
}

# ── Scenario ───────────────────────────────────────────────────────────────────
# Deliberately mixes healthy, denied, unreadable and disabled subscriptions:
# parity on the happy path is easy, parity on how failures are *reported* is the
# thing that drifts. Pagination is forced on, and one subscription is invisible
# so the unreachable-record path is covered too.
cat > "$WORK/scenario.json" <<'JSON'
{
  "tenant_id": "11111111-1111-1111-1111-111111111111",
  "subscriptions": [
    {"id": "aaaaaaaa-0000-0000-0000-000000000001", "name": "Prod",     "state": "Enabled"},
    {"id": "bbbbbbbb-0000-0000-0000-000000000002", "name": "Non-prod", "state": "Enabled"},
    {"id": "cccccccc-0000-0000-0000-000000000003", "name": "Denied",   "state": "Enabled"},
    {"id": "dddddddd-0000-0000-0000-000000000004", "name": "Old",      "state": "Disabled"},
    {"id": "eeeeeeee-0000-0000-0000-000000000005", "name": "Unseen",   "state": "Enabled"}
  ],
  "invisible_subscriptions": ["eeeeeeee-0000-0000-0000-000000000005"],
  "locations": ["westeurope", "eastus", "northeurope"],
  "page_size": 3,
  "disks": 7, "vms": 4, "snapshots": 5, "images": 2, "scale_sets": 2,
  "vaults": 1, "policies": 2,
  "deny_by_subscription": {
    "bbbbbbbb-0000-0000-0000-000000000002": ["Microsoft.Compute/snapshots"],
    "cccccccc-0000-0000-0000-000000000003": ["*"]
  }
}
JSON

# ── Fake ARM ───────────────────────────────────────────────────────────────────
echo "Starting fake ARM endpoint..."
FAKE_ARM_SCENARIO="$WORK/scenario.json" FAKE_ARM_CERT_DIR="$WORK/certs" \
  "$PYTHON_BIN" "$TEST_ROOT/lib/fake_arm.py" > "$WORK/port.txt" 2>"$WORK/server.log" &
SERVER_PID=$!

PORT=""
for _ in $(seq 1 200); do
  PORT=$(head -1 "$WORK/port.txt" 2>/dev/null)
  [[ -n "$PORT" ]] && break
  sleep 0.1
done
if [[ -z "$PORT" ]]; then
  echo "Error: fake ARM endpoint did not start." >&2
  cat "$WORK/server.log" >&2
  exit 1
fi
echo "  listening on 127.0.0.1:$PORT"

export AZURE_ARM_ENDPOINT="https://127.0.0.1:${PORT}"
# A syntactically real JWT: --setup-role reads the principal out of the oid
# claim, and the tenant hint out of tid.
AZURE_ACCESS_TOKEN="$("$PYTHON_BIN" - <<'PY'
import base64, json
def seg(d):
    return base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()
print(".".join([
    seg({"alg": "none", "typ": "JWT"}),
    seg({"oid": "99999999-9999-9999-9999-999999999999",
         "tid": "11111111-1111-1111-1111-111111111111"}),
    "not-a-real-signature",
]))
PY
)"
export AZURE_ACCESS_TOKEN
# One certificate, three HTTP stacks, three standard ways of naming a private CA.
export REQUESTS_CA_BUNDLE="$WORK/certs/cert.pem"
export SSL_CERT_FILE="$WORK/certs/cert.pem"
export CURL_CA_BUNDLE="$WORK/certs/cert.pem"
export AZURE_RETRY_BACKOFF="0.01"
export AZURE_RETRY_BACKOFF_MAX="0.05"

# ── Normalisation ──────────────────────────────────────────────────────────────
# Only the wall-clock stamp is dropped, and records are sorted so scheduling
# order cannot masquerade as a difference. Everything else — every field name,
# every value, every error string — has to match exactly.
#
# The comparison can be exact because all three implementations build their
# error text themselves from ARM's own JSON rather than from a client library's
# wording — so the text is ours, and it has to agree.
normalize() {
  jq -S 'del(.scanned_at)' "$1" 2>/dev/null \
    | jq -sS 'sort_by([.record_type, (.subscription_id // "")])' 2>/dev/null
}

run_impl() {
  local name="$1"; shift
  local out="$WORK/${name}.json" status=0
  "$@" --output "$out" > "$WORK/${name}.stdout" 2>"$WORK/${name}.stderr" || status=$?
  if [[ "$status" -ne 0 ]]; then
    fail "$name ran to completion" "exit $status — $(tail -3 "$WORK/${name}.stderr" | head -1)"
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
run_impl bash bash "$AZURE_ROOT/bash/discovery.sh" && IMPLS+=(bash)

# -- python --------------------------------------------------------------------
if "$PYTHON_BIN" -c "import azure.identity, azure.core" >/dev/null 2>&1; then
  run_impl python "$PYTHON_BIN" "$AZURE_ROOT/python/discovery.py" && IMPLS+=(python)
else
  skip "python" "azure-identity not installed for $PYTHON_BIN"
fi

# -- go ------------------------------------------------------------------------
if command -v go >/dev/null 2>&1; then
  if ( cd "$AZURE_ROOT/golang" && go build -o "$WORK/discovery-go" . ) 2>"$WORK/go-build.log"; then
    run_impl go "$WORK/discovery-go" && IMPLS+=(go)
  else
    fail "go builds" "$(head -3 "$WORK/go-build.log")"
  fi
else
  skip "go" "go toolchain not installed"
fi

if [[ ${#IMPLS[@]} -lt 2 ]]; then
  echo
  echo "Error: parity needs at least two implementations; only ${#IMPLS[@]} ran." >&2
  exit 1
fi

# ── Diff ───────────────────────────────────────────────────────────────────────
echo
echo "Comparing output..."

BASE="${IMPLS[0]}"
for impl in "${IMPLS[@]:1}"; do
  if diff -u "$WORK/${BASE}.norm.json" "$WORK/${impl}.norm.json" > "$WORK/${impl}.diff" 2>&1; then
    pass "$impl matches $BASE line for line"
  else
    fail "$impl matches $BASE line for line" \
      "first difference:
$(head -25 "$WORK/${impl}.diff" | sed 's/^/      /')"
  fi
done

# ── Content checks ─────────────────────────────────────────────────────────────
# Parity on an empty file would pass the diff above, so assert the scenario
# actually produced the records it was built to produce.
echo
echo "Checking the compared output is not vacuous..."

for impl in "${IMPLS[@]}"; do
  norm="$WORK/${impl}.norm.json"
  n() { jq -r "$1" "$norm" 2>/dev/null; }

  [[ "$(n '[.[] | select(.record_type == "subscription")] | length')" == "5" ]] \
    && pass "$impl: all five subscriptions are represented" \
    || fail "$impl: all five subscriptions are represented" "got $(n '[.[] | select(.record_type == "subscription")] | length')"

  [[ "$(n '[.[] | select(.status == "ok")] | length')" == "1" ]] \
    && pass "$impl: one healthy subscription" \
    || fail "$impl: one healthy subscription" "got $(n '[.[] | select(.status == "ok")] | length')"

  [[ "$(n '[.[] | select(.status == "partial")] | length')" == "1" ]] \
    && pass "$impl: one partially-denied subscription" \
    || fail "$impl: one partially-denied subscription" "got $(n '[.[] | select(.status == "partial")] | length')"

  [[ "$(n '[.[] | select(.status == "skipped")] | length')" == "1" ]] \
    && pass "$impl: one skipped subscription" \
    || fail "$impl: one skipped subscription" "got $(n '[.[] | select(.status == "skipped")] | length')"

  # The denied one and the invisible one both land as failed.
  [[ "$(n '[.[] | select(.status == "failed")] | length')" == "2" ]] \
    && pass "$impl: two unreadable subscriptions" \
    || fail "$impl: two unreadable subscriptions" "got $(n '[.[] | select(.status == "failed")] | length')"

  [[ "$(n '[.[] | .disks // [] | length] | add')" == "14" ]] \
    && pass "$impl: every page of disks arrived" \
    || fail "$impl: every page of disks arrived" "got $(n '[.[] | .disks // [] | length] | add')"

  [[ "$(n '[.[] | .virtual_machines // [] | length] | add')" == "8" ]] \
    && pass "$impl: every VM arrived" \
    || fail "$impl: every VM arrived" "got $(n '[.[] | .virtual_machines // [] | length] | add')"

  [[ "$(n '[.[] | (.virtual_machines // [])[] | select(.power_state != null)] | length')" != "0" ]] \
    && pass "$impl: power state was collected" \
    || fail "$impl: power state was collected" "no VM has a power_state"

  [[ "$(n '[.[] | select(.record_type == "summary")] | length')" == "1" ]] \
    && pass "$impl: exactly one summary record" \
    || fail "$impl: exactly one summary record"

  [[ "$(n '.[] | select(.record_type == "summary") | .scope_verified')" == "true" ]] \
    && pass "$impl: scope was verified against the hierarchy" \
    || fail "$impl: scope was verified against the hierarchy"

  [[ "$(n '[.[] | select(.record_type == "subscription") | .errors[]? | select(test("AuthorizationFailed"))] | length')" != "0" ]] \
    && pass "$impl: denials carry the Azure error code" \
    || fail "$impl: denials carry the Azure error code"
done

printf '\n─────────────────────────────────────\n'
if [[ "$FAILURES" -eq 0 ]]; then
  printf 'Parity holds across: %s\n' "${IMPLS[*]}"
  exit 0
fi
printf '%d parity check(s) failed.\n' "$FAILURES"
exit 1
