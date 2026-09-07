# A tenant-wide scan is long enough to be Ctrl+C'd or killed by a timeout, and
# whatever it had already collected is worth keeping. Three things have to hold:
# the collected records survive, the subscriptions that never ran are still
# named in the file, and the exit status says the run was interrupted — exiting
# 0 would claim coverage the scan never had.

setup_sandbox

scenario <<'JSON'
{ "subscriptions": [
    "s0000000-0000-0000-0000-000000000000", "s0000000-0000-0000-0000-000000000001",
    "s0000000-0000-0000-0000-000000000002", "s0000000-0000-0000-0000-000000000003",
    "s0000000-0000-0000-0000-000000000004", "s0000000-0000-0000-0000-000000000005",
    "s0000000-0000-0000-0000-000000000006", "s0000000-0000-0000-0000-000000000007",
    "s0000000-0000-0000-0000-000000000008", "s0000000-0000-0000-0000-000000000009",
    "s0000000-0000-0000-0000-000000000010", "s0000000-0000-0000-0000-000000000011",
    "s0000000-0000-0000-0000-000000000012", "s0000000-0000-0000-0000-000000000013",
    "s0000000-0000-0000-0000-000000000014", "s0000000-0000-0000-0000-000000000015",
    "s0000000-0000-0000-0000-000000000016", "s0000000-0000-0000-0000-000000000017",
    "s0000000-0000-0000-0000-000000000018", "s0000000-0000-0000-0000-000000000019",
    "s0000000-0000-0000-0000-000000000020", "s0000000-0000-0000-0000-000000000021",
    "s0000000-0000-0000-0000-000000000022", "s0000000-0000-0000-0000-000000000023",
    "s0000000-0000-0000-0000-000000000024", "s0000000-0000-0000-0000-000000000025",
    "s0000000-0000-0000-0000-000000000026", "s0000000-0000-0000-0000-000000000027",
    "s0000000-0000-0000-0000-000000000028", "s0000000-0000-0000-0000-000000000029"
  ],
  "disks": 3, "vms": 2, "delay_ms": 120 }
JSON

run_discovery_bg
wait_for_subscriptions 1 30 || _fail "at least one subscription finished before the interrupt" \
  "$(tail -3 "$STDERR_FILE")"
interrupt_discovery TERM
wait_for_discovery 90

assert_equals "$(impl_interrupt_status)" "$DISCOVERY_STATUS" \
  "an interrupted run exits 128+SIGTERM, so a wrapper can tell it apart from a clean one"
assert_valid_jsonl "the partial output is still valid JSONL"

assert_log_has "Interrupted" "the operator is told the run was interrupted"

assert_equals "true" "$(summary_record | jq -r '.interrupted')" \
  "the summary marks the run interrupted, so the file is not read as full coverage"
assert_equals "summary" "$(output_lines | tail -1 | jq -r '.record_type')" \
  "the summary is still the last line"

# What was collected before the interrupt is kept.
assert_at_least 1 "$(count_records '.record_type == "subscription" and .status == "ok"')" \
  "subscriptions that finished keep their data"
assert_at_least 1 "$(total_len disks)" "the disks collected before the interrupt survive"

# And every subscription in scope is still named, so the gap is visible in the
# file rather than only in the tallies.
assert_equals 30 "$(count_records '.record_type == "subscription"')" \
  "every subscription in scope appears in the file"
assert_equals 30 "$(output_lines | jq -r 'select(.record_type=="subscription") | .subscription_id' | sort -u | wc -l | tr -d " ")" \
  "each appears exactly once — none duplicated by the interrupt path"
assert_at_least 1 "$(count_records '.record_type == "subscription" and ((.reason // "") | test("interrupted"))')" \
  "subscriptions that never ran say so"
assert_equals 30 "$(summary_record | jq -r '.subscriptions_total')" "the summary still counts the full scope"
