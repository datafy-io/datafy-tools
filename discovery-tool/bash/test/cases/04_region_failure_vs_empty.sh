# DT-11095 — "Clear differentiation between regions that were empty and those
# that were skipped."
#
# Before the fix every AWS call was `2>/dev/null || echo "[]"`, so a region that
# denied ec2:DescribeVolumes was indistinguishable from a region that genuinely
# held no volumes: both emitted "volumes": []. The customer only discovered the
# gap by diffing against an older run.
#
# Every region here is genuinely empty. eu-west-1 additionally denies
# DescribeVolumes, and ap-southeast-1 denies everything.

setup_sandbox

export MOCK_CALLER_ACCOUNT="000000000000"
export MOCK_ACCOUNTS="000000000000"
export MOCK_REGIONS="us-east-1,eu-west-1,ap-southeast-1"
export MOCK_VOLUMES=0
export MOCK_INSTANCES=0
export MOCK_SNAPSHOTS=0
export MOCK_DENY_VOLUMES="000000000000/eu-west-1"
export MOCK_DENY_ALL="000000000000/ap-southeast-1"

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "discovery.sh exits 0"
assert_valid_jsonl "output is valid JSONL"

# All three regions must be represented — a failing region must not vanish.
assert_not_empty "$(record_for 000000000000 us-east-1)"      "empty region is present"
assert_not_empty "$(record_for 000000000000 eu-west-1)"      "partially-failed region is present"
assert_not_empty "$(record_for 000000000000 ap-southeast-1)" "fully-failed region is present"

status_of() { record_for 000000000000 "$1" | jq -r '.status // "<missing>"'; }
errors_of() { record_for 000000000000 "$1" | jq -r '.errors // [] | length'; }

assert_equals "ok"      "$(status_of us-east-1)"      "genuinely empty region is status=ok"
assert_equals "0"       "$(errors_of us-east-1)"      "empty region records no errors"

assert_equals "partial" "$(status_of eu-west-1)"      "region with one denied call is status=partial"
assert_equals "1"       "$(errors_of eu-west-1)"      "the denied call is recorded as an error"
assert_not_empty "$(record_for 000000000000 eu-west-1 | jq -r '.errors[] | select(test("DescribeVolumes"))')" \
  "the error names the API that was denied"

assert_equals "failed"  "$(status_of ap-southeast-1)" "fully unreachable region is status=failed"

# The operator must be told on stderr too, not just in the file.
assert_stderr_has "ap-southeast-1" "the failed region is reported on stderr"
