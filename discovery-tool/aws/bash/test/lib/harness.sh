#!/usr/bin/env bash
# Harness for the bash-internal test cases.
#
# Sourced by run_tests.sh before each case file. Provides sandbox setup, a
# `run_discovery` wrapper that puts the mock AWS CLI on PATH, and assertions.
# Cases report failure by incrementing FAILURES.
#
# This suite only covers what is a property of discovery.sh itself — its argv to
# the AWS CLI, its $TMPDIR staging. Everything about what the tool *produces* is
# tested for all three implementations by test/run_tests.sh in the repository
# root, which drives the real AWS CLI, real boto3 and the real Go SDK against a
# shared fake endpoint.

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
  : > "$STDERR_FILE"
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

# ── Output queries ─────────────────────────────────────────────────────────────

output_lines() {
  [[ -s "$OUTPUT_FILE" ]] || return 0
  cat "$OUTPUT_FILE"
}

# The single record for account/region, or empty if absent.
record_for() {
  output_lines | jq -c --arg a "$1" --arg r "$2" \
    'select(.account_id == $a and .region == $r)' 2>/dev/null || true
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

# Fails when the pattern is NOT found in stderr.
assert_stderr_has() {
  local pattern="$1" msg="$2"
  if grep -qF "$pattern" "$STDERR_FILE" 2>/dev/null; then
    _pass "$msg"
  else
    _fail "$msg" "stderr did not contain: $pattern"
  fi
}
