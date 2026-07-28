# DT-11095 — a payload that arrives damaged must not read as an empty region.
#
# This is the same bug class as the original ticket, one layer further down.
# fetch_json only inspects the exit status, so a call that exits 0 with a
# truncated body (a cut connection, a proxy error page, a short read) is treated
# as success. The transform then fails and falls back to "[]" — and if that
# fallback is silent, the region is reported as status=ok holding no volumes.
# Indistinguishable from a genuinely empty region, which is precisely what the
# customer could not tell apart.
#
# us-east-1 returns truncated JSON for DescribeVolumes; eu-west-1 is healthy.

setup_sandbox

export MOCK_CALLER_ACCOUNT="000000000000"
export MOCK_ACCOUNTS="000000000000"
export MOCK_REGIONS="us-east-1,eu-west-1"
export MOCK_VOLUMES=5
export MOCK_INSTANCES=2
export MOCK_SNAPSHOTS=2
export MOCK_CORRUPT_OPS="describe-volumes"
export MOCK_CORRUPT_REGIONS="us-east-1"

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "discovery.sh exits 0"
assert_valid_jsonl "a corrupt upstream payload still yields valid JSONL"

corrupt=$(record_for 000000000000 us-east-1)
healthy=$(record_for 000000000000 eu-west-1)

assert_not_empty "$corrupt" "the region with the corrupt payload is present"
assert_not_empty "$healthy" "the healthy region is present"

# The core assertion: damaged data must be visible as damaged.
assert_equals "partial" "$(echo "$corrupt" | jq -r '.status')" \
  "a region whose payload could not be parsed is status=partial"

assert_not_empty "$(echo "$corrupt" | jq -r '.errors[]? | select(test("[Vv]olume"))')" \
  "the error identifies the payload that could not be parsed"

# The rest of the region must still be collected — one bad call is not a reason
# to discard the instances and snapshots that arrived intact.
assert_equals 2 "$(echo "$corrupt" | jq -r '.instances | length')" \
  "instances from the same region are still collected"
assert_equals 2 "$(echo "$corrupt" | jq -r '.snapshots | length')" \
  "snapshots from the same region are still collected"

# And the healthy region is untouched.
assert_equals "ok" "$(echo "$healthy" | jq -r '.status')" "the healthy region is still status=ok"
assert_equals 5    "$(echo "$healthy" | jq -r '.volumes | length')" "the healthy region kept its volumes"
