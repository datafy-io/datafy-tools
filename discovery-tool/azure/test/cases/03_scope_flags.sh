# --include and --exclude narrow the scan. An id that was asked for and is not
# visible to this identity is a scoping mistake worth saying out loud, rather
# than a quietly shorter run that looks like a complete one.

setup_sandbox

scenario <<'JSON'
{ "subscriptions": [
    "aaaaaaaa-0000-0000-0000-000000000001",
    "bbbbbbbb-0000-0000-0000-000000000002",
    "cccccccc-0000-0000-0000-000000000003"
  ],
  "disks": 1, "vms": 1 }
JSON

run_discovery --include aaaaaaaa-0000-0000-0000-000000000001,cccccccc-0000-0000-0000-000000000003

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_equals 2 "$(count_records '.record_type == "subscription"')" "--include scanned only the named subscriptions"
assert_not_empty "$(record_for aaaaaaaa-0000-0000-0000-000000000001)" "an included subscription is present"
assert_empty     "$(record_for bbbbbbbb-0000-0000-0000-000000000002)" "an unlisted subscription is absent"

# Even a narrowed run reports its own scope, so the file says what it covered.
assert_equals 2 "$(summary_record | jq -r '.subscriptions_total')" \
  "the summary counts the narrowed scope, not the whole tenant"

restart_fake
run_discovery --exclude bbbbbbbb-0000-0000-0000-000000000002

assert_equals 2 "$(count_records '.record_type == "subscription"')" "--exclude skipped the named subscription"
assert_empty "$(record_for bbbbbbbb-0000-0000-0000-000000000002)" "the excluded subscription is absent"

# An --include id this identity cannot see is a gap, and a gap belongs in the
# file. A warning on stderr alone is gone the moment the operator redirects it,
# and the file is the only thing that gets sent to us.
restart_fake
run_discovery --include aaaaaaaa-0000-0000-0000-000000000001,dddddddd-0000-0000-0000-000000000009

missing=dddddddd-0000-0000-0000-000000000009
assert_equals 2 "$(count_records '.record_type == "subscription"')" \
  "both the scanned subscription and the unreachable one are in the file"
assert_equals "ok" "$(field_of aaaaaaaa-0000-0000-0000-000000000001 '.status')" \
  "the visible included subscription was scanned"
assert_equals "failed" "$(field_of $missing '.status')" \
  "the one that cannot be seen is recorded as failed, not dropped"
assert_contains "$(field_of $missing '.reason')" "--include" \
  "and its reason says it was asked for by name"
assert_contains "$(field_of $missing '.reason')" "no role assignment reaches it" \
  "and points at the cause the operator has to fix"
assert_log_has "$missing" "it is named on stderr too, while the run is happening"
assert_equals 2 "$(summary_record | jq -r '.subscriptions_total')" \
  "the unreachable subscription counts towards the total"
assert_equals 1 "$(summary_record | jq -r '.subscriptions_failed')" \
  "and towards the failed tally, so tail -1 shows the gap"
