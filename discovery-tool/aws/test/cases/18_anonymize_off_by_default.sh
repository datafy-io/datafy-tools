# SAAS-252 — without the flags the output is exactly what it always was: real
# tags, real account IDs, no derived fields, no mapping file, nothing added to
# the summary. And --help documents both flags.

setup_sandbox

export DATAFY_ANONYMIZE_KEY_FILE="$SANDBOX/anonymize.key"

scenario <<'JSON'
{ "caller_account": "000000000000",
  "accounts": ["000000000000"],
  "regions":  ["us-east-1"],
  "volumes": 1, "instances": 1, "snapshots": 1,
  "tags": { "volumes": [ { "eks:cluster-name": "prod" } ] } }
JSON

run_discovery

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
rec=$(record_for 000000000000 us-east-1)
assert_equals "000000000000" "$(echo "$rec" | jq -r .account_id)" "the account ID is the real one"
assert_equals "volume-0" "$(echo "$rec" | jq -r '.volumes[0].Name')" "Name is kept"
assert_equals "prod" "$(echo "$rec" | jq -r '.volumes[0].Tags[] | select(.Key == "eks:cluster-name") | .Value')" \
  "tags are kept"
assert_equals "false" "$(echo "$rec" | jq '.volumes[0] | has("cluster") or has("is_k8s") or has("managed_by")')" \
  "no anonymization fields are added"
assert_equals "false" "$(summary_record | jq 'has("anonymization")')" "the summary has no anonymization field"
assert_equals "no" "$([[ -e "$OUTPUT_FILE.mapping.private" ]] && echo yes || echo no)" "no mapping file is written"
assert_equals "no" "$([[ -e "$DATAFY_ANONYMIZE_KEY_FILE" ]] && echo yes || echo no)" "no key is generated"

# --help lists both flags, each with an explanation.
start_fake
case "$IMPL" in
  bash)   help_out=$(bash "$REPO_ROOT/bash/discovery.sh" --help 2>&1) ;;
  python) help_out=$(python3 "$REPO_ROOT/python/discovery.py" --help 2>&1) ;;
  go)     help_out=$("$DISCOVERY_GO_BIN" --help 2>&1) ;;
esac
assert_at_least 1 "$(echo "$help_out" | grep -c -- '-anonymize-tags')" "--help lists --anonymize-tags"
assert_at_least 1 "$(echo "$help_out" | grep -c -- '-anonymize-accounts')" "--help lists --anonymize-accounts"
assert_not_empty "$(echo "$help_out" | grep -i 'tag' | grep -i 'drop')" "--anonymize-tags is explained"
assert_not_empty "$(echo "$help_out" | grep -i 'alias')" "--anonymize-accounts is explained"
