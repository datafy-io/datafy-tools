#!/usr/bin/env bash
# Shared harness for discovery.sh test cases.
#
# Sourced by run_tests.sh before each case file. Provides sandbox setup, a
# `run_discovery` wrapper that puts the mock AWS CLI on PATH, and assertions.
# Cases report failure by incrementing FAILURES.

TEST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(dirname "$TEST_LIB_DIR")"
DISCOVERY_SH="$(dirname "$TEST_ROOT")/discovery.sh"

FAILURES=0
ASSERTIONS=0

# ── Sandbox ────────────────────────────────────────────────────────────────────

# Creates SANDBOX with a bin/ containing the mock `aws`, and exports the paths
# each case works with. Called once per case.
setup_sandbox() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/datafy-test.XXXXXX")"
  mkdir -p "$SANDBOX/bin"

  # Shim named `aws` so discovery.sh's `command -v aws` and every call resolve here.
  cat > "$SANDBOX/bin/aws" <<EOF
#!/usr/bin/env bash
exec "$TEST_LIB_DIR/mock_aws.sh" "\$@"
EOF
  chmod +x "$SANDBOX/bin/aws"

  OUTPUT_FILE="$SANDBOX/discovery.json"
  STDERR_FILE="$SANDBOX/stderr.log"

  # Cross-process bookkeeping for the mock (call counts, in-flight registry).
  MOCK_STATE_DIR="$SANDBOX/state"
  mkdir -p "$MOCK_STATE_DIR/live"
  export MOCK_STATE_DIR
}

teardown_sandbox() {
  [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
  return 0
}

# ── Running the tool ───────────────────────────────────────────────────────────

# run_discovery [extra discovery.sh args...]
# Captures stderr to STDERR_FILE and the exit status to DISCOVERY_STATUS.
run_discovery() {
  DISCOVERY_STATUS=0
  PATH="$SANDBOX/bin:$PATH" \
    bash "$DISCOVERY_SH" --output "$OUTPUT_FILE" "$@" \
    >/dev/null 2>"$STDERR_FILE" || DISCOVERY_STATUS=$?
}

# Start the tool without blocking, so a case can act while it is mid-scan.
run_discovery_bg() {
  DISCOVERY_STATUS=""
  PATH="$SANDBOX/bin:$PATH" \
    bash "$DISCOVERY_SH" --output "$OUTPUT_FILE" "$@" \
    >/dev/null 2>"$STDERR_FILE" &
  DISCOVERY_PID=$!
}

# wait_for_stderr PATTERN COUNT [TIMEOUT_SECONDS]
# Block until PATTERN has appeared COUNT times on the tool's stderr.
wait_for_stderr() {
  local pattern="$1" want="$2" timeout="${3:-60}" ticks=0 got
  while (( ticks < timeout * 10 )); do
    # grep -c always prints a count, and exits 1 on zero matches — an `|| echo 0`
    # here would append a second line and break the arithmetic below.
    got=$(grep -c -- "$pattern" "$STDERR_FILE" 2>/dev/null)
    (( ${got:-0} >= want )) && return 0
    sleep 0.1
    ticks=$(( ticks + 1 ))
  done
  return 1
}

# Signal the running tool. Defaults to TERM rather than INT: a shell started in
# the background inherits SIGINT as ignored, and a signal that was ignored on
# entry cannot be trapped — so `kill -INT` here would be silently discarded no
# matter what the tool does. TERM reaches the same handler and models the case
# that actually bit the customer: a run killed by a timeout.
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

# Highest number of inventory calls the mock ever saw in flight at once.
peak_concurrency() {
  local max=0 n
  while IFS= read -r n; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    (( n > max )) && max=$n
  done < "${MOCK_STATE_DIR}/peak.log" 2>/dev/null
  echo "$max"
}

# The job caps the tool sized itself to, read back from its own startup log.
job_limit_product() {
  local accounts regions
  accounts=$(grep -o '[0-9]\{1,\} accounts' "$STDERR_FILE" 2>/dev/null | head -1 | grep -o '[0-9]\{1,\}')
  regions=$(grep -o '[0-9]\{1,\} regions' "$STDERR_FILE" 2>/dev/null | head -1 | grep -o '[0-9]\{1,\}')
  [[ -z "$accounts" || -z "$regions" ]] && { echo 0; return; }
  echo $(( accounts * regions ))
}

# ── Output queries ─────────────────────────────────────────────────────────────

# Every JSON line the run produced.
output_lines() {
  [[ -s "$OUTPUT_FILE" ]] || return 0
  cat "$OUTPUT_FILE"
}

# Count of records for a given account (any region).
records_for_account() {
  output_lines | jq -c --arg a "$1" 'select(.account_id == $a)' 2>/dev/null | grep -c . || true
}

# The single record for account/region, or empty if absent.
record_for() {
  output_lines | jq -c --arg a "$1" --arg r "$2" \
    'select(.account_id == $a and .region == $r)' 2>/dev/null || true
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

# Fails when the pattern IS found in stderr.
assert_stderr_lacks() {
  local pattern="$1" msg="$2"
  if grep -qF "$pattern" "$STDERR_FILE" 2>/dev/null; then
    _fail "$msg" "stderr contained: $(grep -F -m1 "$pattern" "$STDERR_FILE")"
  else
    _pass "$msg"
  fi
}

# Fails when the pattern is NOT found in stderr.
assert_stderr_has() {
  local pattern="$1" msg="$2"
  if grep -qF "$pattern" "$STDERR_FILE" 2>/dev/null; then
    _pass "$msg"
  else
    _fail "$msg" "stderr did not contain: $pattern"
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
