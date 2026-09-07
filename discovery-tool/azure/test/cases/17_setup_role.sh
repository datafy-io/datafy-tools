# --setup-role: grant the access the scan needs, scan, then always take it away
# again.
#
# Because Azure RBAC inherits, that is one assignment at a tenant root
# management group covering every subscription beneath it — however large the
# tenant, one grant and one revoke.
#
# The tenant below has four subscriptions and the identity can initially see
# none of them, so the flag either works or the run comes back empty. That is
# deliberate: it is the only setup in which "the flag did nothing" and "the flag
# worked" cannot produce the same output.

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
    "aaaaaaaa-0000-0000-0000-000000000001",
    "bbbbbbbb-0000-0000-0000-000000000002",
    "cccccccc-0000-0000-0000-000000000003",
    "dddddddd-0000-0000-0000-000000000004"
  ],
  "disks": 2, "vms": 1 }
JSON

# Without the flag: nothing is granted, nothing is visible, and the run says so
# rather than reporting an empty tenant as a clean result. This is the control —
# it is what makes the run below mean something.
run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "without --setup-role the run still exits 0"
assert_equals 0 "$(count_records '.record_type == "subscription" and .status == "ok"')" \
  "without the flag, nothing could be read"
assert_equals 4 "$(summary_record | jq -r '.subscriptions_failed')" \
  "and all four are recorded as unreachable rather than omitted"
assert_equals 0 "$(fake_stat assignments)" "no role assignment was created"

# With the flag: Reader is assigned at the tenant root, the subscriptions become
# visible, and the scan covers them.
restart_fake
run_discovery --setup-role

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_valid_jsonl "output is valid JSONL"

assert_equals 4 "$(count_records '.record_type == "subscription" and .status == "ok"')" \
  "with --setup-role every subscription became readable"
assert_equals 4 "$(summary_record | jq -r '.subscriptions_scanned')" "all four were scanned"
assert_equals 0 "$(summary_record | jq -r '.subscriptions_failed')" "and none was left unreachable"
assert_equals 8 "$(total_len disks)" "their data was actually collected"

assert_log_has "$TEST_PRINCIPAL_ID" \
  "the principal being granted Reader is named, taken from the token's oid claim"
assert_log_has "/providers/Microsoft.Management/managementGroups/11111111-1111-1111-1111-111111111111" \
  "the grant is made at the tenant root management group, not per subscription"

# One assignment for the whole tenant, however many subscriptions it holds.
assert_equals 1 "$(fake_calls_for 'roleAssignments/write')" \
  "one assignment covered the entire tenant"

# And it is gone by the end. This is the assertion that matters most: the tool
# writes exactly one thing, and must not leave it behind.
assert_equals 1 "$(fake_calls_for 'roleAssignments/delete')" "the assignment was removed"
assert_equals 0 "$(fake_stat assignments)" "nothing was left behind in the tenant"
assert_log_has "Reader assignment removed" "and the operator is told it was cleaned up"

# Cleanup has to survive a failing run, or a crash mid-scan leaves the customer
# holding a role assignment they did not ask for. An unwritable --output fails
# after the grant and before the scan, which is the worst moment for it.
restart_fake
run_discovery_to "$SANDBOX/no/such/dir/out.json" --setup-role

assert_equals 1 "$DISCOVERY_STATUS" "a failing run still exits non-zero"
assert_equals 1 "$(fake_calls_for 'roleAssignments/write')" "the grant was made"
assert_equals 0 "$(fake_stat assignments)" \
  "and was still removed, even though the run failed before scanning"

# A pre-existing assignment must not be revoked out from under the customer:
# teardown removes only what this run created.
restart_fake
scenario <<'JSON'
{ "tenant_id": "11111111-1111-1111-1111-111111111111",
  "subscriptions": ["aaaaaaaa-0000-0000-0000-000000000001"],
  "role_already_exists": true,
  "disks": 1 }
JSON

run_discovery --setup-role

assert_equals 0 "$DISCOVERY_STATUS" "a standing grant is not an error"
assert_log_has "already assigned" "the tool says it found one and left it alone"
assert_equals 0 "$(fake_calls_for 'roleAssignments/delete')" \
  "and never deletes an assignment it did not create"

# No permission to create the assignment is a scoping problem the operator can
# act on, so it has to be said plainly rather than surfacing as a traceback.
restart_fake
scenario <<'JSON'
{ "tenant_id": "11111111-1111-1111-1111-111111111111",
  "subscriptions": ["aaaaaaaa-0000-0000-0000-000000000001"],
  "deny_role_write": true,
  "disks": 1 }
JSON

run_discovery --setup-role

assert_equals 1 "$DISCOVERY_STATUS" "exits non-zero when the grant is refused"
assert_log_has "could not grant Reader" "and says what failed"
assert_log_has "User Access Administrator" "naming the permission that would fix it"
assert_log_has "Run without --setup-role" "and the way to proceed regardless"
assert_equals 0 "$(fake_stat assignments)" "nothing was left behind"
