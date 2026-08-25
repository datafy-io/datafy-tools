# A subscription Azure does not report as Enabled cannot be read. Saying so once
# is more useful than six identical AuthorizationFailed errors — and the
# subscription still has to appear in the file, because a subscription missing
# from the file is indistinguishable from one nobody knew about.

setup_sandbox

scenario <<'JSON'
{ "subscriptions": [
    {"id": "aaaaaaaa-0000-0000-0000-000000000001", "name": "Prod",     "state": "Enabled"},
    {"id": "bbbbbbbb-0000-0000-0000-000000000002", "name": "Old",      "state": "Disabled"},
    {"id": "cccccccc-0000-0000-0000-000000000003", "name": "Expired",  "state": "PastDue"}
  ],
  "disks": 2 }
JSON

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_equals 3 "$(count_records '.record_type == "subscription"')" \
  "every subscription appears in the file, enabled or not"

assert_equals "ok"      "$(field_of aaaaaaaa-0000-0000-0000-000000000001 '.status')" "the enabled subscription was scanned"
assert_equals "skipped" "$(field_of bbbbbbbb-0000-0000-0000-000000000002 '.status')" "a disabled subscription is status=skipped"
assert_equals "skipped" "$(field_of cccccccc-0000-0000-0000-000000000003 '.status')" "a past-due subscription is status=skipped"

assert_contains "$(field_of bbbbbbbb-0000-0000-0000-000000000002 '.reason')" "Disabled" \
  "the reason names the state Azure reported"
assert_equals "Disabled" "$(field_of bbbbbbbb-0000-0000-0000-000000000002 '.subscription_state')" \
  "the raw subscription state is recorded too"

# A skipped subscription is not scanned, so its arrays are empty — and its
# status is what says so, not the emptiness.
assert_equals 0 "$(len_of bbbbbbbb-0000-0000-0000-000000000002 disks)" "a skipped subscription holds no data"

assert_equals 2 "$(summary_record | jq -r '.subscriptions_skipped')" "the summary counts both skipped subscriptions"
assert_equals 1 "$(summary_record | jq -r '.subscriptions_scanned')" "and the one that was scanned"
assert_equals 3 "$(summary_record | jq -r '.subscriptions_total')"   "and they add up to the total"
