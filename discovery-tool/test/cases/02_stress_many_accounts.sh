# DT-11095 — scale across accounts.
#
# The customer's org has 900+ accounts. This exercises the account/region
# throttling and the concurrent writes to the shared output file: with many
# writers emitting multi-hundred-KB records, a torn or interleaved write shows
# up as invalid JSONL or as a lost record. Each implementation solves this
# differently — bash stages a file per account and concatenates, Python holds a
# single writer, Go serialises encoding behind a mutex — so it is worth
# asserting on all three.
#
# 12 accounts x 4 regions = 48 region scans, each ~180KB of payload.

setup_sandbox

scenario <<'JSON'
{ "caller_account": "000000000000",
  "accounts": ["000000000000", "100000000000", "200000000000", "300000000000",
               "400000000000", "500000000000", "600000000000", "700000000000",
               "800000000000", "900000000000", "110000000000", "120000000000"],
  "regions":  ["us-east-1", "us-west-2", "eu-west-1", "ap-southeast-1"],
  "volumes": 300, "instances": 100, "snapshots": 150, "ami_count": 20 }
JSON

run_discovery

expected_records=48   # 12 accounts x 4 regions

assert_log_lacks "Argument list too long" "no argument-list overflow at scale"
assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_valid_jsonl "concurrent writes produced valid JSONL"

# Every account x region pair must appear exactly once — no losses, no duplicates.
assert_equals "$expected_records" "$(count_records '.record_type == "region"')" \
  "every account x region produced a record"

distinct_pairs=$(output_lines \
  | jq -r 'select(.record_type == "region") | "\(.account_id)/\(.region)"' \
  | sort -u | grep -c . || true)
assert_equals "$expected_records" "$distinct_pairs" "no duplicate account/region records"

assert_equals 0 "$(count_records '.record_type == "region" and .status != "ok"')" \
  "every region was scanned cleanly"

assert_equals $(( expected_records * 300 )) "$(total_len volumes)"   "no volumes lost"
assert_equals $(( expected_records * 100 )) "$(total_len instances)" "no instances lost"
assert_equals $(( expected_records * 150 )) "$(total_len snapshots)" "no snapshots lost"

summary=$(summary_record)
assert_equals 12 "$(echo "$summary" | jq -r '.accounts_total')"   "summary counts every account"
assert_equals 48 "$(echo "$summary" | jq -r '.regions_scanned')"  "summary counts every region"
