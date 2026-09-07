# An empty subscription and an unreadable one must never look alike. A call that
# swallows its failure and returns an empty array makes the two indistinguishable
# in the output, and the gap is then only findable by diffing against an older
# run — which nobody does.
#
# The blast radius is a whole subscription, because ARM list calls are
# subscription-scoped: a denied read costs every region in it at once. That is
# exactly why status lives on the subscription record.
#
# Three subscriptions here: one genuinely empty, one denied a single provider,
# one denied everything.

setup_sandbox

scenario <<'JSON'
{ "subscriptions": [
    "aaaaaaaa-0000-0000-0000-000000000001",
    "bbbbbbbb-0000-0000-0000-000000000002",
    "cccccccc-0000-0000-0000-000000000003"
  ],
  "disks": 0, "vms": 0, "snapshots": 0, "images": 0, "scale_sets": 0, "vaults": 0,
  "deny_by_subscription": {
    "bbbbbbbb-0000-0000-0000-000000000002": ["Microsoft.Compute/disks"],
    "cccccccc-0000-0000-0000-000000000003": ["*"]
  } }
JSON

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "exits 0 despite unreadable subscriptions"
assert_valid_jsonl "output is valid JSONL"

empty=aaaaaaaa-0000-0000-0000-000000000001
partial=bbbbbbbb-0000-0000-0000-000000000002
denied=cccccccc-0000-0000-0000-000000000003

# All three must be represented — a failing subscription must not vanish.
assert_not_empty "$(record_for $empty)"   "the empty subscription is present"
assert_not_empty "$(record_for $partial)" "the partially-denied subscription is present"
assert_not_empty "$(record_for $denied)"  "the fully-denied subscription is present"

assert_equals "ok" "$(field_of $empty '.status')" "a genuinely empty subscription is status=ok"
assert_equals "0"  "$(field_of $empty '.errors | length')" "an empty subscription records no errors"
assert_equals "0"  "$(len_of $empty disks)" "and its disks array is genuinely empty"

assert_equals "partial" "$(field_of $partial '.status')" \
  "a subscription with one denied provider is status=partial"
assert_equals "1" "$(field_of $partial '.errors | length')" "the denied call is recorded"
assert_not_empty "$(record_for $partial | jq -r '.errors[] | select(test("Microsoft.Compute/disks"))')" \
  "the error names the provider that was denied"
assert_not_empty "$(record_for $partial | jq -r '.errors[] | select(test("AuthorizationFailed"))')" \
  "the error carries the Azure error code, so the operator knows to fix RBAC"

assert_equals "failed" "$(field_of $denied '.status')" \
  "a wholly unreadable subscription is status=failed"
assert_at_least 1 "$(field_of $denied '.errors | length')" \
  "the unreadable subscription explains itself"

# The operator must be told while the run is happening, not only in the file.
assert_log_has "$denied" "the failed subscription is named in the progress output"
assert_log_has "send the file as-is" "the operator is told the file records the gaps"
