# One subscription holding far more than a single ARM page of everything. A
# design partner's production subscription is this shape, and the failure mode
# it guards against — a paginated list quietly returning its first page — looks
# exactly like a healthy small tenant.

setup_sandbox

scenario <<'JSON'
{ "subscriptions": ["aaaaaaaa-0000-0000-0000-000000000001"],
  "locations": ["westeurope", "eastus", "northeurope", "uksouth"],
  "page_size": 100,
  "disks": 4000, "vms": 800, "snapshots": 1500, "images": 120, "scale_sets": 60,
  "vaults": 2, "policies": 20 }
JSON

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_valid_jsonl "output is valid JSONL"

sub=aaaaaaaa-0000-0000-0000-000000000001
assert_equals "ok" "$(field_of $sub '.status')" "the large subscription is status=ok"

assert_equals 4000 "$(len_of $sub disks)"            "all 4000 disks arrived"
assert_equals  800 "$(len_of $sub virtual_machines)" "all 800 VMs arrived"
assert_equals 1500 "$(len_of $sub snapshots)"        "all 1500 snapshots arrived"
assert_equals  120 "$(len_of $sub images)"           "all 120 images arrived"
assert_equals   60 "$(len_of $sub scale_sets)"       "all 60 scale sets arrived"

assert_equals 4000 "$(record_for $sub | jq -r '[.disks[].id] | unique | length')" \
  "the disks are 4000 distinct resources, not pages repeated"

assert_equals "eastus northeurope uksouth westeurope" "$(field_of $sub '.locations | join(" ")')" \
  "every location the resources sit in is rolled up"

# The whole subscription is one line of JSONL, which is the shape a consumer
# reads — worth asserting once at a size where it might not have been.
assert_equals 2 "$(output_lines | wc -l | tr -d ' ')" \
  "one subscription record plus one summary, however large the subscription"
