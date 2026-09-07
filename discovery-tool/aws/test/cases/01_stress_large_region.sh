# DT-11095 — a single busy region must survive assembly intact.
#
# The bash implementation used to build its record by passing every transformed
# array to jq as a command-line argument (--argjson volumes "$volumes" ...). A
# single busy region produces megabytes of JSON, which exceeds the kernel's exec
# argument limit (~1MB total on macOS, 128KB per argument on Linux), so jq was
# never executed. The failure was swallowed by the region subshell, so the
# region vanished from the output with no error recorded — which is exactly how
# entire regions went missing from the customer's run.
#
# The cause was bash-specific; the contract is not. No implementation may lose
# data because a region is large, and none may report a region it failed to
# assemble as though it were simply empty.
#
# 4000 volumes is ~2.4MB of transformed JSON, comfortably over both limits.

setup_sandbox

scenario <<'JSON'
{ "caller_account": "000000000000",
  "accounts": ["000000000000"],
  "regions":  ["us-east-1"],
  "volumes": 4000, "instances": 50, "snapshots": 2000, "ami_count": 10 }
JSON

run_discovery

assert_log_lacks "Argument list too long" "no argument-list overflow assembling the record"
assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_valid_jsonl "output is valid JSONL"

assert_not_empty "$(record_for 000000000000 us-east-1)" "the large region still produced a record"
assert_equals "ok" "$(record_for 000000000000 us-east-1 | jq -r '.status')" \
  "the large region is status=ok"

assert_equals 4000 "$(total_len volumes)"   "all 4000 volumes survived assembly"
assert_equals 50   "$(total_len instances)" "all 50 instances survived assembly"
assert_equals 2000 "$(total_len snapshots)" "all 2000 snapshots survived assembly"

# Ids must be distinct — a truncated or repeated batch would still total 4000.
distinct=$(output_lines | jq -r '.volumes[]?.VolumeId' | sort -u | grep -c . || true)
assert_equals 4000 "$distinct" "every volume id is distinct"
