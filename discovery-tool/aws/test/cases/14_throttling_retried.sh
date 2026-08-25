# A throttled call must be retried, not counted as a loss.
#
# A 900-account scan makes tens of thousands of API calls, and AWS pushes back
# well before that. Every client retries throttling with exponential backoff and
# jitter, but none of the three used to say so: bash inherited the AWS CLI
# default, Python inherited boto3's "legacy" mode, Go inherited the SDK's
# "standard". Three different answers to the same question, and no test that
# would notice. All three now pin standard mode with the same attempt budget.
#
# Throttling is a strong candidate for the customer's "~400 of 900 accounts,
# little overlap between runs" symptom: unlike an expired session, which loses
# whatever is scanned late, throttling loses a scattered subset that differs
# every run.
#
# Two runs here. First: a burst the client should ride out.

setup_sandbox

scenario <<'JSON'
{ "caller_account": "000000000000",
  "accounts": ["000000000000"],
  "regions":  ["us-east-1", "eu-west-1"],
  "volumes": 4, "instances": 2, "snapshots": 2,
  "throttle": { "DescribeVolumes": 2, "DescribeSnapshots": 1 } }
JSON

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_valid_jsonl "output is valid JSONL"

# The endpoint rejected the first two DescribeVolumes attempts and the first
# DescribeSnapshots attempt in each region — 2 x (2 + 1) — so an answer at all
# proves the client came back for another go. Exact rather than a floor: a
# client that retried more times than its budget allows is as much a
# misalignment as one that retried fewer.
assert_equals 6 "$(fake_stat throttled)" \
  "the endpoint rejected exactly the burst it was told to"

assert_equals "ok" "$(record_for 000000000000 us-east-1 | jq -r '.status')" \
  "a region that was throttled and retried is status=ok"
assert_equals "ok" "$(record_for 000000000000 eu-west-1 | jq -r '.status')" \
  "the second region likewise"

assert_equals 0 "$(count_records '.record_type == "region" and (.errors | length) > 0')" \
  "an absorbed burst leaves no error behind"

# The data has to be all there — a retry that silently gave up would show as a
# short array rather than as an error.
assert_equals 8 "$(total_len volumes)"   "both regions' volumes arrived"
assert_equals 4 "$(total_len snapshots)" "both regions' snapshots arrived"

summary=$(summary_record)
assert_equals 2 "$(echo "$summary" | jq -r '.regions_scanned')" "the summary reports a clean run"
assert_equals 0 "$(echo "$summary" | jq -r '.regions_partial')" "no region is reported as partial"

# ── Second run: throttling that never lets up ─────────────────────────────────
# When the budget really is exhausted the call must be reported, not silently
# turned into an empty array — the DT-11095 contract. AWS_MAX_ATTEMPTS is
# lowered so the case does not sit through the full backoff schedule; that it
# is honoured at all is itself the check that the setting is not hard-coded.
export AWS_MAX_ATTEMPTS=3

scenario <<'JSON'
{ "caller_account": "000000000000",
  "accounts": ["000000000000"],
  "regions":  ["us-east-1"],
  "volumes": 4, "instances": 2, "snapshots": 2,
  "throttle_forever": ["DescribeVolumes"] }
JSON
restart_fake

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "exits 0 even when a call is throttled out"
assert_valid_jsonl "output is still valid JSONL"

exhausted=$(record_for 000000000000 us-east-1)
assert_not_empty "$exhausted" "the region is still present"
assert_equals "partial" "$(echo "$exhausted" | jq -r '.status')" \
  "a call that exhausted its retries leaves the region partial, not ok"
assert_equals 0 "$(echo "$exhausted" | jq -r '.volumes | length')" \
  "the throttled call contributes no volumes"
assert_not_empty "$(echo "$exhausted" | jq -r '.errors[]? | select(test("[Vv]olume"))')" \
  "the error names the call that was throttled out"

# Everything else in the region still arrives — one throttled call is not a
# reason to discard the rest.
assert_equals 2 "$(echo "$exhausted" | jq -r '.snapshots | length')" \
  "snapshots from the same region are still collected"

# The client must have spent its budget rather than giving up on the first 503.
# Exactly AWS_MAX_ATTEMPTS attempts for the one throttled call — no more, no
# fewer. This is what catches a client whose "max attempts" counts retries
# rather than attempts, which is a real difference between the AWS SDKs.
assert_equals 3 "$(fake_stat throttled)" \
  "the client made exactly its budget of 3 attempts before giving up"
