# The question this case exists to answer: can a half-granted tenant produce a
# file that looks complete?
#
# In AWS it cannot, because organizations:ListAccounts names every account in
# the org whether or not it can be assumed into — the denominator is free. Azure
# has no such call. GET /subscriptions returns only the subscriptions the
# identity can already see; one that no role assignment reaches is not listed as
# denied, it is simply absent. Trusting it as the denominator means a tenant of
# six subscriptions with Reader on two reports "2 total, 2 scanned, 0 failed" —
# byte-for-byte what a healthy two-subscription tenant reports.
#
# The management group hierarchy is the denominator, because it lists
# subscriptions by membership rather than by access.

setup_sandbox

scenario <<'JSON'
{ "tenant_id": "11111111-1111-1111-1111-111111111111",
  "subscriptions": [
    "aaaaaaaa-0000-0000-0000-000000000001",
    "bbbbbbbb-0000-0000-0000-000000000002",
    "cccccccc-0000-0000-0000-000000000003",
    "dddddddd-0000-0000-0000-000000000004"
  ],
  "invisible_subscriptions": [
    "cccccccc-0000-0000-0000-000000000003",
    "dddddddd-0000-0000-0000-000000000004"
  ],
  "disks": 2, "vms": 1 }
JSON

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_valid_jsonl "output is valid JSONL"

seen=cccccccc-0000-0000-0000-000000000003
assert_equals 4 "$(count_records '.record_type == "subscription"')" \
  "all four subscriptions are in the file, not just the two we can read"
assert_equals "ok" "$(field_of aaaaaaaa-0000-0000-0000-000000000001 '.status')" \
  "a readable subscription is scanned normally"
assert_equals "failed" "$(field_of $seen '.status')" \
  "one the identity cannot reach is recorded as failed, not omitted"
assert_contains "$(field_of $seen '.reason')" "no role assignment reaches it" \
  "and its reason names the cause the operator has to fix"

# The tallies are what a reader checks first, so the gap has to show there too.
assert_equals 4 "$(summary_record | jq -r '.subscriptions_total')" \
  "the total counts what the tenant contains, not what was visible"
assert_equals 2 "$(summary_record | jq -r '.subscriptions_scanned')" "two were scanned"
assert_equals 2 "$(summary_record | jq -r '.subscriptions_failed')" "two could not be reached"
assert_equals "true" "$(summary_record | jq -r '.scope_verified')" \
  "and the run could vouch for that total, having checked the hierarchy"

assert_log_has "$seen" "the gap is named on stderr while the run is happening"

# The control: with the grant complete, the very same tenant reports four
# scanned and nothing failed. If these two runs ever produce the same tallies,
# the denominator has stopped working.
restart_fake
scenario <<'JSON'
{ "tenant_id": "11111111-1111-1111-1111-111111111111",
  "subscriptions": [
    "aaaaaaaa-0000-0000-0000-000000000001",
    "bbbbbbbb-0000-0000-0000-000000000002",
    "cccccccc-0000-0000-0000-000000000003",
    "dddddddd-0000-0000-0000-000000000004"
  ],
  "disks": 2, "vms": 1 }
JSON

run_discovery

assert_equals 4 "$(summary_record | jq -r '.subscriptions_scanned')" "a full grant scans all four"
assert_equals 0 "$(summary_record | jq -r '.subscriptions_failed')" "and reports nothing failed"
assert_equals "true" "$(summary_record | jq -r '.scope_verified')" "still verified"
