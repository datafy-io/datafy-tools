# DT-11095 — a scan that cannot write its results must fail loudly.
#
# The one outcome we cannot accept is a run that appears to succeed while
# producing nothing, which is how this ticket started. An unwritable output path
# has to be caught before the scan spends an hour on API calls, reported with a
# message that names the path, and turned into a non-zero exit status so a
# wrapper script notices.
#
# A raw stack trace satisfies none of that: it tells the operator the tool
# broke, not that their --output path is wrong.

setup_sandbox

scenario <<'JSON'
{ "caller_account": "000000000000",
  "accounts": ["000000000000"],
  "regions":  ["us-east-1"],
  "volumes": 2, "instances": 1, "snapshots": 1 }
JSON

bad_path="$SANDBOX/no/such/dir/out.json"
run_discovery_to "$bad_path"

if [[ "$DISCOVERY_STATUS" -ne 0 ]]; then
  _pass "an unwritable output path fails with a non-zero status ($DISCOVERY_STATUS)"
else
  _fail "an unwritable output path fails with a non-zero status" "exited 0"
fi

assert_log_has "$bad_path" "the error names the path that could not be written"
assert_log_lacks "Traceback (most recent call last)" \
  "the failure is reported as a message, not as an unhandled stack trace"
assert_log_lacks "panic:" \
  "the failure is reported as a message, not as a panic"

# It must fail before doing the work, not after.
assert_at_most 0 "$(fake_stat data_calls)" \
  "no inventory calls were made before the write failure was caught"

# ── The healthy path is unaffected ─────────────────────────────────────────────
run_discovery
assert_equals 0 "$DISCOVERY_STATUS" "a writable run still exits 0"
assert_not_empty "$(record_for 000000000000 us-east-1)" "a writable run still produces its record"
