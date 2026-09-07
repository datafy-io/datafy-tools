# ARM paginates a list response with an absolute nextLink carrying its own
# continuation token. Following it means re-sending it verbatim — adding query
# parameters to it is how a paginated scan silently returns only its first page,
# and a first page of disks looks exactly like a small tenant.

setup_sandbox

scenario <<'JSON'
{ "subscriptions": ["aaaaaaaa-0000-0000-0000-000000000001"],
  "page_size": 7,
  "disks": 50, "vms": 23, "snapshots": 31, "images": 9, "scale_sets": 8,
  "vaults": 3, "policies": 5 }
JSON

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_valid_jsonl "output is valid JSONL"

sub=aaaaaaaa-0000-0000-0000-000000000001
assert_equals "ok" "$(field_of $sub '.status')" "a paginated scan is still status=ok"

assert_equals 50 "$(len_of $sub disks)"            "every page of disks arrived"
assert_equals 23 "$(len_of $sub virtual_machines)" "every page of VMs arrived"
assert_equals 31 "$(len_of $sub snapshots)"        "every page of snapshots arrived"
assert_equals  9 "$(len_of $sub images)"           "every page of images arrived"
assert_equals  8 "$(len_of $sub scale_sets)"       "every page of scale sets arrived"
assert_equals  6 "$(len_of $sub backup_vaults)"    "every page of vaults arrived, both families"
assert_equals 30 "$(len_of $sub backup_policies)"  "every page of policies arrived, from every vault"

# Distinct ids, not the same page counted repeatedly — a nextLink that loses its
# continuation token returns page one forever and would still total 50.
assert_equals 50 "$(record_for $sub | jq -r '[.disks[].id] | unique | length')" \
  "the disks are 50 distinct resources, not one page repeated"

# The endpoint served more pages than it did calls, which is what proves
# pagination actually happened rather than everything fitting in one response.
assert_at_least 8 "$(fake_stat pages)" "the endpoint served multiple pages"
