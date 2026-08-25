# A tenant-wide scan exhausts a subscription's ARM read quota, and ARM answers
# 429 with a Retry-After header. The retry policy is pinned rather than left to
# the client default so a burst is ridden out rather than costing a whole
# subscription — which in Azure is the entire blast radius of one lost call.

setup_sandbox

scenario <<'JSON'
{ "subscriptions": ["aaaaaaaa-0000-0000-0000-000000000001"],
  "disks": 5, "vms": 2,
  "throttle": { "Microsoft.Compute/disks": 3 } }
JSON

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "a throttled run still exits 0"
assert_valid_jsonl "output is valid JSONL"

sub=aaaaaaaa-0000-0000-0000-000000000001

assert_at_least 3 "$(fake_stat throttled)" "the endpoint really did throttle the call"
assert_equals "ok" "$(field_of $sub '.status')" \
  "a throttled call that succeeds on retry leaves the subscription status=ok"
assert_equals 5 "$(len_of $sub disks)" "and the data arrives whole"
assert_equals "0" "$(field_of $sub '.errors | length')" "a ridden-out throttle is not an error"

# Once the attempts are exhausted the loss must be visible: reported as a
# degraded subscription with the Azure error code, never as an empty one.
restart_fake
scenario <<'JSON'
{ "subscriptions": ["aaaaaaaa-0000-0000-0000-000000000001"],
  "disks": 5, "vms": 2,
  "throttle": { "Microsoft.Compute/disks": 999 } }
JSON

AZURE_MAX_ATTEMPTS=3 run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "exits 0 — a lost call is data loss, not a crash"
assert_equals "partial" "$(field_of $sub '.status')" \
  "a call that exhausts its attempts leaves the subscription status=partial"
assert_equals 0 "$(len_of $sub disks)" "the disks could not be read"
assert_not_empty "$(record_for $sub | jq -r '.errors[] | select(test("Microsoft.Compute/disks"))')" \
  "and the record says so, naming the provider"
assert_not_empty "$(record_for $sub | jq -r '.errors[] | select(test("TooManyRequests|Http429"))')" \
  "carrying the Azure error code, so throttling is distinguishable from a denial"

# AZURE_MAX_ATTEMPTS counts total attempts, the first one included — the same
# contract as AWS_MAX_ATTEMPTS in the AWS edition, and the reason azure-core's
# retry_total is not passed through raw.
assert_equals 3 "$(fake_calls_for 'Microsoft.Compute/disks')" \
  "AZURE_MAX_ATTEMPTS=3 means three attempts in total, not three retries"
