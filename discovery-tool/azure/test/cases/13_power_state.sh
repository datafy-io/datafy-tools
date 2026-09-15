# A stopped VM still paying for its disks is one of the findings a scoping run
# exists to surface, so power_state has to be collected. It lives in the VM
# instance view, and how you get that at subscription scope is not obvious:
#
#   GET /subscriptions/<s>/providers/Microsoft.Compute/virtualMachines
#       ?$expand=instanceView
#
# is rejected outright by ARM — "Expand Instance View is only supported when
# Virtual Machine Scale Set resource filter is applied". The first version of
# this tool asked for exactly that, and the first version of the fake ARM
# answered it happily, so the suite was green while a real tenant returned 400.
# The fake now refuses it the way ARM does, and this case pins both halves: that
# the expand is never asked for, and that statusOnly=true is.

setup_sandbox

scenario <<'JSON'
{ "subscriptions": ["aaaaaaaa-0000-0000-0000-000000000001"], "vms": 6, "disks": 1 }
JSON

run_discovery

sub=aaaaaaaa-0000-0000-0000-000000000001

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_equals "ok" "$(field_of $sub '.status')" "the subscription is status=ok"
assert_equals 6 "$(len_of $sub virtual_machines)" "every VM arrived"

# If the tool ever goes back to asking for the inline expand, ARM answers 400,
# the error lands in the record and this assertion fails.
assert_equals "0" "$(field_of $sub '.errors | length')" \
  "no ARM call was rejected — the inline instanceView expand is not asked for"

assert_at_least 1 "$(record_for $sub | jq -r '[.virtual_machines[] | select(.power_state == "deallocated")] | length')" \
  "a deallocated VM is visible as such — the reason the status pass is made"
assert_at_least 1 "$(record_for $sub | jq -r '[.virtual_machines[] | select(.power_state == "running")] | length')" \
  "and a running one is too"
assert_equals 0 "$(record_for $sub | jq -r '[.virtual_machines[] | select(.power_state == null)] | length')" \
  "every VM got a power state"

# The status pass returns run-time status, not a second copy of each VM, so the
# inventory fields must still come from the plain list.
assert_equals "Standard_D2s_v3" "$(record_for $sub | jq -r '.virtual_machines[0].vm_size')" \
  "VM inventory fields survive the merge"
assert_not_empty "$(record_for $sub | jq -r '.virtual_machines[0].os_disk.managed_disk_id')" \
  "and so does the disk linkage the merge must not disturb"

# Losing run state must never cost the fleet: the inventory call goes out plain
# and first, so a failing status pass degrades one field, not the subscription.
restart_fake
scenario <<'JSON'
{ "subscriptions": ["aaaaaaaa-0000-0000-0000-000000000001"],
  "vms": 6, "disks": 1, "reject_status_only": true }
JSON

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_equals 6 "$(len_of $sub virtual_machines)" \
  "every VM is still reported when the status pass is denied"
assert_equals 6 "$(record_for $sub | jq -r '[.virtual_machines[] | select(.power_state == null)] | length')" \
  "power_state is null, since run state was never returned"
assert_equals "partial" "$(field_of $sub '.status')" \
  "the loss is reported, not passed off as a complete scan"
assert_not_empty "$(record_for $sub | jq -r '.errors[] | select(test("statusOnly"))')" \
  "the error names the pass that failed, so the null power_state is explained"
