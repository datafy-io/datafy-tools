# DT-11095 — result sets must never be silently truncated.
#
# A region holding more resources than fit in one API page is the most ordinary
# way to end up with a partial answer that looks complete. Every implementation
# handles this differently: bash relies on AWS CLI v2 auto-pagination, Python on
# a boto3 paginator, Go on the SDK's paginator types. All three are real here —
# the endpoint returns genuine multi-page responses with a nextToken — so this
# exercises each client's pagination rather than trusting it.
#
# 2500 volumes at 100 per page is 25 pages; an implementation that reads only
# the first page reports 100 volumes and calls the region status=ok, which is
# exactly the failure this ticket is about.

setup_sandbox

scenario <<'JSON'
{ "caller_account": "000000000000",
  "accounts": ["000000000000"],
  "regions":  ["us-east-1"],
  "volumes": 2500, "instances": 1200, "snapshots": 1800, "ami_count": 50,
  "page_size": 100 }
JSON

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_valid_jsonl "output is valid JSONL"
assert_equals "ok" "$(record_for 000000000000 us-east-1 | jq -r '.status')" "the region is status=ok"

assert_equals 2500 "$(total_len volumes)"   "all 2500 volumes arrived, across 25 pages"
assert_equals 1200 "$(total_len instances)" "all 1200 instances arrived, across 12 pages"
assert_equals 1800 "$(total_len snapshots)" "all 1800 snapshots arrived, across 18 pages"

# Pages must not overlap or repeat — a paginator that re-sends the same token
# still totals the right number if it also drops a page.
distinct=$(output_lines | jq -r '.volumes[]?.VolumeId' | sort -u | grep -c . || true)
assert_equals 2500 "$distinct" "every volume id is distinct across pages"

# And the pages were genuinely fetched one by one, rather than the endpoint
# having quietly served everything at once: 25 + 12 + 18 page requests, plus the
# AMI, DLM and Backup calls.
assert_at_least 50 "$(fake_stat data_calls)" \
  "the result sets were fetched page by page ($(fake_stat data_calls) calls)"
