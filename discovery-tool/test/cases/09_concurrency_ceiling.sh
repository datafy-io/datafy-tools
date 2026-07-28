# DT-11095 — the parallelism cap must actually hold.
#
# This tool has already exhausted memory once: the comment in the bash
# implementation's scan_region records that running the per-region API calls in
# parallel "multiplied peak process count by 5x and exhausted RAM". Each
# implementation therefore caps how much it runs at once — Python and Go with
# fixed worker pools, bash with limits sized from available RAM — but nothing
# enforced the resulting cap, so a regression in either throttle would go
# unnoticed until a customer's machine fell over mid-scan.
#
# 25 accounts is deliberately more than any implementation's account cap, so the
# cap is the thing that binds rather than the size of the org. The endpoint
# registers each call while it is in flight, so the peak is observable; every
# call is held briefly, otherwise calls complete faster than they overlap and
# the peak is meaningless.

setup_sandbox

scenario <<'JSON'
{ "caller_account": "000000000000",
  "accounts": ["000000000000", "010000000000", "020000000000", "030000000000",
               "040000000000", "050000000000", "060000000000", "070000000000",
               "080000000000", "090000000000", "100000000000", "110000000000",
               "120000000000", "130000000000", "140000000000", "150000000000",
               "160000000000", "170000000000", "180000000000", "190000000000",
               "200000000000", "210000000000", "220000000000", "230000000000",
               "240000000000"],
  "regions":  ["us-east-1", "eu-west-1"],
  "volumes": 1, "instances": 1, "snapshots": 1,
  "delay_seconds": 0.5 }
JSON

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"

account_cap=$(impl_account_cap)
call_cap=$(impl_call_cap)
peak_accounts=$(fake_stat peak_accounts)
peak_calls=$(fake_stat peak_calls)

assert_at_least 1 "$account_cap" "the implementation's account cap is known (cap = $account_cap)"

# The peak must be real. If nothing ever overlapped, the cap assertions below
# would be vacuous and would pass on a completely serial implementation.
assert_at_least 2 "$peak_accounts" "accounts were genuinely scanned concurrently (peak $peak_accounts)"
assert_at_least 2 "$peak_calls"    "calls were genuinely in flight concurrently (peak $peak_calls)"

assert_at_most "$account_cap" "$peak_accounts" \
  "peak concurrent accounts ($peak_accounts) stayed within the cap of $account_cap"
assert_at_most "$call_cap" "$peak_calls" \
  "peak concurrent calls ($peak_calls) stayed within the cap of $call_cap"

# Throttling must not cost coverage.
assert_equals 50 "$(count_records '.record_type == "region"')" \
  "all 25 accounts x 2 regions were still scanned"
assert_equals 0 "$(count_records '.record_type == "region" and .status != "ok"')" \
  "throttling did not degrade any region"
