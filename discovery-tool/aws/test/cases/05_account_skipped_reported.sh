# DT-11095 — "The output file shared by the user should indicate accounts that
# were skipped/failed (+why)."
#
# The customer's run returned data for ~400 of 900+ accounts. The missing ones
# left no trace in the JSON at all: the scan logged to the console and moved on,
# so the file we were sent could not tell us which accounts were never scanned,
# let alone why. Console output is not part of what gets shared.
#
# 111111111111 cannot be assumed; 222222222222 can be assumed but cannot list
# regions; 000000000000 and 333333333333 are healthy.

setup_sandbox

scenario <<'JSON'
{ "caller_account": "000000000000",
  "accounts": ["000000000000", "111111111111", "222222222222", "333333333333"],
  "regions":  ["us-east-1"],
  "volumes": 2, "instances": 1, "snapshots": 1,
  "deny_assume": ["111111111111"],
  "deny": { "222222222222/us-east-1": ["DescribeRegions"] } }
JSON

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "exits 0 despite unreachable accounts"
assert_valid_jsonl "output is valid JSONL"

# Both unreachable accounts must appear in the file, not only in the console log.
assert_not_empty "$(account_record 111111111111)" "the un-assumable account appears in the output"
assert_not_empty "$(account_record 222222222222)" "the account that cannot list regions appears in the output"

assert_equals "skipped" "$(account_record 111111111111 | jq -r '.status')" \
  "an un-assumable account is status=skipped"
assert_equals "failed"  "$(account_record 222222222222 | jq -r '.status')" \
  "an account that cannot list regions is status=failed"

# The reason must be actionable — it has to name what went wrong.
assert_not_empty "$(account_record 111111111111 | jq -r '.reason | select(test("assume role"))')" \
  "the skipped account explains that the role could not be assumed"
assert_not_empty "$(account_record 111111111111 | jq -r '.reason | select(test("AccessDenied"))')" \
  "the skip reason carries the AWS error code"
assert_not_empty "$(account_record 222222222222 | jq -r '.reason | select(test("region"))')" \
  "the failed account explains that regions could not be listed"

# Healthy accounts are unaffected and carry no account-level record.
assert_equals 1 "$(records_for_account 000000000000)" "the management account still produced its region record"
assert_equals 1 "$(records_for_account 333333333333)" "the healthy child account still produced its region record"
assert_empty "$(account_record 333333333333)"         "a healthy account has no account-level record"

# Neither unreachable account may be counted as scanned.
summary=$(summary_record)
assert_equals 4 "$(echo "$summary" | jq -r '.accounts_total')"   "summary counts all 4 accounts"
assert_equals 2 "$(echo "$summary" | jq -r '.accounts_scanned')" "summary counts only the 2 that returned data"
assert_equals 1 "$(echo "$summary" | jq -r '.accounts_skipped')" "summary counts the un-assumable account"
assert_equals 1 "$(echo "$summary" | jq -r '.accounts_failed')"  "summary counts the account that could not list regions"
