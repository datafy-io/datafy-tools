# DT-11095 — the AMI lookup must be batched.
#
# scan_region collected every distinct ImageId into a single shell word list and
# eval'd it into one `aws ec2 describe-images --image-ids ...` call. A region
# with thousands of distinct AMIs blows the same exec limit as the record
# assembly, and even below that limit the real EC2 API rejects a request
# carrying more than a couple of hundred ids. Either way the AMI list came back
# empty and — because the failure was masked by `|| echo "[]"` — the record
# claimed the region simply had no AMIs.
#
# The fake endpoint enforces the API's id cap here (max_image_ids), so an
# implementation that sends every id in one request gets an error rather than a
# convenient answer. That is what makes batching testable rather than assumed.

setup_sandbox

scenario <<'JSON'
{ "caller_account": "000000000000",
  "accounts": ["000000000000"],
  "regions":  ["us-east-1"],
  "volumes": 10, "instances": 3000, "snapshots": 10, "ami_count": 3000,
  "max_image_ids": 200 }
JSON

run_discovery

assert_log_lacks "Argument list too long" "the AMI lookup does not overflow the argument list"
assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_not_empty "$(record_for 000000000000 us-east-1)" "the region produced a record"
assert_equals "ok" "$(record_for 000000000000 us-east-1 | jq -r '.status')" \
  "the region is status=ok — the AMI lookup succeeded"

assert_equals 3000 "$(total_len instances)" "all 3000 instances present"
assert_equals 3000 "$(total_len amis)"      "all 3000 distinct AMIs resolved"

# Batching must not duplicate ids across chunks.
distinct_amis=$(output_lines | jq -r '.amis[]?.ImageId' | sort -u | grep -c . || true)
assert_equals 3000 "$distinct_amis" "no duplicate AMIs across batches"

# The endpoint reports the largest id list it was ever handed. Staying under the
# cap is the proof that the request was actually split.
largest=$(fake_stat max_image_ids)
assert_at_least 1 "$largest" "the AMI lookup was actually issued"
assert_at_most 200 "$largest" "no request exceeded the API's id cap (largest was $largest)"
