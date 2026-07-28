# DT-11095 — the run must be self-describing.
#
# The customer sent us a JSON file and we could not tell from it whether the run
# covered the whole org. The last line of the output is now a summary record so
# coverage is answerable from the shared file alone.
#
# Org of 5 accounts x 2 regions:
#   000000000000  healthy, but eu-west-1 denies DescribeVolumes -> 1 ok + 1 partial
#   111111111111  healthy                                       -> 2 ok
#   222222222222  role cannot be assumed                        -> skipped
#   333333333333  role assumed, regions cannot be listed        -> failed
#   444444444444  healthy, but eu-west-1 fully unreachable      -> 1 ok + 1 failed

setup_sandbox

export MOCK_CALLER_ACCOUNT="000000000000"
export MOCK_ACCOUNTS="000000000000,111111111111,222222222222,333333333333,444444444444"
export MOCK_REGIONS="us-east-1,eu-west-1"
export MOCK_VOLUMES=2
export MOCK_INSTANCES=1
export MOCK_SNAPSHOTS=1
export MOCK_DENY_ASSUME="222222222222"
export MOCK_DENY_LIST_REGIONS="333333333333"
export MOCK_DENY_VOLUMES="000000000000/eu-west-1"
export MOCK_DENY_ALL="444444444444/eu-west-1"

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "discovery.sh exits 0"
assert_valid_jsonl "output is valid JSONL"

summary=$(output_lines | jq -c 'select(.record_type == "summary")')
assert_not_empty "$summary" "a summary record was written"

# It must be the last line, so a truncated file is obvious.
last_line=$(output_lines | tail -1 | jq -r '.record_type // ""')
assert_equals "summary" "$last_line" "the summary is the final line of the file"

field() { echo "$summary" | jq -r ".$1 // \"<missing>\""; }

assert_equals 5 "$(field accounts_total)"    "accounts_total counts every account considered"
assert_equals 3 "$(field accounts_scanned)"  "accounts_scanned counts the accounts that returned data"
assert_equals 1 "$(field accounts_skipped)"  "accounts_skipped counts the un-assumable account"
assert_equals 1 "$(field accounts_failed)"   "accounts_failed counts the account that could not list regions"

assert_equals 4 "$(field regions_scanned)"   "regions_scanned counts fully successful regions"
assert_equals 1 "$(field regions_partial)"   "regions_partial counts regions with some denied calls"
assert_equals 1 "$(field regions_failed)"    "regions_failed counts fully unreachable regions"

assert_not_empty "$(field tool_version)"     "the summary records the tool version"
assert_not_empty "$(field scanned_at)"       "the summary records when the run finished"

# Region records in the file must reconcile with the summary above.
emitted_regions=$(output_lines | jq -c 'select(.record_type == "region")' | grep -c . || true)
assert_equals 6 "$emitted_regions" "one region record per reachable account x region"
