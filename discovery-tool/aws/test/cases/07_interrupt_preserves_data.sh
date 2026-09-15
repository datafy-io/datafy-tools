# DT-11095 — an interrupted run must not throw away what it already collected.
#
# The customer's *first* run timed out. A scan of a large org can easily be
# Ctrl+C'd or killed by a session limit, and when that happens the accounts that
# already finished are the most valuable thing on disk.
#
# Four healthy accounts finish immediately; 999999999999 blocks in every data
# call long enough that the run is unambiguously still in flight when the
# interrupt arrives.

setup_sandbox

scenario <<'JSON'
{ "caller_account": "000000000000",
  "accounts": ["000000000000", "111111111111", "222222222222",
               "333333333333", "999999999999"],
  "regions":  ["us-east-1", "eu-west-1"],
  "volumes": 5, "instances": 2, "snapshots": 2,
  "delay_seconds": 5, "delay_accounts": ["999999999999"] }
JSON

run_discovery_bg

# Wait until the four fast accounts have reported done, so there is definitely
# completed work to lose.
if wait_for_accounts 4 60; then
  _pass "four accounts completed before the interrupt"
else
  _fail "four accounts completed before the interrupt" \
        "timed out waiting for four accounts to finish"
fi

# SIGTERM, not SIGINT — see interrupt_discovery in the harness. Both reach the
# same handler; TERM is what a timeout or a supervisor sends, which is the case
# that actually bit the customer.
interrupt_discovery TERM

# How quickly the interrupt takes effect differs legitimately, so the watchdog
# is generous: bash kills the process tree and Go cancels the request context,
# but Python's ThreadPoolExecutor cannot cancel a future that is already
# running, so it drains its outstanding calls first. What every implementation
# must do — write out what it has, mark the run interrupted, exit 143 — is what
# is asserted below. How long it takes to get there is not part of the contract.
wait_for_discovery 120

assert_equals "$(impl_interrupt_status)" "$DISCOVERY_STATUS" \
  "a terminated run exits 143 (128 + SIGTERM)"
assert_log_has "Interrupted" "the interrupt is reported to the operator"
assert_valid_jsonl "the partial output is still valid JSONL"

# The whole point: completed accounts must survive.
assert_at_least 8 "$(count_records '.record_type == "region"')" \
  "the regions of the four completed accounts were kept"

# ...and the file must say it is incomplete, or we will read it as full coverage.
summary=$(summary_record)
assert_not_empty "$summary" "an interrupted run still writes a summary"
assert_equals "true" "$(echo "$summary" | jq -r '.interrupted // "<missing>"')" \
  "the summary marks the run as interrupted"
assert_equals "summary" "$(output_lines | tail -1 | jq -r '.record_type // ""')" \
  "the summary is still the final line"

# Every account must still be accounted for. An account that never finished is
# only useful if it is named — otherwise the gap is invisible in the file.
seen=$(output_lines | jq -r 'select(.record_type == "region" or .record_type == "account")
                             | .account_id' | sort -u | grep -c . || true)
assert_equals 5 "$seen" "every account in the org appears in the interrupted file"
