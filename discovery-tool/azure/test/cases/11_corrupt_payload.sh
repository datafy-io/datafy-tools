# A 200 whose body is not JSON — a captive portal, a proxy error page, a
# truncated response — must be reported, never read as an empty result. An
# unparseable disks response and a subscription with no disks are very
# different findings.

setup_sandbox

scenario <<'JSON'
{ "subscriptions": ["aaaaaaaa-0000-0000-0000-000000000001"],
  "disks": 5, "vms": 2,
  "corrupt": ["Microsoft.Compute/disks"] }
JSON

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "exits 0 — a bad payload is data loss, not a crash"
assert_valid_jsonl "the output file is still valid JSONL"

sub=aaaaaaaa-0000-0000-0000-000000000001

assert_equals "partial" "$(field_of $sub '.status')" \
  "an unparseable response leaves the subscription status=partial"
assert_equals 0 "$(len_of $sub disks)" "the disks could not be read"
assert_not_empty "$(record_for $sub | jq -r '.errors[] | select(test("Microsoft.Compute/disks"))')" \
  "the error names the provider whose response could not be parsed"

# The calls that did work are unaffected — one bad response must not cost the
# whole subscription.
assert_equals 2 "$(len_of $sub virtual_machines)" "the calls that succeeded still returned their data"
