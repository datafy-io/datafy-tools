# DT-11095 — regression test for:
#   discovery.sh: line 253: /usr/bin/jq: Argument list too long
#
# scan_region assembled its result by passing every transformed array to jq as a
# command-line argument (--argjson volumes "$volumes" ...). A single busy region
# produces megabytes of JSON, which exceeds the kernel's exec argument limit
# (1MB total on macOS, 128KB per single argument on Linux), so jq is never
# executed. The failure is swallowed by the region subshell, so the region
# vanishes from the output with no error recorded — which is exactly how
# entire regions went missing from the customer's run.
#
# 4000 volumes -> ~2.4MB of transformed JSON, comfortably over both limits.

setup_sandbox

export MOCK_CALLER_ACCOUNT="000000000000"
export MOCK_ACCOUNTS="000000000000"
export MOCK_REGIONS="us-east-1"
export MOCK_VOLUMES=4000
export MOCK_INSTANCES=50
export MOCK_SNAPSHOTS=2000

run_discovery

assert_stderr_lacks "Argument list too long" "jq is not invoked with an oversized argument list"
assert_equals 0 "$DISCOVERY_STATUS" "discovery.sh exits 0"
assert_valid_jsonl "output is valid JSONL"

assert_not_empty "$(record_for 000000000000 us-east-1)" \
  "the large region still produced a record"

assert_equals 4000 "$(total_len volumes)"   "all 4000 volumes survived assembly"
assert_equals 50   "$(total_len instances)" "all 50 instances survived assembly"
assert_equals 2000 "$(total_len snapshots)" "all 2000 snapshots survived assembly"
