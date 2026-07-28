# Smoke test — proves the implementation is wired up to the fake endpoint and
# that a normal small org produces the documented one-record-per-account-per-
# region output.

setup_sandbox

scenario <<'JSON'
{ "caller_account": "000000000000",
  "accounts": ["000000000000", "111111111111"],
  "regions":  ["us-east-1", "eu-west-1"],
  "volumes": 3, "instances": 2, "snapshots": 1, "ami_count": 3 }
JSON

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_valid_jsonl "output is valid JSONL"

assert_equals 2 "$(records_for_account 000000000000)" "management account produced 2 region records"
assert_equals 2 "$(records_for_account 111111111111)" "child account produced 2 region records"

assert_not_empty "$(record_for 000000000000 us-east-1)" "record exists for 000000000000/us-east-1"
assert_not_empty "$(record_for 111111111111 eu-west-1)" "record exists for 111111111111/eu-west-1"

# 2 accounts x 2 regions x the per-region counts above.
assert_equals 12 "$(total_len volumes)"   "all 12 volumes present"
assert_equals 8  "$(total_len instances)" "all 8 instances present"
assert_equals 4  "$(total_len snapshots)" "all 4 snapshots present"
# Two instances per region cycling through 3 AMIs reference 2 distinct images.
assert_equals 8  "$(total_len amis)"      "every referenced AMI resolved"

# A healthy run is tagged as such on every record.
assert_equals 0 "$(count_records '.record_type == "region" and .status != "ok"')" \
  "every region record is status=ok"

assert_equals 0 "$(count_records '.record_type == "account"')" \
  "a healthy org produces no account-level records"
assert_equals 1 "$(count_records '.record_type == "summary"')" \
  "exactly one summary record"

# The record shape the README documents, checked once here so the other cases
# can take it as given.
missing=$(output_lines | jq -r 'select(.record_type == "region")
  | [ "account_id","region","status","scanned_at","errors","volumes","instances",
      "amis","snapshots","dlm_policies","backup_plans" ]
  - (. | keys) | .[]' | sort -u | tr '\n' ' ')
assert_empty "$missing" "region records carry every documented field"
