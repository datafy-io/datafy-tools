# Smoke test — proves the mock AWS CLI is wired up and a normal small org
# produces the documented one-record-per-account-per-region output.

setup_sandbox

export MOCK_CALLER_ACCOUNT="000000000000"
export MOCK_ACCOUNTS="000000000000,111111111111"
export MOCK_REGIONS="us-east-1,eu-west-1"
export MOCK_VOLUMES=3
export MOCK_INSTANCES=2
export MOCK_SNAPSHOTS=1

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "discovery.sh exits 0"
assert_valid_jsonl "output is valid JSONL"

assert_equals 2 "$(records_for_account 000000000000)" "management account produced 2 region records"
assert_equals 2 "$(records_for_account 111111111111)" "child account produced 2 region records"

assert_not_empty "$(record_for 000000000000 us-east-1)" "record exists for 000000000000/us-east-1"
assert_not_empty "$(record_for 111111111111 eu-west-1)" "record exists for 111111111111/eu-west-1"

# 2 accounts x 2 regions x the per-region counts above.
assert_equals 12 "$(total_len volumes)"   "all 12 volumes present"
assert_equals 8  "$(total_len instances)" "all 8 instances present"
assert_equals 4  "$(total_len snapshots)" "all 4 snapshots present"
assert_equals 8  "$(total_len amis)"      "one AMI resolved per instance"

# A healthy run is tagged as such on every record.
all_ok=$(output_lines | jq -c 'select(.record_type == "region" and .status != "ok")' | grep -c . || true)
assert_equals 0 "$all_ok" "every region record is status=ok"

assert_equals 0 "$(output_lines | jq -c 'select(.record_type == "account")' | grep -c . || true)" \
  "a healthy org produces no account-level records"
assert_equals 1 "$(output_lines | jq -c 'select(.record_type == "summary")' | grep -c . || true)" \
  "exactly one summary record"
