# Coverage has to be answerable from the shared file alone. The summary is
# always the last line, so a truncated upload is obvious, and its four status
# counts add up to the total, so "did this cover everything?" is one jq away.

setup_sandbox

scenario <<'JSON'
{ "subscriptions": [
    {"id": "aaaaaaaa-0000-0000-0000-000000000001", "state": "Enabled"},
    {"id": "bbbbbbbb-0000-0000-0000-000000000002", "state": "Enabled"},
    {"id": "cccccccc-0000-0000-0000-000000000003", "state": "Enabled"},
    {"id": "dddddddd-0000-0000-0000-000000000004", "state": "Disabled"}
  ],
  "disks": 2,
  "deny_by_subscription": {
    "bbbbbbbb-0000-0000-0000-000000000002": ["Microsoft.Compute/disks"],
    "cccccccc-0000-0000-0000-000000000003": ["*"]
  } }
JSON

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"

assert_equals 1 "$(count_records '.record_type == "summary"')" "exactly one summary record"
assert_equals "summary" "$(output_lines | tail -1 | jq -r '.record_type')" \
  "the summary is the last line, so a truncated upload is obvious"

assert_equals "azure"  "$(summary_record | jq -r '.cloud')" \
  "the summary names the cloud, so an Azure file is never mistaken for an AWS one"
assert_not_empty "$(summary_record | jq -r '.tool_version')" "the summary carries the tool version"
assert_equals "false"  "$(summary_record | jq -r '.interrupted')" "a completed run is not marked interrupted"

assert_equals 4 "$(summary_record | jq -r '.subscriptions_total')"   "total counts every subscription in scope"
assert_equals 1 "$(summary_record | jq -r '.subscriptions_scanned')" "one subscription was fully scanned"
assert_equals 1 "$(summary_record | jq -r '.subscriptions_partial')" "one came back incomplete"
assert_equals 1 "$(summary_record | jq -r '.subscriptions_failed')"  "one could not be read"
assert_equals 1 "$(summary_record | jq -r '.subscriptions_skipped')" "one was never eligible"

# The four statuses partition the total — no subscription is counted twice, and
# none goes missing between them.
assert_equals "true" "$(summary_record | jq -r \
  '(.subscriptions_scanned + .subscriptions_partial + .subscriptions_failed + .subscriptions_skipped)
   == .subscriptions_total')" \
  "the status counts add up to the total"

# And they agree with the records themselves, so neither can drift from the other.
assert_equals "$(count_records '.record_type == "subscription"')" \
  "$(summary_record | jq -r '.subscriptions_total')" \
  "the summary agrees with the number of subscription records"
