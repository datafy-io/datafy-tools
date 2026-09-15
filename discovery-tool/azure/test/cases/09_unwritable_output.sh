# A scan that cannot write its results is worth failing immediately, not after
# an hour of ARM calls. The message has to name the path: an unhandled OSError
# tells the operator the tool broke, not that their --output argument is wrong.

setup_sandbox

scenario <<'JSON'
{ "subscriptions": ["aaaaaaaa-0000-0000-0000-000000000001"], "disks": 2 }
JSON

run_discovery_to "$SANDBOX/no/such/directory/discovery.json"

assert_equals 1 "$DISCOVERY_STATUS" "an unwritable --output path exits non-zero"
assert_log_has "no/such/directory/discovery.json" "the error names the path that could not be written"
assert_log_has "cannot write output file" "the error says what went wrong in the operator's terms"

# Early, not late: the tenant must not have been scanned before the failure.
assert_equals 0 "$(fake_calls_for 'Microsoft.Compute/disks')" \
  "the scan never started — the check happens before any inventory call"

# A path that is writable must, of course, still work.
restart_fake
run_discovery
assert_equals 0 "$DISCOVERY_STATUS" "a writable --output path still succeeds"
assert_at_least 1 "$(count_records '.record_type == "subscription"')" "and produces records"
