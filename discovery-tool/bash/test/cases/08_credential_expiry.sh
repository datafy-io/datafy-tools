# DT-11095 — credentials expiring part-way through a long scan.
#
# assume_role_env requests a 1-hour session and nothing renews it. A 900-account
# org can take longer than that, after which every remaining call fails with
# ExpiredToken. This is the most likely explanation for the customer's "~400
# accounts, very little overlap between runs" pattern: whichever accounts happen
# to be scanned late come back with nothing.
#
# The tool cannot prevent expiry here, but it must never report an expired
# region as an empty one. MOCK_EXPIRE_AFTER trips after 12 inventory calls,
# part-way through the 6 accounts x 2 regions this case scans.

setup_sandbox

export MOCK_CALLER_ACCOUNT="000000000000"
export MOCK_ACCOUNTS="000000000000,111111111111,222222222222,333333333333,444444444444,555555555555"
export MOCK_REGIONS="us-east-1,eu-west-1"
export MOCK_VOLUMES=3
export MOCK_INSTANCES=1
export MOCK_SNAPSHOTS=1
export MOCK_EXPIRE_AFTER=12

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "discovery.sh exits 0"
assert_valid_jsonl "output is valid JSONL"

# Every account x region is still represented — nothing vanishes.
regions=$(output_lines | jq -c 'select(.record_type == "region")' | grep -c . || true)
assert_equals 12 "$regions" "all 12 account x region pairs are represented"

# Expiry must surface as a degraded status, never as a clean empty region.
degraded=$(output_lines | jq -c 'select(.record_type == "region" and .status != "ok")' | grep -c . || true)
if [[ "${degraded:-0}" -ge 1 ]]; then
  _pass "regions hit by expiry are marked partial or failed ($degraded)"
else
  _fail "regions hit by expiry are marked partial or failed" "every region claimed status=ok"
fi

# The reason has to name the expiry, or the operator cannot tell this from a
# permissions problem — the fix is completely different.
assert_not_empty "$(output_lines | jq -r 'select(.record_type == "region") | .errors[]? | select(test("ExpiredToken"))' | head -1)" \
  "the error names ExpiredToken"

# A region reported ok must genuinely hold its data.
bad_ok=$(output_lines | jq -c 'select(.record_type == "region" and .status == "ok" and (.volumes | length) == 0)' | grep -c . || true)
assert_equals 0 "$bad_ok" "no region claims status=ok while holding no data"

# The summary has to reflect the damage, not report a clean run.
summary=$(output_lines | jq -c 'select(.record_type == "summary")')
degraded_total=$(echo "$summary" | jq -r '(.regions_partial // 0) + (.regions_failed // 0)')
if [[ "${degraded_total:-0}" -ge 1 ]]; then
  _pass "the summary counts the degraded regions"
else
  _fail "the summary counts the degraded regions" "summary reported a clean run: $summary"
fi
