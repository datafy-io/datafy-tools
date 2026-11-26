# SAAS-252 — an interrupted run with --anonymize-accounts must not leak the IDs
# of the accounts that never finished. Those are named in the file as failed, and
# their IDs are exactly what the customer asked us not to see.

setup_sandbox

export DATAFY_ANONYMIZE_KEY_FILE="$SANDBOX/anonymize.key"
MAPPING="$OUTPUT_FILE.mapping.private"

scenario <<'JSON'
{ "caller_account": "000000000000",
  "accounts": ["000000000000", "111111111111", "222222222222",
               "333333333333", "999999999999"],
  "regions":  ["us-east-1", "eu-west-1"],
  "volumes": 2, "instances": 1, "snapshots": 1,
  "delay_seconds": 5, "delay_accounts": ["999999999999"] }
JSON

run_discovery_bg --anonymize-accounts --anonymize-tags
wait_for_accounts 4 60 || _fail "four accounts completed before the interrupt"
interrupt_discovery TERM
wait_for_discovery 120

assert_equals "$(impl_interrupt_status)" "$DISCOVERY_STATUS" "a terminated run exits 143"
assert_valid_jsonl "the partial output is still valid JSONL"
assert_equals 0 "$(output_lines | grep -Ecw '[0-9]{12}' || true)" \
  "no 12-digit account ID appears in the interrupted output"
assert_equals 5 "$(output_lines | jq -r 'select(.record_type == "region" or .record_type == "account") | .account_id' | sort -u | grep -c .)" \
  "every account, finished or not, still appears — under its alias"
assert_equals 5 "$(jq '.accounts | length' "$MAPPING")" "the mapping file covers the accounts that never finished too"
assert_equals '{"tags":true,"accounts":true}' "$(summary_record | jq -c .anonymization)" \
  "the interrupted summary says which options were applied"
