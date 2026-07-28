# DT-11095 — the second argument-list overflow, on the AMI lookup.
#
# scan_region collected every distinct ImageId into a single shell word list and
# eval'd it into one `aws ec2 describe-images --image-ids ...` call. A region
# with thousands of distinct AMIs blows the same exec limit as the jq call, and
# even below that limit the real EC2 API rejects more than 200 ids per request.
# Either way the AMI list comes back empty and — because the failure is masked
# by `|| echo "[]"` — the record claims the region simply has no AMIs.
#
# 3000 distinct AMIs at ~22 bytes per id is ~66KB of argv, and well over the
# API's per-request id cap.

setup_sandbox

export MOCK_CALLER_ACCOUNT="000000000000"
export MOCK_ACCOUNTS="000000000000"
export MOCK_REGIONS="us-east-1"
export MOCK_VOLUMES=10
export MOCK_INSTANCES=3000
export MOCK_AMI_COUNT=3000
export MOCK_SNAPSHOTS=10

run_discovery

assert_stderr_lacks "Argument list too long" "AMI lookup does not overflow the argument list"
assert_equals 0 "$DISCOVERY_STATUS" "discovery.sh exits 0"
assert_not_empty "$(record_for 000000000000 us-east-1)" "region produced a record"

assert_equals 3000 "$(total_len instances)" "all 3000 instances present"
assert_equals 3000 "$(total_len amis)"      "all 3000 distinct AMIs resolved"

# Batching must not duplicate ids across chunks.
distinct_amis=$(output_lines | jq -r '.amis[]?.ImageId' | sort -u | grep -c . || true)
assert_equals 3000 "$distinct_amis" "no duplicate AMIs across batches"
