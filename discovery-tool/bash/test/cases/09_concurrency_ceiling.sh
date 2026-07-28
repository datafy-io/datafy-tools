# DT-11095 — the parallelism cap must actually hold.
#
# set_job_limits sizes MAX_ACCOUNT_JOBS x MAX_REGION_JOBS from available RAM
# because this tool has already exhausted memory once — the comment in
# scan_region records that running the per-region API calls in parallel
# "multiplied peak process count by 5x and exhausted RAM". Nothing enforced the
# resulting cap, so a regression in either throttle would go unnoticed until a
# customer's machine fell over mid-scan.
#
# The mock registers each inventory call while it is in flight, so the peak is
# observable. Every call is held briefly, otherwise calls complete faster than
# they overlap and the peak is meaningless.

setup_sandbox

export MOCK_CALLER_ACCOUNT="000000000000"
export MOCK_ACCOUNTS="000000000000,111111111111,222222222222,333333333333,444444444444,555555555555,666666666666,777777777777"
export MOCK_REGIONS="us-east-1,us-west-2,eu-west-1,ap-south-1,sa-east-1"
export MOCK_VOLUMES=2
export MOCK_INSTANCES=1
export MOCK_SNAPSHOTS=1
export MOCK_DELAY_SECONDS=1

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "discovery.sh exits 0"

limit=$(job_limit_product)
peak=$(peak_concurrency)

if [[ "${limit:-0}" -gt 0 ]]; then
  _pass "job limits parsed from the tool's own log (cap = $limit concurrent calls)"
else
  _fail "job limits parsed from the tool's own log" "could not read 'N accounts x M regions' from stderr"
fi

# The peak must be real — if nothing ever overlapped the assertion below is
# vacuous and would pass on a completely serial implementation.
if [[ "${peak:-0}" -ge 2 ]]; then
  _pass "calls genuinely ran concurrently (peak $peak)"
else
  _fail "calls genuinely ran concurrently" "peak concurrency was ${peak:-0} — the cap assertion would be vacuous"
fi

if [[ "${limit:-0}" -gt 0 && "${peak:-0}" -le "${limit:-0}" ]]; then
  _pass "peak concurrency $peak stayed within the $limit cap"
else
  _fail "peak concurrency stayed within the cap" "peak $peak exceeded cap $limit"
fi

# Throttling must not cost coverage.
regions=$(output_lines | jq -c 'select(.record_type == "region")' | grep -c . || true)
assert_equals 40 "$regions" "all 8 accounts x 5 regions were still scanned"
