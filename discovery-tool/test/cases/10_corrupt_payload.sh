# DT-11095 — a payload that arrives damaged must not read as an empty region.
#
# This is the same bug class as the original ticket, one layer further down. A
# call that returns a 200 with a truncated body — a cut connection, a proxy
# error page, a short read — is a success as far as the transport is concerned.
# If the implementation then falls back to an empty array without recording
# anything, the region is reported as status=ok holding no volumes:
# indistinguishable from a genuinely empty region, which is precisely what the
# customer could not tell apart.
#
# us-east-1 returns truncated XML for DescribeVolumes; eu-west-1 is healthy.

setup_sandbox

scenario <<'JSON'
{ "caller_account": "000000000000",
  "accounts": ["000000000000"],
  "regions":  ["us-east-1", "eu-west-1"],
  "volumes": 5, "instances": 2, "snapshots": 2,
  "corrupt": { "us-east-1": ["DescribeVolumes"] } }
JSON

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
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

assert_equals 0 "$(echo "$corrupt" | jq -r '.volumes | length')" \
  "the unparseable payload contributes no volumes"

# The rest of the region must still be collected — one bad call is not a reason
# to discard the instances and snapshots that arrived intact.
assert_equals 2 "$(echo "$corrupt" | jq -r '.instances | length')" \
  "instances from the same region are still collected"
assert_equals 2 "$(echo "$corrupt" | jq -r '.snapshots | length')" \
  "snapshots from the same region are still collected"

# And the healthy region is untouched.
assert_equals "ok" "$(echo "$healthy" | jq -r '.status')" "the healthy region is still status=ok"
assert_equals 5    "$(echo "$healthy" | jq -r '.volumes | length')" "the healthy region kept its volumes"

# The summary must not describe this as a clean run.
assert_equals 1 "$(summary_record | jq -r '.regions_partial')" \
  "the summary counts the damaged region as partial"
