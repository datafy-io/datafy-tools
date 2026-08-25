# --management-group narrows to a subtree of the management group hierarchy —
# the Azure analogue of the AWS edition's --ou. /descendants walks the whole
# subtree, so a nested group's subscriptions are included, which is what an
# operator naming their top-level "Production" group means.

setup_sandbox

scenario <<'JSON'
{ "subscriptions": [
    "aaaaaaaa-0000-0000-0000-000000000001",
    "bbbbbbbb-0000-0000-0000-000000000002",
    "cccccccc-0000-0000-0000-000000000003"
  ],
  "disks": 2,
  "management_groups": {
    "mg-production": [
      "aaaaaaaa-0000-0000-0000-000000000001",
      "cccccccc-0000-0000-0000-000000000003"
    ],
    "mg-empty": []
  } }
JSON

run_discovery --management-group mg-production

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_equals 2 "$(count_records '.record_type == "subscription"')" \
  "only subscriptions beneath the management group were scanned"
assert_not_empty "$(record_for aaaaaaaa-0000-0000-0000-000000000001)" "a member subscription is present"
assert_not_empty "$(record_for cccccccc-0000-0000-0000-000000000003)" "a nested member subscription is present"
assert_empty     "$(record_for bbbbbbbb-0000-0000-0000-000000000002)" "a non-member subscription is absent"

# A management group with nothing in it must produce an honest empty run, not an
# error and not the whole tenant.
restart_fake
run_discovery --management-group mg-empty

assert_equals 0 "$DISCOVERY_STATUS" "an empty management group still exits 0"
assert_equals 0 "$(count_records '.record_type == "subscription"')" "and scans nothing"
assert_equals 1 "$(count_records '.record_type == "summary"')" "but still writes a summary"
assert_equals 0 "$(summary_record | jq -r '.subscriptions_total')" "the summary says the scope was empty"

# A management group that does not exist must fail loudly rather than silently
# falling back to scanning the entire tenant.
restart_fake
run_discovery --management-group mg-does-not-exist

assert_equals 1 "$DISCOVERY_STATUS" "an unknown management group exits non-zero"
assert_log_has "could not determine which subscriptions to scan" "and says why"
