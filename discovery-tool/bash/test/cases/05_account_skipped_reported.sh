# DT-11095 — "The output file shared by the user should indicate accounts that
# were skipped/failed (+why)."
#
# Abbvie's run returned data for ~400 of 900+ accounts. The missing ones left no
# trace in the JSON at all: scan_account logged to stderr and returned, so the
# file the customer sent us could not tell us which accounts were never scanned,
# let alone why. stderr is not part of what gets shared.
#
# 111111111111 cannot be assumed; 222222222222 can be assumed but cannot list
# regions; 333333333333 is healthy.

setup_sandbox

export MOCK_CALLER_ACCOUNT="000000000000"
export MOCK_ACCOUNTS="000000000000,111111111111,222222222222,333333333333"
export MOCK_REGIONS="us-east-1"
export MOCK_VOLUMES=2
export MOCK_INSTANCES=1
export MOCK_SNAPSHOTS=1
export MOCK_DENY_ASSUME="111111111111"
export MOCK_DENY_LIST_REGIONS="222222222222"

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "discovery.sh exits 0 despite unreachable accounts"
assert_valid_jsonl "output is valid JSONL"

account_record() {
  output_lines | jq -c --arg a "$1" 'select(.record_type == "account" and .account_id == $a)'
}

# Both unreachable accounts must appear in the file, not only on stderr.
assert_not_empty "$(account_record 111111111111)" "un-assumable account appears in the output"
assert_not_empty "$(account_record 222222222222)" "account that cannot list regions appears in the output"

assert_equals "skipped" "$(account_record 111111111111 | jq -r '.status')" \
  "un-assumable account is status=skipped"
assert_equals "failed"  "$(account_record 222222222222 | jq -r '.status')" \
  "account that cannot list regions is status=failed"

# The reason must be actionable — it has to name what went wrong.
assert_not_empty "$(account_record 111111111111 | jq -r '.reason | select(test("assume role"))')" \
  "skipped account explains that the role could not be assumed"
assert_not_empty "$(account_record 222222222222 | jq -r '.reason | select(test("region"))')" \
  "failed account explains that regions could not be listed"

# Healthy accounts are unaffected and carry no account-level record.
assert_equals 1 "$(records_for_account 333333333333)" "healthy account still produced its region record"
assert_equals "" "$(account_record 333333333333)"     "healthy account has no account-level record"
