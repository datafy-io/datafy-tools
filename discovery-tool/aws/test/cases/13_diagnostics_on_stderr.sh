# The three implementations must agree on where output goes.
#
# The tool has exactly one product — the JSONL file named by --output. Progress,
# warnings and the closing summary are diagnostics about that product, and they
# belong on stderr in all three implementations, for two reasons:
#
#   * an operator who pipes or redirects stdout must still see that accounts
#     were skipped; a run whose problems scroll past into /dev/null is how
#     DT-11095 stayed invisible for so long, and
#   * a wrapper that captures stdout should get nothing but what the tool
#     deliberately prints there — today that is nothing at all.
#
# This case is what keeps the convention from drifting per implementation. The
# org below deliberately contains a problem worth reporting, so there is
# something for the run to say.

setup_sandbox

scenario <<'JSON'
{ "caller_account": "000000000000",
  "accounts": ["000000000000", "111111111111"],
  "regions":  ["us-east-1", "eu-west-1"],
  "volumes": 2, "instances": 1, "snapshots": 1,
  "deny_assume": ["111111111111"],
  "deny": { "000000000000/eu-west-1": ["DescribeVolumes"] } }
JSON

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"

stdout_bytes=$(wc -c < "$STDOUT_FILE" | tr -d ' ')
if [[ "${stdout_bytes:-0}" -eq 0 ]]; then
  _pass "stdout is left clean for the caller"
else
  _fail "stdout is left clean for the caller" \
        "$stdout_bytes byte(s) on stdout, first line: $(head -1 "$STDOUT_FILE")"
fi

stderr_has() {
  if grep -qF -- "$1" "$STDERR_FILE" 2>/dev/null; then
    _pass "$2"
  else
    _fail "$2" "stderr did not mention: $1"
  fi
}

stderr_has "111111111111"  "the skipped account is named on stderr"
stderr_has "eu-west-1"     "the degraded region is named on stderr"
stderr_has "Accounts:"     "the closing account tally is on stderr"
stderr_has "Regions:"      "the closing region tally is on stderr"
stderr_has "$OUTPUT_FILE"  "the operator is told where the results were written"

# The data itself must be in the file and nowhere else — a record on stdout
# would mean two sources of truth.
assert_valid_jsonl "the output file holds the records"
assert_equals 1 "$(count_records '.record_type == "account"')" \
  "the skipped account is recorded in the file, not only on stderr"
