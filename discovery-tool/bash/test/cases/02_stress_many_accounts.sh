# DT-11095 — scale test.
#
# The customer's org has 900+ accounts. This exercises the account/region
# throttling and the concurrent appends to the shared output file: with many
# writers appending multi-hundred-KB records under flock, a torn or interleaved
# write shows up as invalid JSONL or a lost record.
#
# 12 accounts x 4 regions = 48 region scans, each ~180KB of payload.

setup_sandbox

ACCOUNTS="000000000000"
for i in 1 2 3 4 5 6 7 8 9 10 11; do
  ACCOUNTS="${ACCOUNTS},$(printf '%012d' "$(( i * 100000000 ))")"
done

export MOCK_CALLER_ACCOUNT="000000000000"
export MOCK_ACCOUNTS="$ACCOUNTS"
export MOCK_REGIONS="us-east-1,us-west-2,eu-west-1,ap-southeast-1"
export MOCK_VOLUMES=300
export MOCK_INSTANCES=100
export MOCK_SNAPSHOTS=150

run_discovery

expected_accounts=$(echo "$ACCOUNTS" | tr ',' '\n' | grep -c .)
expected_records=$(( expected_accounts * 4 ))

assert_stderr_lacks "Argument list too long" "no argument-list overflow at scale"
assert_equals 0 "$DISCOVERY_STATUS" "discovery.sh exits 0"
assert_valid_jsonl "concurrent appends produced valid JSONL"

# Every account x region pair must appear exactly once — no losses, no duplicates.
actual_records=$(output_lines | jq -c 'select(.region != null)' | grep -c . || true)
assert_equals "$expected_records" "$actual_records" "every account x region produced exactly one record"

distinct_pairs=$(output_lines \
  | jq -r 'select(.region != null) | "\(.account_id)/\(.region)"' \
  | sort -u | grep -c . || true)
assert_equals "$expected_records" "$distinct_pairs" "no duplicate account/region records"

assert_equals $(( expected_records * 300 )) "$(total_len volumes)"   "no volumes lost"
assert_equals $(( expected_records * 100 )) "$(total_len instances)" "no instances lost"
assert_equals $(( expected_records * 150 )) "$(total_len snapshots)" "no snapshots lost"
