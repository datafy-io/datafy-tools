#!/usr/bin/env bash
# Shared harness for the cross-implementation test suite.
#
# Sourced by run_tests.sh before each case file, once per implementation. A case
# describes the org it wants as a scenario, calls run_discovery, and asserts on
# the output — without ever naming bash, Python or Go. $IMPL selects which
# implementation the current pass is exercising.
#
# Everything talks to the same fake AWS endpoint over AWS_ENDPOINT_URL, so the
# real AWS CLI, real boto3 and the real Go SDK are all under test, including
# their signing and their pagination.

TEST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(dirname "$TEST_LIB_DIR")"
REPO_ROOT="$(dirname "$TEST_ROOT")"
FAKE_AWS="$TEST_LIB_DIR/fake_aws.py"

FAILURES=0
ASSERTIONS=0

# ── Implementation profiles ────────────────────────────────────────────────────
# What differs legitimately between the three, stated once here rather than
# smuggled into individual cases as if-then chains.

impl_display_name() {
  case "$IMPL" in
    bash)   echo "bash/discovery.sh" ;;
    python) echo "python/discovery.py" ;;
    go)     echo "golang (compiled)" ;;
  esac
}

# Exit status expected from a run stopped by SIGTERM: 128 + 15.
impl_interrupt_status() { echo 143; }

# Most accounts the implementation may have in flight at once, and most
# inventory calls. Python and Go pin these as constants (20 accounts x 10
# regions); bash sizes them at runtime from available RAM and logs the figure it
# chose, so its cap is read back from its own startup log.
impl_account_cap() {
  if [[ "$IMPL" == "bash" ]]; then _bash_job_limit 1; else echo 20; fi
}

impl_call_cap() {
  if [[ "$IMPL" == "bash" ]]; then
    local a r
    a=$(_bash_job_limit 1); r=$(_bash_job_limit 2)
    echo $(( a * r ))
  else
    echo 200
  fi
}

# bash logs "Jobs: N accounts × M regions" at startup. Field 1 is N, 2 is M.
_bash_job_limit() {
  local field="$1" value
  value=$(grep -o '[0-9]\{1,\} accounts × [0-9]\{1,\} regions' "$STDERR_FILE" 2>/dev/null | head -1)
  [[ -z "$value" ]] && { echo 0; return; }
  if [[ "$field" == "1" ]]; then
    echo "$value" | grep -o '^[0-9]\{1,\}'
  else
    echo "$value" | grep -o '[0-9]\{1,\} regions' | grep -o '[0-9]\{1,\}'
  fi
}

# ── Sandbox ────────────────────────────────────────────────────────────────────

setup_sandbox() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/datafy-test.XXXXXX")"
  OUTPUT_FILE="$SANDBOX/discovery.json"
  STDOUT_FILE="$SANDBOX/stdout.log"
  STDERR_FILE="$SANDBOX/stderr.log"
  SCENARIO_FILE="$SANDBOX/scenario.json"
  : > "$STDOUT_FILE"
  : > "$STDERR_FILE"
  FAKE_PID=""
  FAKE_PORT=""

  # A scenario a case can run without describing anything itself.
  scenario <<'JSON'
{ "caller_account": "000000000000",
  "accounts": ["000000000000"],
  "regions": ["us-east-1"],
  "volumes": 1, "instances": 1, "snapshots": 1 }
JSON
}

teardown_sandbox() {
  stop_fake
  [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
  return 0
}

# ── The fake AWS endpoint ──────────────────────────────────────────────────────

# scenario <<'JSON' ... JSON — describe the org this case needs.
scenario() { cat > "$SCENARIO_FILE"; }

# Apply a new scenario within a case. The endpoint reads its scenario once at
# startup, so it has to be restarted — which also resets the bookkeeping that
# /__stats reports, giving the second run a clean slate.
restart_fake() { stop_fake; FAKE_PORT=""; return 0; }

start_fake() {
  [[ -n "${FAKE_PID:-}" ]] && return 0

  FAKE_AWS_SCENARIO="$SCENARIO_FILE" python3 "$FAKE_AWS" \
    > "$SANDBOX/port.txt" 2>"$SANDBOX/fake.log" &
  FAKE_PID=$!

  local tick=0
  while (( tick < 100 )); do
    FAKE_PORT=$(head -1 "$SANDBOX/port.txt" 2>/dev/null)
    [[ -n "$FAKE_PORT" ]] && break
    sleep 0.1
    tick=$(( tick + 1 ))
  done
  if [[ -z "$FAKE_PORT" ]]; then
    _fail "fake AWS endpoint started" "$(head -3 "$SANDBOX/fake.log" 2>/dev/null)"
    return 1
  fi

  # Every client honours these, which is the whole reason one endpoint can serve
  # all three implementations.
  export AWS_ENDPOINT_URL="http://127.0.0.1:${FAKE_PORT}"
  export AWS_ACCESS_KEY_ID="AKIATESTCALLER"
  export AWS_SECRET_ACCESS_KEY="test-secret"
  export AWS_DEFAULT_REGION="us-east-1"
  export AWS_REGION="us-east-1"
  export AWS_EC2_METADATA_DISABLED="true"
  export AWS_PAGER=""
  unset AWS_PROFILE
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

# fake_stat KEY — read the endpoint's own bookkeeping (peak_calls, data_calls,
# peak_accounts, max_image_ids). Must be called before the fake is stopped.
fake_stat() {
  [[ -n "${FAKE_PORT:-}" ]] || { echo 0; return; }
  curl -s "http://127.0.0.1:${FAKE_PORT}/__stats" 2>/dev/null \
    | jq -r --arg k "$1" '.[$k] // 0' 2>/dev/null || echo 0
}

# ── Running the tool ───────────────────────────────────────────────────────────

# The command for the implementation under test, as pipe-separated words. All
# three accept --output; Go's flag package treats --output and -output alike.
_discovery_argv() {
  case "$IMPL" in
    bash)   echo "bash|$REPO_ROOT/bash/discovery.sh" ;;
    python) echo "python3|$REPO_ROOT/python/discovery.py" ;;
    go)     echo "$DISCOVERY_GO_BIN" ;;
  esac
}

# run_discovery_to OUTPUT [extra args...] — run to completion, writing to OUTPUT.
# Captures stdout and stderr separately, and the exit status in DISCOVERY_STATUS.
run_discovery_to() {
  start_fake || return 1
  local out="$1"; shift
  DISCOVERY_STATUS=0
  local argv; argv="$(_discovery_argv)"
  local IFS='|'
  # shellcheck disable=SC2086 — splitting the pipe-separated argv is deliberate
  ${argv} --output "$out" "$@" >"$STDOUT_FILE" 2>"$STDERR_FILE" \
    || DISCOVERY_STATUS=$?
}

run_discovery() { run_discovery_to "$OUTPUT_FILE" "$@"; }

# Start the tool without blocking, so a case can act while it is mid-scan.
run_discovery_bg() {
  start_fake || return 1
  DISCOVERY_STATUS=""
  local argv; argv="$(_discovery_argv)"
  local IFS='|'
  # shellcheck disable=SC2086
  ${argv} --output "$OUTPUT_FILE" "$@" >"$STDOUT_FILE" 2>"$STDERR_FILE" &
  DISCOVERY_PID=$!
}

# Everything the operator was told, whichever stream carried it.
log_lines() { cat "$STDOUT_FILE" "$STDERR_FILE" 2>/dev/null; }

# The line each implementation prints when an account finishes. bash reports
# "[done] <account> — N regions"; Python and Go report "[i/N] <account> — R
# regions". All three end the line the same way, which is what this matches.
#
# The em dash is load-bearing: bash also logs "Jobs: 4 accounts × 4 regions" at
# startup, and a pattern of just " regions$" would count that as an account.
ACCOUNT_DONE_PATTERN='— [0-9]+ regions$'

# wait_for_accounts COUNT [TIMEOUT] — block until COUNT accounts have reported
# done, so a case can be sure there is finished work to lose.
wait_for_accounts() {
  local want="$1" timeout="${2:-60}" ticks=0 got
  while (( ticks < timeout * 10 )); do
    # grep -c always prints a count and exits 1 on zero matches — an `|| echo 0`
    # here would append a second line and break the arithmetic below.
    got=$(log_lines | grep -cE -- "$ACCOUNT_DONE_PATTERN" 2>/dev/null)
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

# ── Output queries ─────────────────────────────────────────────────────────────

output_lines() {
  [[ -s "$OUTPUT_FILE" ]] || return 0
  cat "$OUTPUT_FILE"
}

# Number of records matching a jq select expression.
count_records() {
  output_lines | jq -c "select($1)" 2>/dev/null | grep -c . || true
}

records_for_account() {
  count_records ".record_type == \"region\" and .account_id == \"$1\""
}

# The single region record for account/region, or empty if absent.
record_for() {
  output_lines | jq -c --arg a "$1" --arg r "$2" \
    'select(.record_type == "region" and .account_id == $a and .region == $r)' 2>/dev/null || true
}

# The account-level record for an account, or empty if it was scanned normally.
account_record() {
  output_lines | jq -c --arg a "$1" \
    'select(.record_type == "account" and .account_id == $a)' 2>/dev/null || true
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

# assert_at_least MINIMUM ACTUAL MESSAGE
assert_at_least() {
  local minimum="$1" actual="$2" msg="$3"
  if [[ "${actual:-0}" -ge "$minimum" ]]; then
    _pass "$msg"
  else
    _fail "$msg" "expected at least $minimum, got ${actual:-0}"
  fi
}

# assert_at_most CEILING ACTUAL MESSAGE
assert_at_most() {
  local ceiling="$1" actual="$2" msg="$3"
  if [[ "${actual:-0}" -le "$ceiling" ]]; then
    _pass "$msg"
  else
    _fail "$msg" "expected at most $ceiling, got ${actual:-0}"
  fi
}

# What the operator was told, on either stream. That they were told is the
# contract every implementation shares; which stream carried it is asserted
# separately, by the case that owns that convention.
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
