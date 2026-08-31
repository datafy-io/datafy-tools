# Smoke test — proves the tool is wired up to the fake ARM endpoint and that a
# normal small tenant produces the documented one-record-per-subscription output.

setup_sandbox

scenario <<'JSON'
{ "subscriptions": [
    {"id": "aaaaaaaa-0000-0000-0000-000000000001", "name": "Prod",    "state": "Enabled"},
    {"id": "bbbbbbbb-0000-0000-0000-000000000002", "name": "Non-prod","state": "Enabled"}
  ],
  "locations": ["westeurope", "eastus"],
  "disks": 4, "vms": 2, "snapshots": 2, "images": 1, "scale_sets": 1,
  "vaults": 1, "policies": 2 }
JSON

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_valid_jsonl "output is valid JSONL"

assert_equals 2 "$(count_records '.record_type == "subscription"')" \
  "one record per subscription"
assert_equals 1 "$(count_records '.record_type == "summary"')" \
  "exactly one summary record"

assert_not_empty "$(record_for aaaaaaaa-0000-0000-0000-000000000001)" "Prod has a record"
assert_not_empty "$(record_for bbbbbbbb-0000-0000-0000-000000000002)" "Non-prod has a record"

# The display name is why the subscription list is fetched even when the ids are
# already known — an id alone is not something a customer can talk about.
assert_equals "Prod" "$(field_of aaaaaaaa-0000-0000-0000-000000000001 '.subscription_name')" \
  "the subscription's display name is recorded"

assert_equals 0 "$(count_records '.record_type == "subscription" and .status != "ok"')" \
  "every subscription record is status=ok"

# 2 subscriptions x the per-subscription counts above.
assert_equals 8 "$(total_len disks)"            "all 8 disks present"
assert_equals 4 "$(total_len virtual_machines)" "all 4 VMs present"
assert_equals 4 "$(total_len snapshots)"        "all 4 snapshots present"
assert_equals 2 "$(total_len images)"           "all 2 images present"
assert_equals 2 "$(total_len scale_sets)"       "all 2 scale sets present"
# "vaults": 1 gives each subscription one Recovery Services vault and one Data
# Protection backup vault — both families are searched, and both are reported.
assert_equals 4 "$(total_len backup_vaults)"    "both vault families searched in both subscriptions"
assert_equals 8 "$(total_len backup_policies)"  "policies fetched from every vault found"

assert_equals 2 "$(count_records '.record_type == "subscription"')" \
  "vault policies do not multiply the subscription records"
assert_equals "DataProtection RecoveryServices" \
  "$(output_lines | jq -r 'select(.record_type=="subscription") | .backup_vaults[].vault_type' | sort -u | tr '\n' ' ' | sed 's/ $//')" \
  "both vault families are labelled in the output"

# Both locations the resources sit in are rolled up, so "which regions are you
# in" is answerable without unioning six arrays by hand.
assert_equals "eastus westeurope" \
  "$(field_of aaaaaaaa-0000-0000-0000-000000000001 '.locations | join(" ")')" \
  "locations are rolled up from the resources actually found"

# The record shape the README documents, checked once here so the other cases
# can take it as given.
missing=$(output_lines | jq -r 'select(.record_type == "subscription")
  | [ "subscription_id","subscription_name","tenant_id","subscription_state","status",
      "reason","scanned_at","errors","locations","disks","virtual_machines","scale_sets",
      "snapshots","images","backup_vaults","backup_policies" ]
  - (. | keys) | .[]' | sort -u | tr '\n' ' ')
assert_empty "$missing" "subscription records carry every documented field"

# Timestamps are RFC3339 UTC with a Z suffix, as the README states.
assert_not_empty "$(field_of aaaaaaaa-0000-0000-0000-000000000001 \
  '.scanned_at | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))')" \
  "scanned_at is RFC3339 UTC with a Z suffix"
