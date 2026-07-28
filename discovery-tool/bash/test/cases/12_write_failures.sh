# DT-11095 — the tool now buffers far more to disk than it used to.
#
# Records are staged in a temp dir per account and concatenated at the end, so
# both the temp location and the output path are on the critical path. A scan
# that cannot write must say so loudly: the one outcome we cannot accept is a
# run that appears to succeed while producing nothing, which is how this ticket
# started.

setup_sandbox

export MOCK_CALLER_ACCOUNT="000000000000"
export MOCK_ACCOUNTS="000000000000"
export MOCK_REGIONS="us-east-1"
export MOCK_VOLUMES=2
export MOCK_INSTANCES=1
export MOCK_SNAPSHOTS=1

# ── An output path that cannot be written ──────────────────────────────────────
status=0
PATH="$SANDBOX/bin:$PATH" \
  bash "$DISCOVERY_SH" --output "$SANDBOX/no/such/dir/out.json" \
  >/dev/null 2>"$STDERR_FILE" || status=$?

if [[ "$status" -ne 0 ]]; then
  _pass "an unwritable output path fails with a non-zero status ($status)"
else
  _fail "an unwritable output path fails with a non-zero status" "exited 0"
fi
assert_stderr_has "output" "the error names the output file as the problem"

# ── A temp directory that cannot be written ────────────────────────────────────
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
assert_stderr_has "temp" "the error names the temp directory as the problem"

# The failure must be diagnosable from the message alone. A bare `mktemp:
# Permission denied` sends the customer to the wrong place.
assert_stderr_has "TMPDIR" "the error tells the operator which variable to change"

# ── The healthy path is unaffected ─────────────────────────────────────────────
run_discovery
assert_equals 0 "$DISCOVERY_STATUS" "a writable run still exits 0"
assert_not_empty "$(record_for 000000000000 us-east-1)" "a writable run still produces its record"
