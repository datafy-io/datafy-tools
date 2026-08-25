# power_state comes only from the VM instance view, and a stopped VM still
# paying for its disks is exactly what a scoping run is looking for — so the
# tool asks for $expand=instanceView. If a provider version rejects the
# parameter, losing power_state is a far smaller loss than losing the VM list,
# so the call is retried plain. The fallback is recorded, so the subscription
# reports partial rather than passing itself off as complete.

setup_sandbox

# First: the normal case, where the expand is honoured.
scenario <<'JSON'
{ "subscriptions": ["aaaaaaaa-0000-0000-0000-000000000001"], "vms": 6, "disks": 1 }
JSON

run_discovery

sub=aaaaaaaa-0000-0000-0000-000000000001
assert_equals "ok" "$(field_of $sub '.status')" "with the expand honoured the subscription is status=ok"
assert_equals 6 "$(len_of $sub virtual_machines)" "every VM arrived"
assert_at_least 1 "$(record_for $sub | jq -r '[.virtual_machines[] | select(.power_state == "deallocated")] | length')" \
  "a deallocated VM is visible as such — the reason the expand is asked for"

# Then: the same tenant, with ARM rejecting $expand.
restart_fake
scenario <<'JSON'
{ "subscriptions": ["aaaaaaaa-0000-0000-0000-000000000001"],
  "vms": 6, "disks": 1, "reject_expand": true }
JSON

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_equals 6 "$(len_of $sub virtual_machines)" \
  "the VM list survives a rejected expand — the fallback ran"
assert_equals 6 "$(record_for $sub | jq -r '[.virtual_machines[] | select(.power_state == null)] | length')" \
  "power_state is null, since the instance view was never returned"

assert_equals "partial" "$(field_of $sub '.status')" \
  "the fallback is reported, not passed off as a complete scan"
assert_not_empty "$(record_for $sub | jq -r '.errors[] | select(test("instanceView"))')" \
  "the error names the expand that was rejected, so the null power_state is explained"
