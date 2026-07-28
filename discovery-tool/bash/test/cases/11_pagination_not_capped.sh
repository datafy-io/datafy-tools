# DT-11095 — result sets must never be silently truncated.
#
# A caveat about what this case can and cannot prove. The bash implementation
# relies on AWS CLI v2 auto-pagination: it issues one `aws ec2 describe-volumes`
# and trusts the CLI to walk every page. Our mock *is* the CLI, so it cannot
# exercise that behaviour — testing it would mean testing AWS's own client.
#
# What is worth guarding is the thing we control: nothing in discovery.sh may
# disable or cap pagination. `--no-paginate`, `--max-items` and `--page-size`
# all silently return a prefix of the data, which would look exactly like a
# small account rather than a truncated scan — the failure mode this whole
# ticket is about.
#
# Genuine multi-page coverage for the Python and Go clients lives in the
# parity harness, where the SDK paginators are real.

setup_sandbox

for flag in --no-paginate --max-items --page-size --starting-token; do
  if grep -q -- "$flag" "$DISCOVERY_SH"; then
    _fail "discovery.sh does not use $flag" \
          "$(grep -n -- "$flag" "$DISCOVERY_SH" | head -1)"
  else
    _pass "discovery.sh does not use $flag"
  fi
done

# Every inventory call must go through fetch_json, which is what records a
# failure. A bare `aws ec2 describe-...` would reintroduce the silent fallback.
stray=$(grep -nE '^[[:space:]]*aws (ec2|dlm|backup) ' "$DISCOVERY_SH" | grep -v 'describe-regions' || true)
if [[ -z "$stray" ]]; then
  _pass "every inventory call goes through fetch_json"
else
  _fail "every inventory call goes through fetch_json" "$stray"
fi

# And a result set larger than any single API page still arrives whole.
export MOCK_CALLER_ACCOUNT="000000000000"
export MOCK_ACCOUNTS="000000000000"
export MOCK_REGIONS="us-east-1"
export MOCK_VOLUMES=2500
export MOCK_INSTANCES=1200
export MOCK_SNAPSHOTS=1800

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "discovery.sh exits 0"
assert_equals "ok" "$(record_for 000000000000 us-east-1 | jq -r '.status')" "the region is status=ok"
assert_equals 2500 "$(total_len volumes)"   "all 2500 volumes arrived"
assert_equals 1200 "$(total_len instances)" "all 1200 instances arrived"
assert_equals 1800 "$(total_len snapshots)" "all 1800 snapshots arrived"
