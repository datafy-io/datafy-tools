# SAAS-252 — --anonymize-tags.
#
# Some customers will not share their tag values. With the flag, every tag is
# dropped except Datafy's own, and what survives is a handful of derived fields:
# hashed cluster / node group / ASG names, is_k8s, and a fixed managed_by
# category. A volume inherits cluster, node group and ASG from its instance, and
# its own tags override. The real names go to a private mapping file instead.
#
# i-0 is an EKS node in an ASG; v-0 is its volume, but carries its own cluster
# tag (which must win) and a PVC name (which must never be emitted). i-1 carries
# only Datafy's own tags. v-1 is a CSI volume. The snapshot is a Karpenter one.

setup_sandbox

export DATAFY_ANONYMIZE_KEY_FILE="$SANDBOX/anonymize.key"
MAPPING="$OUTPUT_FILE.mapping.private"

scenario <<'JSON'
{ "caller_account": "000000000000",
  "accounts": ["000000000000"],
  "regions":  ["us-east-1"],
  "volumes": 2, "instances": 2, "snapshots": 1, "ami_count": 2,
  "tags": {
    "instances": [
      { "aws:autoscaling:groupName": "asg-secret", "eks:cluster-name": "inst-cluster-secret",
        "eks:nodegroup-name": "ng-secret", "Owner": "bob-secret" },
      { "Managed-By": "Datafy.io", "datafy:policy": "keep", "Terraform": "true-secret" } ],
    "volumes": [
      { "kubernetes.io/cluster/vol-cluster-secret": "owned",
        "kubernetes.io/created-for/pvc/name": "pvc-secret" },
      { "ebs.csi.aws.com/cluster": "true" } ],
    "snapshots": [ { "karpenter.sh/nodepool": "np-secret", "Managed-By": "terraform-secret" } ]
  } }
JSON

run_discovery --anonymize-tags

assert_equals 0 "$DISCOVERY_STATUS" "exits 0"
assert_valid_jsonl "output is valid JSONL"

# ── Nothing sensitive survives ────────────────────────────────────────────────
leaked=$(output_lines | grep -oE '[A-Za-z0-9._-]*(secret|volume-[0-9]|instance-[0-9]|snapshot-[0-9]|env-[0-9])[A-Za-z0-9._-]*' | sort -u | tr '\n' ' ')
assert_empty "$leaked" "no real tag value or Name appears anywhere in the output"

assert_equals 0 "$(output_lines | jq -s '[.[] | select(.record_type == "region")
    | (.volumes[], .instances[]) | select(.Name != null)] | length')" \
  "Name is null on every volume and instance"

non_datafy=$(output_lines | jq -r 'select(.record_type == "region")
    | (.volumes[], .instances[], .snapshots[]) | .Tags[]
    | select((.Key == "Managed-By" and .Value == "Datafy.io" or (.Key | startswith("datafy:"))) | not)
    | .Key')
assert_empty "$non_datafy" "no tag other than Datafy's own is kept"

# ── Derived fields ─────────────────────────────────────────────────────────────
rec=$(record_for 000000000000 us-east-1)
mapped() { jq -r --arg kind "$1" --arg alias "$2" '.[$kind][$alias] // "<unmapped>"' "$MAPPING"; }
vol()  { echo "$rec" | jq -r --argjson n "$1" ".volumes[$1] | $2"; }
inst() { echo "$rec" | jq -r ".instances[$1] | $2"; }
snap() { echo "$rec" | jq -r ".snapshots[$1] | $2"; }

assert_equals "vol-cluster-secret" "$(mapped clusters "$(vol 0 .cluster)")" \
  "a volume's own cluster tag (kubernetes.io/cluster/<name>) wins over its instance's"
assert_equals "ng-secret" "$(mapped node_groups "$(vol 0 .node_group)")" \
  "the volume inherits the node group from its instance"
assert_equals "asg-secret" "$(mapped asgs "$(vol 0 .asg)")" \
  "the volume inherits the ASG from its instance"
assert_equals "true" "$(vol 0 .is_k8s)" "the volume is flagged Kubernetes"

assert_equals "null"  "$(vol 1 .cluster)" "a CSI volume with no cluster tag has no cluster"
assert_equals "true"  "$(vol 1 .is_k8s)"  "a CSI marker tag makes the volume Kubernetes"
assert_equals "null"  "$(vol 1 .managed_by)" "no managed_by when nothing maps to one"

assert_equals "inst-cluster-secret" "$(mapped clusters "$(inst 0 .cluster)")" "instance cluster hashed"
assert_equals "eks-nodegroup" "$(inst 0 .managed_by)" \
  "managed_by is a fixed category (EKS node group wins over ASG), not the tag value"
assert_equals "false" "$(inst 1 .is_k8s)" "an instance with no Kubernetes tags is not flagged"
assert_equals "2" "$(inst 1 '.Tags | length')" "Datafy's own tags are kept as they are"

assert_equals "np-secret" "$(mapped node_groups "$(snap 0 .node_group)")" "snapshot node group hashed"
assert_equals "karpenter" "$(snap 0 .managed_by)" "karpenter.sh/* maps to karpenter"
assert_equals "0" "$(snap 0 '.Tags | length')" "a generic Managed-By tag is dropped"

# A hash is a hash: not the name, not recognisably derived from it.
assert_equals 16 "$(vol 0 .cluster | tr -d '\n' | wc -c | tr -d ' ')" "hashes are 16 hex characters"

# ── The summary, the mapping file and what the operator is told ────────────────
assert_equals '{"tags":true,"accounts":false}' \
  "$(summary_record | jq -c '.anonymization')" "the summary says which options were applied"
assert_equals "000000000000" "$(echo "$rec" | jq -r .account_id)" \
  "account IDs are untouched when only tags are anonymized"

assert_not_empty "$(cat "$MAPPING" 2>/dev/null)" "a mapping file was written next to the output"
assert_equals "-rw-------" "$(ls -l "$MAPPING" | cut -c1-10)" "the mapping file is readable by its owner only"
assert_equals "false" "$(jq 'has("accounts")' "$MAPPING")" "no accounts section when accounts are not anonymized"
assert_log_has "$MAPPING" "the operator is told where the mapping file is"
assert_log_has "do NOT send" "the operator is told not to share it"

# ── Stable across runs ─────────────────────────────────────────────────────────
first=$(vol 0 .cluster)
assert_not_empty "$(cat "$DATAFY_ANONYMIZE_KEY_FILE" 2>/dev/null)" "the key was kept for later runs"
restart_fake
run_discovery_to "$SANDBOX/second.json" --anonymize-tags
second=$(jq -r 'select(.record_type == "region") | .volumes[0].cluster' "$SANDBOX/second.json")
assert_equals "$first" "$second" "the same cluster hashes the same way on a later run"
