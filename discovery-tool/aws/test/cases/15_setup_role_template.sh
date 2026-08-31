# DT-11548 — the role template --setup-role deploys granted two actions on
# resource ARNs that AWS does not support resource-level permissions for:
#
#   dlm:GetLifecyclePolicies    scoped to arn:aws:dlm:*:*:policy/*
#   backup:ListBackupPlans      scoped to arn:aws:backup:*:*:backup-plan:*
#
# Neither is a tighter grant. Both are grants that never match, so both calls
# failed on every account, on every run using --setup-role. Nothing crashed —
# attempt() caught each failure per call — so every region record simply carried
# an empty dlm_policies / backup_plans list and an error string, and backup
# coverage came back empty for the whole org.
#
# It reached a customer because the template is a static document that nothing
# ever inspected: --setup-role had no test at all, and reading the template
# required reading the source. --print-role-template makes it inspectable, and
# this case reads it back.

setup_sandbox

# No AWS is contacted for any of this — the template is embedded in the tool.
template="$SANDBOX/role-template.json"
run_role_template() {
  local argv; argv="$(_discovery_argv)"
  local IFS='|'
  # shellcheck disable=SC2086
  ${argv} --print-role-template >"$template" 2>"$STDERR_FILE"
}
run_role_template
status=$?

assert_equals 0 "$status" "--print-role-template exits 0"
assert_empty "$(cat "$STDERR_FILE")" "it writes nothing to stderr"

if jq -e . "$template" >/dev/null 2>&1; then
  _pass "the template is valid JSON"
else
  _fail "the template is valid JSON" "$(head -3 "$template")"
fi

# The template has to be a CloudFormation document that creates the role the
# tool then assumes — asserted here so the flag cannot start printing something
# else and still pass.
assert_equals "2010-09-09" "$(jq -r '.AWSTemplateFormatVersion' "$template")" \
  "it is a CloudFormation template"
assert_equals "AWS::IAM::Role" "$(jq -r '.Resources.DatafyDiscoveryRole.Type' "$template")" \
  "it creates an IAM role"
assert_equals "DatafyDiscoveryRole" "$(jq -r '.Resources.DatafyDiscoveryRole.Properties.RoleName' "$template")" \
  "named the one --setup-role assumes"

statements() {
  jq -c '.Resources.DatafyDiscoveryRole.Properties.Policies[0].PolicyDocument.Statement[]' "$template"
}

# resource_for ACTION — the Resource element of the statement granting ACTION.
resource_for() {
  statements | jq -r --arg a "$1" \
    'select([.Action] | flatten | index($a)) | .Resource' 2>/dev/null
}

# The two the bug was about.
assert_equals "*" "$(resource_for dlm:GetLifecyclePolicies)" \
  "dlm:GetLifecyclePolicies is granted on * — it supports no resource type"
assert_equals "*" "$(resource_for backup:ListBackupPlans)" \
  "backup:ListBackupPlans is granted on * — it supports no resource type"

# And every other action the tool calls, so the same mistake cannot be made
# again one action over. All of these are List/Describe actions for which AWS
# defines no resource type.
for action in ec2:DescribeVolumes ec2:DescribeInstances ec2:DescribeRegions \
              ec2:DescribeImages ec2:DescribeSnapshots; do
  assert_equals "*" "$(resource_for "$action")" "$action is granted on *"
done

# Stated as a property rather than action by action, so an action added later is
# covered too: nothing in this template may be scoped to an ARN.
scoped=$(statements | jq -r 'select(.Resource | type == "string" and startswith("arn:")) | .Sid' | tr '\n' ' ')
assert_empty "$scoped" \
  "no statement is scoped to an ARN pattern — every action here supports only Resource: *"

# The role has to be assumable by the management account, or the scan cannot use
# it whatever its permissions say.
assert_equals "sts:AssumeRole" \
  "$(jq -r '.Resources.DatafyDiscoveryRole.Properties.AssumeRolePolicyDocument.Statement[0].Action' "$template")" \
  "the role trusts the management account to assume it"
assert_not_empty \
  "$(jq -r '.Resources.DatafyDiscoveryRole.Properties.AssumeRolePolicyDocument.Statement[0].Principal.AWS["Fn::Sub"] // empty' "$template")" \
  "and names it through the ManagementAccountId parameter"

# The grant must stay minimal: this template is deployed into a customer's
# accounts, so a wildcard action would be a real finding in their review.
wildcards=$(statements | jq -r '[.Action] | flatten | .[] | select(test("[*]"))' | tr '\n' ' ')
assert_empty "$wildcards" "no statement grants a wildcard action"

writes=$(statements | jq -r '[.Action] | flatten | .[]
  | select(test("^(ec2|dlm|backup):(Describe|Get|List)") | not)' | tr '\n' ' ')
assert_empty "$writes" "every action is a Describe, Get or List — the role is read-only"

# Printing the template must not have started a scan or written an output file.
assert_equals 0 "$(fake_stat data_calls)" "no AWS call was made"
