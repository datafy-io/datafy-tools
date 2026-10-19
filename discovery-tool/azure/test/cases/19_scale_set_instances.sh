# A Uniform scale set's instances are not in the subscription's virtualMachines
# list, and AKS makes every node one — so a tenant that runs Kubernetes on AKS
# showed scale sets with a capacity and not one node. They are listed under the
# scale set, with the instance view expanded for power state, and reported in
# scale_set_instances.

setup_sandbox

scenario <<'JSON'
{ "subscriptions": ["aaaaaaaa-0000-0000-0000-000000000001"], "scale_sets": 4, "vms": 2, "disks": 1 }
JSON

run_discovery

sub=aaaaaaaa-0000-0000-0000-000000000001

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_equals "ok" "$(field_of $sub '.status')" "the subscription is status=ok"
assert_equals 0 "$(field_of $sub '.errors | length')" "no ARM call was rejected"

# Fake scale sets have capacity 3+i, so 3+4+5+6.
assert_equals 18 "$(len_of $sub scale_set_instances)" "every instance of every scale set arrived"
assert_equals 0 "$(record_for $sub | jq -r '[.virtual_machines[] | select(.scale_set_id != null)] | length')" \
  "none of them came from the VM list — that list never has Uniform instances"

assert_not_empty "$(record_for $sub | jq -r '.scale_set_instances[0].vm_id')" "instances carry the VM id"
assert_not_empty "$(record_for $sub | jq -r '.scale_set_instances[0].computer_name')" "and the node name"
assert_equals "Standard_D2s_v3" "$(record_for $sub | jq -r '.scale_set_instances[0].vm_size')" \
  "vm_size comes from the instance sku"
assert_not_empty "$(record_for $sub | jq -r '.scale_set_instances[0].os_disk.managed_disk_id')" \
  "the OS disk is linked, so disks can be joined to nodes"
assert_at_least 1 "$(record_for $sub | jq -r '[.scale_set_instances[] | select(.power_state == "stopped")] | length')" \
  "power state is collected"
assert_equals 0 "$(record_for $sub | jq -r '[.scale_set_instances[] | select(.power_state == null)] | length')" \
  "for every instance — the expand is honoured at scale-set scope"

# AKS marks the scale sets it manages; that is what identifies a node.
assert_equals "pool0" "$(record_for $sub | jq -r '.scale_sets[0].aks_pool')" "the scale set names its AKS pool"
assert_equals "null" "$(record_for $sub | jq -r '.scale_sets[1].aks_pool')" "and a non-AKS one does not"
assert_equals "pool0" "$(record_for $sub | jq -r '.scale_set_instances[0].aks_pool')" \
  "instances inherit the pool"
assert_equals "vmss-0" "$(record_for $sub | jq -r '.scale_set_instances[0].scale_set_name')" \
  "and name their scale set"

# Instances the identity cannot read must not cost the scale sets themselves.
restart_fake
scenario <<'JSON'
{ "subscriptions": ["aaaaaaaa-0000-0000-0000-000000000001"], "scale_sets": 4,
  "deny": ["Microsoft.Compute/virtualMachineScaleSets/virtualMachines"] }
JSON

run_discovery

assert_equals 4 "$(len_of $sub scale_sets)" "scale sets are still reported when their instances are denied"
assert_equals 0 "$(len_of $sub scale_set_instances)" "with no instances"
assert_equals "partial" "$(field_of $sub '.status')" "the loss is reported, not passed off as complete"
assert_not_empty "$(record_for $sub | jq -r '.errors[] | select(test("virtualMachines"))')" \
  "and the error names the instance call"
