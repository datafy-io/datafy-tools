# An unwritable temp directory must fail loudly, and say which one.
#
# Only the bash implementation stages its records through $TMPDIR: it writes a
# file per region, then per account, and concatenates them at the end, so the
# temp location is on the critical path in a way it is not for Python or Go.
# (The shared output-path check lives in test/cases/12_unwritable_output.sh and
# covers all three.)
#
# A bare "mktemp: Permission denied" sends the operator to the wrong place, so
# the message has to name both the directory and the variable that changes it.

setup_sandbox

export MOCK_CALLER_ACCOUNT="000000000000"
export MOCK_ACCOUNTS="000000000000"
export MOCK_REGIONS="us-east-1"
export MOCK_VOLUMES=2
export MOCK_INSTANCES=1
export MOCK_SNAPSHOTS=1

readonly_tmp="$SANDBOX/readonly-tmp"
mkdir -p "$readonly_tmp"
chmod 500 "$readonly_tmp"

status=0
TMPDIR="$readonly_tmp" PATH="$SANDBOX/bin:$PATH" \
  bash "$DISCOVERY_SH" --output "$OUTPUT_FILE" \
  >/dev/null 2>"$STDERR_FILE" || status=$?

chmod 700 "$readonly_tmp"

if [[ "$status" -ne 0 ]]; then
  _pass "an unwritable temp directory fails with a non-zero status ($status)"
else
  _fail "an unwritable temp directory fails with a non-zero status" "exited 0"
fi

assert_stderr_has "temp"   "the error names the temp directory as the problem"
assert_stderr_has "TMPDIR" "the error tells the operator which variable to change"

# ── The healthy path is unaffected ─────────────────────────────────────────────
run_discovery
assert_equals 0 "$DISCOVERY_STATUS" "a run with a writable temp directory still exits 0"
assert_not_empty "$(record_for 000000000000 us-east-1)" "it still produces its record"
