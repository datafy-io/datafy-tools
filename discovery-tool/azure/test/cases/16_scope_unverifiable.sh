# When the tenant root management group cannot be read either, there is no
# denominator to be had: the run genuinely does not know what it is missing.
#
# The honest thing is to say so in the file rather than print totals that imply
# coverage the run never established. scope_verified=false is the one field that
# distinguishes "this is the whole tenant" from "this is what I could see".

setup_sandbox

scenario <<'JSON'
{ "tenant_id": "11111111-1111-1111-1111-111111111111",
  "subscriptions": [
    "aaaaaaaa-0000-0000-0000-000000000001",
    "bbbbbbbb-0000-0000-0000-000000000002"
  ],
  "deny_tenant_root": true,
  "disks": 2, "vms": 1 }
JSON

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" \
  "exits 0 — an unverifiable scope is a caveat on the results, not a failure"
assert_valid_jsonl "output is valid JSONL"

# What could be read is still read and still useful.
assert_equals 2 "$(count_records '.record_type == "subscription"')" "the visible subscriptions were scanned"
assert_equals 2 "$(summary_record | jq -r '.subscriptions_scanned')" "and counted"

assert_equals "false" "$(summary_record | jq -r '.scope_verified')" \
  "the summary says the scope could not be verified"
assert_not_empty "$(summary_record | jq -r '.scope_note // empty')" \
  "and carries a note explaining why"
assert_contains "$(summary_record | jq -r '.scope_note')" "do not read these totals as full tenant coverage" \
  "the note says plainly how the totals must not be read"
assert_contains "$(summary_record | jq -r '.scope_note')" "AuthorizationFailed" \
  "and carries the Azure error code, so the operator knows it is an RBAC gap"

# Loud on stderr too, because this is the one gap that leaves no other trace:
# what is absent is absent without a record of its own.
assert_log_has "Coverage could not be verified" "the operator is warned while the run is happening"
