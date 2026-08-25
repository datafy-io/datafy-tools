# DT-11095 — the run must be self-describing.
#
# The customer sent us a JSON file and we could not tell from it whether the run
# covered the whole org. The last line of the output is now a summary record, so
# coverage is answerable from the shared file alone.
#
# Org of 5 accounts x 2 regions:
#   000000000000  healthy, but eu-west-1 denies DescribeVolumes -> 1 ok + 1 partial
#   111111111111  healthy                                       -> 2 ok
#   222222222222  role cannot be assumed                        -> skipped
#   333333333333  role assumed, regions cannot be listed        -> failed
#   444444444444  healthy, but eu-west-1 fully unreachable      -> 1 ok + 1 failed

setup_sandbox

scenario <<'JSON'
{ "caller_account": "000000000000",
  "accounts": ["000000000000", "111111111111", "222222222222",
               "333333333333", "444444444444"],
  "regions":  ["us-east-1", "eu-west-1"],
  "volumes": 2, "instances": 1, "snapshots": 1,
  "deny_assume": ["222222222222"],
  "deny": {
    "333333333333/us-east-1": ["DescribeRegions"],
    "000000000000/eu-west-1": ["DescribeVolumes"],
    "444444444444/eu-west-1": ["*"]
  } }
JSON

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_valid_jsonl "output is valid JSONL"

summary=$(summary_record)
assert_not_empty "$summary" "a summary record was written"

# It must be the last line, so a truncated file is obvious.
assert_equals "summary" "$(output_lines | tail -1 | jq -r '.record_type // ""')" \
  "the summary is the final line of the file"
assert_equals 1 "$(count_records '.record_type == "summary"')" "there is exactly one summary"

field() { echo "$summary" | jq -r ".$1 // \"<missing>\""; }

assert_equals 5 "$(field accounts_total)"    "accounts_total counts every account considered"
assert_equals 3 "$(field accounts_scanned)"  "accounts_scanned counts the accounts that returned data"
assert_equals 1 "$(field accounts_skipped)"  "accounts_skipped counts the un-assumable account"
assert_equals 1 "$(field accounts_failed)"   "accounts_failed counts the account that could not list regions"

assert_equals 4 "$(field regions_scanned)"   "regions_scanned counts fully successful regions"
assert_equals 1 "$(field regions_partial)"   "regions_partial counts regions with some denied calls"
assert_equals 1 "$(field regions_failed)"    "regions_failed counts fully unreachable regions"

# Read without a `// "<missing>"` fallback: jq's alternative operator treats
# `false` as absent, so that idiom cannot distinguish interrupted:false from a
# summary that omits the field entirely.
assert_equals "false" "$(echo "$summary" | jq -r '.interrupted')" \
  "a completed run is not marked interrupted"
assert_not_empty "$(field tool_version)"     "the summary records the tool version"
assert_not_empty "$(field scanned_at)"       "the summary records when the run finished"

# The region records in the file must reconcile with the summary above.
assert_equals 6 "$(count_records '.record_type == "region"')" \
  "one region record per reachable account x region"
assert_equals "$(field regions_scanned)" "$(count_records '.record_type == "region" and .status == "ok"')" \
  "regions_scanned matches the ok records in the file"
assert_equals "$(field regions_partial)" "$(count_records '.record_type == "region" and .status == "partial"')" \
  "regions_partial matches the partial records in the file"
assert_equals "$(field regions_failed)"  "$(count_records '.record_type == "region" and .status == "failed"')" \
  "regions_failed matches the failed records in the file"

# Timestamps are RFC3339 UTC with a Z suffix in every implementation — "+00:00"
# is equally valid RFC3339 but not interchangeable to a consumer comparing
# strings, and the README promises Z.
assert_equals 0 "$(output_lines | jq -r '[.. | strings | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T.*\\+00:00$"))] | length' | awk '{s+=$1} END {print s+0}')" \
  "every timestamp is Z-suffixed RFC3339"
