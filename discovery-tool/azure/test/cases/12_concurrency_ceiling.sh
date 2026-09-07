# The tool pins how much it may have in flight: 20 subscriptions, and 8 ARM
# calls within each. Both are ceilings a customer's ARM read quota is sized
# against, so a change to either should be a deliberate one that fails here
# first.

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
  "disks": 2, "vms": 1, "snapshots": 1, "images": 1, "scale_sets": 1, "vaults": 1,
  "delay_ms": 60 }
JSON

peak_before=$(fake_stat peak_concurrent)
run_discovery
peak=$(fake_stat peak_concurrent)

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_equals 30 "$(count_records '.record_type == "subscription"')" "all 30 subscriptions were scanned"

assert_at_most "$(impl_call_cap)" "$peak" \
  "peak in-flight ARM calls stayed within the documented ceiling"

# And it really did run in parallel — a serial implementation would peak at 1
# and pass the ceiling assertion above for the wrong reason.
assert_at_least 5 "$peak" "the scan actually ran in parallel"
assert_equals 0 "$peak_before" "the ceiling was measured over this run only"
