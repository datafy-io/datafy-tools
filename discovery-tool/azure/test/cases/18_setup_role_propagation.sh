# Azure does not make a role assignment effective the moment it is written —
# ARM has to propagate it, which can take minutes.
#
# This is the subtle way --setup-role fails: the PUT succeeds, the tool scans
# immediately, and every subscription it just granted itself access to is still
# invisible. The run then reports them unreachable — a result identical to the
# flag not working at all, produced moments after it did. Worse, a customer
# would conclude the tool cannot see their tenant.
#
# Here the grant takes three polls to take effect.

setup_sandbox

scenario <<'JSON'
{ "tenant_id": "11111111-1111-1111-1111-111111111111",
  "subscriptions": [
    "aaaaaaaa-0000-0000-0000-000000000001",
    "bbbbbbbb-0000-0000-0000-000000000002"
  ],
  "invisible_subscriptions": [
    "aaaaaaaa-0000-0000-0000-000000000001",
    "bbbbbbbb-0000-0000-0000-000000000002"
  ],
  "propagation_polls": 3,
  "disks": 2, "vms": 1 }
JSON

AZURE_PROPAGATION_POLL=0.1 AZURE_PROPAGATION_TIMEOUT=30 run_discovery --setup-role

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_valid_jsonl "output is valid JSONL"

assert_equals 2 "$(summary_record | jq -r '.subscriptions_scanned')" \
  "the scan waited for the grant to take effect, and then covered everything"
assert_equals 0 "$(summary_record | jq -r '.subscriptions_failed')" \
  "nothing was written off as unreachable while the grant was still landing"
assert_log_has "Waiting for the role assignment to take effect" \
  "the operator is told why the run is pausing, rather than watching it hang"
assert_log_has "Reader is in effect" "and told when it is usable"

assert_equals 0 "$(fake_stat assignments)" "the assignment was still cleaned up afterwards"

# A grant that never propagates must not hang the run forever, and must not be
# reported as coverage either: the timeout is a bounded wait, after which the
# subscriptions still out of reach are recorded the ordinary way.
restart_fake
scenario <<'JSON'
{ "tenant_id": "11111111-1111-1111-1111-111111111111",
  "subscriptions": [
    "aaaaaaaa-0000-0000-0000-000000000001",
    "bbbbbbbb-0000-0000-0000-000000000002"
  ],
  "invisible_subscriptions": [
    "aaaaaaaa-0000-0000-0000-000000000001",
    "bbbbbbbb-0000-0000-0000-000000000002"
  ],
  "propagation_polls": 100000,
  "disks": 2, "vms": 1 }
JSON

AZURE_PROPAGATION_POLL=0.1 AZURE_PROPAGATION_TIMEOUT=1 run_discovery --setup-role

assert_equals 0 "$DISCOVERY_STATUS" "a grant that never lands does not hang the run"
assert_log_has "still not visible after" "the operator is told the wait was given up on"
assert_equals 2 "$(summary_record | jq -r '.subscriptions_failed')" \
  "and the subscriptions are recorded as unreachable, not silently dropped"
assert_equals 2 "$(count_records '.record_type == "subscription"')" \
  "each one still gets a record with a reason"
assert_equals 0 "$(fake_stat assignments)" "and the assignment is cleaned up regardless"
