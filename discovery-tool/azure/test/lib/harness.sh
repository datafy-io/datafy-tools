#!/usr/bin/env bash
# Shared harness for the Azure discovery tool's test suite.
#
# Sourced by run_tests.sh before each case file. A case describes the tenant it
# wants as a scenario, calls run_discovery, and asserts on the output.
#
# Everything talks to test/lib/fake_arm.py — a fake ARM served over HTTPS —
# through AZURE_ARM_ENDPOINT. The real azure-core pipeline is under test:
# its credential policy, its retry policy and its nextLink pagination all run
# exactly as they would against Azure. HTTPS rather than plain http because
# azure-core refuses to attach a bearer token to an unencrypted URL, and
# weakening that in the tool to make it testable would be testing a tool nobody
# runs.

TEST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(dirname "$TEST_LIB_DIR")"
AZURE_ROOT="$(dirname "$TEST_ROOT")"
FAKE_ARM="$TEST_LIB_DIR/fake_arm.py"
DISCOVERY="$AZURE_ROOT/discovery.py"

PYTHON_BIN="${DISCOVERY_PYTHON:-python3}"

FAILURES=0
ASSERTIONS=0

# Most subscriptions the tool may have in flight at once, and most ARM calls.
# Both are pinned constants in discovery.py; a case asserts the tool stays
# within them rather than re-deriving them.
impl_subscription_cap() { echo 20; }
impl_call_cap()         { echo $(( 20 * 8 )); }

# Exit status expected from a run stopped by SIGTERM: 128 + 15.
impl_interrupt_status() { echo 143; }

# ── Sandbox ────────────────────────────────────────────────────────────────────

setup_sandbox() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/datafy-azure-test.XXXXXX")"
  OUTPUT_FILE="$SANDBOX/discovery.json"
  STDOUT_FILE="$SANDBOX/stdout.log"
  STDERR_FILE="$SANDBOX/stderr.log"
  SCENARIO_FILE="$SANDBOX/scenario.json"
  CERT_DIR="$SANDBOX/certs"
  : > "$STDOUT_FILE"
  : > "$STDERR_FILE"
  FAKE_PID=""
  FAKE_PORT=""

  # A scenario a case can run without describing anything itself.
  scenario <<'JSON'
{ "subscriptions": ["00000000-0000-0000-0000-000000000001"],
  "disks": 2, "vms": 1, "snapshots": 1, "images": 1, "scale_sets": 1,
  "vaults": 1, "policies": 1 }
JSON
}

teardown_sandbox() {
  stop_fake
  [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
  return 0
}

# ── The fake ARM endpoint ──────────────────────────────────────────────────────

# scenario <<'JSON' ... JSON — describe the tenant this case needs.
scenario() { cat > "$SCENARIO_FILE"; }

# Apply a new scenario within a case. The endpoint reads its scenario once at
# startup, so it has to be restarted — which also resets the bookkeeping that
# /__stats reports, giving the second run a clean slate.
restart_fake() { stop_fake; FAKE_PORT=""; return 0; }

start_fake() {
  [[ -n "${FAKE_PID:-}" ]] && return 0

  FAKE_ARM_SCENARIO="$SCENARIO_FILE" FAKE_ARM_CERT_DIR="$CERT_DIR" \
    "$PYTHON_BIN" "$FAKE_ARM" > "$SANDBOX/port.txt" 2>"$SANDBOX/fake.log" &
  FAKE_PID=$!

  local tick=0
  while (( tick < 200 )); do
    FAKE_PORT=$(head -1 "$SANDBOX/port.txt" 2>/dev/null)
    [[ -n "$FAKE_PORT" ]] && break
    sleep 0.1
    tick=$(( tick + 1 ))
  done
  if [[ -z "$FAKE_PORT" ]]; then
    _fail "fake ARM endpoint started" "$(head -5 "$SANDBOX/fake.log" 2>/dev/null)"
    return 1
  fi

  export AZURE_ARM_ENDPOINT="https://127.0.0.1:${FAKE_PORT}"
  # The token the tool signs with. Set explicitly so the suite never reaches for
  # a real credential — an az-cli login on the machine running the tests must
  # not change what the tests do.
  export AZURE_ACCESS_TOKEN="fake-test-token"
  # How requests learns to trust the fake's self-signed certificate.
  export REQUESTS_CA_BUNDLE="$CERT_DIR/cert.pem"
  # Keep the backoff short: cases that exercise retries should not spend the
  # suite's wall-clock sleeping.
  export AZURE_RETRY_BACKOFF="${AZURE_RETRY_BACKOFF:-0.01}"
  export AZURE_RETRY_BACKOFF_MAX="${AZURE_RETRY_BACKOFF_MAX:-0.05}"
  return 0
}

stop_fake() {
  if [[ -n "${FAKE_PID:-}" ]]; then
    kill "$FAKE_PID" 2>/dev/null
    wait "$FAKE_PID" 2>/dev/null
    FAKE_PID=""
  fi
  return 0
}

# fake_stat KEY — read the endpoint's own bookkeeping (calls, peak_concurrent,
# throttled, pages). Must be called before the fake is stopped.
fake_stat() {
  [[ -n "${FAKE_PORT:-}" ]] || { echo 0; return; }
  curl -sk "https://127.0.0.1:${FAKE_PORT}/__stats" 2>/dev/null \
    | jq -r --arg k "$1" '.[$k] // 0' 2>/dev/null || echo 0
}

# fake_calls_for TYPE — how many times a resource type was listed.
fake_calls_for() {
  [[ -n "${FAKE_PORT:-}" ]] || { echo 0; return; }
  curl -sk "https://127.0.0.1:${FAKE_PORT}/__stats" 2>/dev/null \
    | jq -r --arg k "$1" '.by_type[$k] // 0' 2>/dev/null || echo 0
}

# ── Running the tool ───────────────────────────────────────────────────────────

# run_discovery_to OUTPUT [extra args...] — run to completion, writing to OUTPUT.
# Captures stdout and stderr separately, and the exit status in DISCOVERY_STATUS.
run_discovery_to() {
  start_fake || return 1
  local out="$1"; shift
  DISCOVERY_STATUS=0
  "$PYTHON_BIN" "$DISCOVERY" --output "$out" "$@" \
    >"$STDOUT_FILE" 2>"$STDERR_FILE" || DISCOVERY_STATUS=$?
}

run_discovery() { run_discovery_to "$OUTPUT_FILE" "$@"; }

# Start the tool without blocking, so a case can act while it is mid-scan.
run_discovery_bg() {
  start_fake || return 1
  DISCOVERY_STATUS=""
  "$PYTHON_BIN" "$DISCOVERY" --output "$OUTPUT_FILE" "$@" \
    >"$STDOUT_FILE" 2>"$STDERR_FILE" &
  DISCOVERY_PID=$!
}

# Everything the operator was told, whichever stream carried it.
log_lines() { cat "$STDOUT_FILE" "$STDERR_FILE" 2>/dev/null; }

# The line the tool prints when a subscription finishes.
SUBSCRIPTION_DONE_PATTERN='— (ok|partial|failed), [0-9]+ disks'

# wait_for_subscriptions COUNT [TIMEOUT] — block until COUNT subscriptions have
# reported done, so a case can be sure there is finished work to lose.
wait_for_subscriptions() {
  local want="$1" timeout="${2:-60}" ticks=0 got
  while (( ticks < timeout * 10 )); do
    got=$(log_lines | grep -cE -- "$SUBSCRIPTION_DONE_PATTERN" 2>/dev/null)
    (( ${got:-0} >= want )) && return 0
    sleep 0.1
    ticks=$(( ticks + 1 ))
  done
  return 1
}

# Signal the running tool. Defaults to TERM rather than INT: a process started
# in the background inherits SIGINT as ignored, and a signal that was ignored on
# entry cannot be trapped — so `kill -INT` here would be silently discarded no
# matter what the tool does. TERM reaches the same handler and models the case
# that actually happens: a run killed by a timeout.
interrupt_discovery() { kill -"${1:-TERM}" "$DISCOVERY_PID" 2>/dev/null || true; }

# Reap the background run, with a watchdog so a hung tool fails the case rather
# than hanging the suite.
wait_for_discovery() {
  local timeout="${1:-60}" watchdog
  ( sleep "$timeout"; kill -KILL "$DISCOVERY_PID" 2>/dev/null ) &
  watchdog=$!
  wait "$DISCOVERY_PID" 2>/dev/null
  DISCOVERY_STATUS=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
}

# ── Output queries ─────────────────────────────────────────────────────────────

output_lines() {
  [[ -s "$OUTPUT_FILE" ]] || return 0
  cat "$OUTPUT_FILE"
}

# Number of records matching a jq select expression.
count_records() {
  output_lines | jq -c "select($1)" 2>/dev/null | grep -c . || true
}

# The single subscription record for an id, or empty if absent.
record_for() {
  output_lines | jq -c --arg s "$1" \
    'select(.record_type == "subscription" and .subscription_id == $s)' 2>/dev/null || true
}

# field_of SUBSCRIPTION JQPATH — one field of one subscription record.
field_of() {
  record_for "$1" | jq -r "$2" 2>/dev/null || true
}

# len_of SUBSCRIPTION ARRAY — length of one array in one subscription record.
len_of() {
  record_for "$1" | jq -r ".$2 | length" 2>/dev/null || echo 0
}

summary_record() {
  output_lines | jq -c 'select(.record_type == "summary")' 2>/dev/null || true
}

# Sum of a top-level array's length across all records.
total_len() {
  output_lines | jq -s --arg k "$1" '[.[] | .[$k] // [] | length] | add // 0' 2>/dev/null || echo 0
}

# ── Assertions ─────────────────────────────────────────────────────────────────

_pass() { ASSERTIONS=$(( ASSERTIONS + 1 )); printf '    ✓ %s\n' "$1"; }
_fail() {
  ASSERTIONS=$(( ASSERTIONS + 1 ))
  FAILURES=$(( FAILURES + 1 ))
  printf '    ✗ %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '      %s\n' "$2"
  return 0
}

assert_equals() {
  local expected="$1" actual="$2" msg="$3"
  if [[ "$expected" == "$actual" ]]; then
    _pass "$msg"
  else
    _fail "$msg" "expected: [$expected]  actual: [$actual]"
  fi
}

assert_not_empty() {
  local value="$1" msg="$2"
  if [[ -n "$value" ]]; then _pass "$msg"; else _fail "$msg" "value was empty"; fi
}

assert_empty() {
  local value="$1" msg="$2"
  if [[ -z "$value" ]]; then _pass "$msg"; else _fail "$msg" "value was [$value]"; fi
}

assert_at_least() {
  local minimum="$1" actual="$2" msg="$3"
  if [[ "${actual:-0}" -ge "$minimum" ]]; then
    _pass "$msg"
  else
    _fail "$msg" "expected at least $minimum, got ${actual:-0}"
  fi
}

assert_at_most() {
  local ceiling="$1" actual="$2" msg="$3"
  if [[ "${actual:-0}" -le "$ceiling" ]]; then
    _pass "$msg"
  else
    _fail "$msg" "expected at most $ceiling, got ${actual:-0}"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    _pass "$msg"
  else
    _fail "$msg" "[$haystack] does not contain [$needle]"
  fi
}

assert_log_has() {
  local pattern="$1" msg="$2"
  if log_lines | grep -qF -- "$pattern"; then
    _pass "$msg"
  else
    _fail "$msg" "no line mentioned: $pattern"
  fi
}

assert_log_lacks() {
  local pattern="$1" msg="$2"
  if log_lines | grep -qF -- "$pattern"; then
    _fail "$msg" "a line contained: $(log_lines | grep -F -m1 -- "$pattern")"
  else
    _pass "$msg"
  fi
}

# Every line of the output file must be valid JSON.
assert_valid_jsonl() {
  local msg="$1" rc
  output_lines | jq -e . >/dev/null 2>&1
  rc=$?
  if [[ "$rc" == "0" ]]; then
    _pass "$msg"
  else
    _fail "$msg" "output is not valid JSONL"
  fi
}
