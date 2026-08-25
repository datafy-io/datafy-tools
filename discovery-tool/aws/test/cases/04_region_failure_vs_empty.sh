# DT-11095 — "Clear differentiation between regions that were empty and those
# that were skipped."
#
# Every AWS call used to be `2>/dev/null || echo "[]"`, so a region that denied
# ec2:DescribeVolumes was indistinguishable from a region that genuinely held no
# volumes: both emitted "volumes": []. The customer only discovered the gap by
# diffing against an older run.
#
# Every region here is genuinely empty. eu-west-1 additionally denies
# DescribeVolumes, and ap-southeast-1 denies everything.

setup_sandbox

scenario <<'JSON'
{ "caller_account": "000000000000",
  "accounts": ["000000000000"],
  "regions":  ["us-east-1", "eu-west-1", "ap-southeast-1"],
  "volumes": 0, "instances": 0, "snapshots": 0,
  "deny": {
    "000000000000/eu-west-1":      ["DescribeVolumes"],
    "000000000000/ap-southeast-1": ["*"]
  } }
JSON

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "exits 0 despite unreachable regions"
assert_valid_jsonl "output is valid JSONL"

# All three regions must be represented — a failing region must not vanish.
assert_not_empty "$(record_for 000000000000 us-east-1)"      "the empty region is present"
assert_not_empty "$(record_for 000000000000 eu-west-1)"      "the partially-failed region is present"
assert_not_empty "$(record_for 000000000000 ap-southeast-1)" "the fully-failed region is present"

status_of() { record_for 000000000000 "$1" | jq -r '.status // "<missing>"'; }
errors_of() { record_for 000000000000 "$1" | jq -r '.errors // [] | length'; }

assert_equals "ok"      "$(status_of us-east-1)" "a genuinely empty region is status=ok"
assert_equals "0"       "$(errors_of us-east-1)" "an empty region records no errors"

assert_equals "partial" "$(status_of eu-west-1)" "a region with one denied call is status=partial"
assert_equals "1"       "$(errors_of eu-west-1)" "the denied call is recorded as an error"
assert_not_empty "$(record_for 000000000000 eu-west-1 | jq -r '.errors[] | select(test("DescribeVolumes"))')" \
  "the error names the API that was denied"
assert_not_empty "$(record_for 000000000000 eu-west-1 | jq -r '.errors[] | select(test("UnauthorizedOperation"))')" \
  "the error carries the AWS error code, so the operator knows to fix IAM"

assert_equals "failed"  "$(status_of ap-southeast-1)" "a fully unreachable region is status=failed"
assert_at_least 1 "$(errors_of ap-southeast-1)"       "the unreachable region explains itself"

# The operator must be told while the run is happening, not only in the file.
assert_log_has "ap-southeast-1" "the failed region is named in the progress output"
