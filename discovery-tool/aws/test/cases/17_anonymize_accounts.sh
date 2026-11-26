# SAAS-252 — --anonymize-accounts.
#
# Every account ID is replaced by a stable alias *everywhere* in the output —
# not just in account_id, but in an instance's OwnerId and in the ARNs AWS puts
# inside error messages. The real IDs go to a private mapping file.
#
#   000000000000  caller, healthy
#   111111111111  eu-west-1 denies DescribeVolumes (the error text names the ARN)
#   222222222222  role cannot be assumed             (the reason text names the ARN)

setup_sandbox

export DATAFY_ANONYMIZE_KEY_FILE="$SANDBOX/anonymize.key"
MAPPING="$OUTPUT_FILE.mapping.private"

scenario <<'JSON'
{ "caller_account": "000000000000",
  "accounts": ["000000000000", "111111111111", "222222222222"],
  "regions":  ["us-east-1", "eu-west-1"],
  "volumes": 2, "instances": 2, "snapshots": 1,
  "deny_assume": ["222222222222"],
  "deny": { "111111111111/eu-west-1": ["DescribeVolumes"] } }
JSON

run_discovery --anonymize-accounts

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_valid_jsonl "output is valid JSONL"

# -w: the fake's 17-digit resource ids are not account IDs, and must not count.
assert_equals 0 "$(output_lines | grep -Ecw '[0-9]{12}' || true)" \
  "no 12-digit account ID appears anywhere in the output"

alias_of() { jq -r --arg real "$1" '.accounts | to_entries[] | select(.value == $real) | .key' "$MAPPING"; }
a0=$(alias_of 000000000000); a1=$(alias_of 111111111111); a2=$(alias_of 222222222222)

assert_not_empty "$a0" "the caller account has an alias in the mapping file"
assert_equals 3 "$(jq '.accounts | length' "$MAPPING")" "the mapping file holds every account"
assert_equals 3 "$(printf '%s\n%s\n%s\n' "$a0" "$a1" "$a2" | sort -u | wc -l | tr -d ' ')" \
  "each account has its own alias"

assert_equals 2 "$(records_for_account "$a0")" "an account's records all carry the same alias"
assert_equals "$a0" "$(record_for "$a0" us-east-1 | jq -r '.instances[0].OwnerId')" \
  "an instance's OwnerId carries the alias too"
assert_contains() { if [[ "$2" == *"$1"* ]]; then _pass "$3"; else _fail "$3" "[$2] does not contain [$1]"; fi; }
assert_contains "$a1" "$(record_for "$a1" eu-west-1 | jq -r '.errors | join(" ")')" \
  "an account ID inside an AWS error message is aliased"
assert_contains "$a2" "$(account_record "$a2" | jq -r '.reason')" \
  "an account ID inside a skip reason is aliased"
assert_equals "skipped" "$(account_record "$a2" | jq -r '.status')" "the skipped account is still reported as skipped"

# Only accounts are touched.
assert_equals "volume-0" "$(record_for "$a0" us-east-1 | jq -r '.volumes[0].Name')" \
  "tags and names are untouched when only accounts are anonymized"
assert_equals "false" "$(record_for "$a0" us-east-1 | jq '.volumes[0] | has("is_k8s")')" \
  "no tag-derived fields without --anonymize-tags"
assert_equals '{"tags":false,"accounts":true}' \
  "$(summary_record | jq -c '.anonymization')" "the summary says which options were applied"
assert_equals 3 "$(summary_record | jq -r '.accounts_total')" "coverage numbers are unaffected"
assert_equals 1 "$(summary_record | jq -r '.accounts_skipped')" "skipped accounts still counted"
assert_equals "false" "$(jq 'has("clusters")' "$MAPPING")" "no tag sections when tags are not anonymized"
assert_equals "-rw-------" "$(ls -l "$MAPPING" | cut -c1-10)" "the mapping file is readable by its owner only"
assert_log_has "do NOT send" "the operator is told not to share the mapping file"

# Stable across runs.
restart_fake
run_discovery_to "$SANDBOX/second.json" --anonymize-accounts
assert_equals "$a0" "$(jq -r 'select(.record_type == "region") | .account_id' "$SANDBOX/second.json" | sort -u | grep -F "$a0")" \
  "an account gets the same alias on a later run"
