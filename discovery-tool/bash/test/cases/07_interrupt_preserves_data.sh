# DT-11095 — an interrupted run must not throw away what it already collected.
#
# Abbvie's *first* run timed out. A scan of a large org can easily be Ctrl+C'd
# or killed by a session limit, and when that happens the accounts that already
# finished are the most valuable thing on disk.
#
# Four healthy accounts finish immediately; 999999999999 blocks in
# DescribeVolumes long enough that the run is unambiguously still in flight when
# the interrupt arrives.

setup_sandbox

export MOCK_CALLER_ACCOUNT="000000000000"
export MOCK_ACCOUNTS="000000000000,111111111111,222222222222,333333333333,999999999999"
export MOCK_REGIONS="us-east-1,eu-west-1"
export MOCK_VOLUMES=5
export MOCK_INSTANCES=2
export MOCK_SNAPSHOTS=2
export MOCK_DELAY_SECONDS=20
export MOCK_DELAY_ACCOUNTS="999999999999"

run_discovery_bg

# Wait until the four fast accounts have reported done, so there is definitely
# completed work to lose.
if wait_for_stderr '\[done\]' 4 60; then
  _pass "four accounts completed before the interrupt"
else
  _fail "four accounts completed before the interrupt" "timed out waiting for [done] x4"
fi

# SIGTERM, not SIGINT — see interrupt_discovery in the harness. Both reach the
# same handler; TERM is what a timeout or a supervisor sends, which is the case
# that actually bit the customer.
interrupt_discovery TERM
wait_for_discovery 60

assert_equals 143 "$DISCOVERY_STATUS" "a terminated run exits 143 (128 + SIGTERM)"
assert_stderr_has "Interrupted" "the interrupt is reported to the operator"
assert_valid_jsonl "the partial output is still valid JSONL"

# The whole point: completed accounts must survive.
kept=$(output_lines | jq -c 'select(.record_type == "region")' | grep -c . || true)
if [[ "${kept:-0}" -ge 8 ]]; then
  _pass "regions from completed accounts were kept ($kept records)"
else
  _fail "regions from completed accounts were kept" "expected >= 8 region records, got ${kept:-0}"
fi

# ...and the file must say it is incomplete, or we will read it as full coverage.
summary=$(output_lines | jq -c 'select(.record_type == "summary")')
assert_not_empty "$summary" "an interrupted run still writes a summary"
assert_equals "true" "$(echo "$summary" | jq -r '.interrupted // "<missing>"')" \
  "the summary marks the run as interrupted"

last_line=$(output_lines | tail -1 | jq -r '.record_type // ""')
assert_equals "summary" "$last_line" "the summary is still the final line"
