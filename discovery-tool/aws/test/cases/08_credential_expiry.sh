# DT-11095 — credentials expiring part-way through a long scan.
#
# Every implementation requests a 1-hour assumed-role session and nothing
# renews it. A 900-account org can take longer than that, after which the
# remaining calls fail with ExpiredToken. This is the most likely explanation
# for the customer's "~400 accounts, very little overlap between runs" pattern:
# whichever accounts happen to be scanned late come back with nothing.
#
# None of the three can prevent the expiry here. What all three must do is never
# report an expired region as an empty one. The endpoint trips after 12 data
# calls and stays tripped, so an SDK that transparently refreshes its
# credentials gains nothing — the failure is not recoverable by retrying.

setup_sandbox

scenario <<'JSON'
{ "caller_account": "000000000000",
  "accounts": ["000000000000", "111111111111", "222222222222",
               "333333333333", "444444444444", "555555555555"],
  "regions":  ["us-east-1", "eu-west-1"],
  "volumes": 3, "instances": 1, "snapshots": 1,
  "expire_after": 12 }
JSON

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_valid_jsonl "output is valid JSONL"

# Every account x region is still represented — nothing vanishes.
assert_equals 12 "$(count_records '.record_type == "region"')" \
  "all 12 account x region pairs are represented"

# Expiry must surface as a degraded status, never as a clean empty region.
degraded=$(count_records '.record_type == "region" and .status != "ok"')
assert_at_least 1 "$degraded" "regions hit by the expiry are marked partial or failed"

# The reason has to name the expiry, or the operator cannot tell this from a
# permissions problem — the fix is completely different.
assert_not_empty "$(output_lines | jq -r 'select(.record_type == "region") | .errors[]? | select(test("ExpiredToken"))' | head -1)" \
  "the error names ExpiredToken"

# A region reported ok must genuinely hold its data.
assert_equals 0 "$(count_records '.record_type == "region" and .status == "ok" and (.volumes | length) == 0')" \
  "no region claims status=ok while holding no data"

# The summary has to reflect the damage, not report a clean run.
summary=$(summary_record)
degraded_total=$(echo "$summary" | jq -r '(.regions_partial // 0) + (.regions_failed // 0)')
assert_at_least 1 "$degraded_total" "the summary counts the degraded regions"
assert_equals "$degraded" "$degraded_total" "the summary's degraded count matches the file"
