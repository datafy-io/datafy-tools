#!/usr/bin/env python3
"""
Datafy Discovery Tool
Inventories EBS volumes, EC2 instances, and backup policies across AWS accounts.
Read-only — safe to run in production.

Usage:
  # Scan using an existing cross-account role (default: OrganizationAccountAccessRole)
  python3 discovery.py

  # Deploy a minimal read-only role via StackSet, scan, then auto-remove it
  python3 discovery.py --setup-role

  # Limit to a specific Organizational Unit
  python3 discovery.py --setup-role --ou ou-xxxx-xxxxxxxx

  # Specific accounts only
  python3 discovery.py --setup-role --include 111111111111,222222222222

  # Skip specific accounts
  python3 discovery.py --exclude 333333333333
"""

import argparse
import json
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError, NoCredentialsError, PartialCredentialsError

# ── Configuration ──────────────────────────────────────────────────────────────
VERSION             = "0.1.0"
DEFAULT_ROLE_NAME   = "OrganizationAccountAccessRole"
DISCOVERY_ROLE_NAME = "DatafyDiscoveryRole"
STACKSET_NAME       = "DatafyDiscovery"
SESSION_NAME        = "DatafyDiscovery"
SESSION_DURATION    = 3600   # seconds — 1 hour
MAX_ACCOUNT_WORKERS = 20     # accounts scanned in parallel
MAX_REGION_WORKERS  = 10     # regions scanned in parallel per account

# ── IAM role template deployed to each child account ──────────────────────────
# Grants only the describe/list permissions this script actually calls.
DISCOVERY_ROLE_TEMPLATE = json.dumps({
    "AWSTemplateFormatVersion": "2010-09-09",
    "Description": (
        "Datafy Discovery Role — minimal read-only role for EBS/EC2 inventory. "
        "Created by discovery.py and auto-deleted after the scan."
    ),
    "Parameters": {
        "ManagementAccountId": {
            "Type": "String",
            "Description": "Management account ID that is allowed to assume this role",
        }
    },
    "Resources": {
        "DatafyDiscoveryRole": {
            "Type": "AWS::IAM::Role",
            "Properties": {
                "RoleName": DISCOVERY_ROLE_NAME,
                "AssumeRolePolicyDocument": {
                    "Version": "2012-10-17",
                    "Statement": [{
                        "Effect": "Allow",
                        "Principal": {
                            "AWS": {"Fn::Sub": "arn:aws:iam::${ManagementAccountId}:root"}
                        },
                        "Action": "sts:AssumeRole",
                    }],
                },
                "Policies": [{
                    "PolicyName": "DatafyDiscovery",
                    "PolicyDocument": {
                        "Version": "2012-10-17",
                        "Statement": [{
                            "Effect": "Allow",
                            "Action": [
                                "ec2:DescribeVolumes",
                                "ec2:DescribeInstances",
                                "ec2:DescribeRegions",
                                "ec2:DescribeImages",
                                "ec2:DescribeSnapshots",
                                "dlm:GetLifecyclePolicies",
                                "backup:ListBackupPlans",
                            ],
                            "Resource": "*",
                        }],
                    },
                }],
            },
        }
    },
})


# ── Utilities ──────────────────────────────────────────────────────────────────

def log(msg):
    print(msg, flush=True)


def paginate(client, method, key, **kwargs):
    """Collect all pages for a paginated boto3 call."""
    results = []
    paginator = client.get_paginator(method)
    for page in paginator.paginate(**kwargs):
        results.extend(page.get(key, []))
    return results


def session_for_account(account_id, role_name, caller_account_id):
    """
    Return a boto3 Session scoped to account_id by assuming role_name.
    Returns None if role assumption fails (account is skipped).
    """
    if account_id == caller_account_id:
        return boto3.Session(profile_name=boto3.DEFAULT_SESSION.profile_name)
    try:
        sts = boto3.client("sts")
        creds = sts.assume_role(
            RoleArn=f"arn:aws:iam::{account_id}:role/{role_name}",
            RoleSessionName=SESSION_NAME,
            DurationSeconds=SESSION_DURATION,
        )["Credentials"]
        return boto3.Session(
            aws_access_key_id=creds["AccessKeyId"],
            aws_secret_access_key=creds["SecretAccessKey"],
            aws_session_token=creds["SessionToken"],
        )
    except ClientError as e:
        log(f"  [skip] {account_id}: cannot assume role — {e.response['Error']['Message']}")
        return None


# ── Per-region scan ────────────────────────────────────────────────────────────

def scan_region(session, account_id, region):
    """Collect all discovery data for one account + region. Returns a dict."""
    ec2 = session.client("ec2", region_name=region)

    # EBS Volumes
    raw_volumes = paginate(ec2, "describe_volumes", "Volumes")
    volumes = [{
        "VolumeId":         v["VolumeId"],
        "Name":             next((t["Value"] for t in v.get("Tags", []) if t["Key"] == "Name"), None),
        "Size":             v["Size"],
        "VolumeType":       v["VolumeType"],
        "State":            v["State"],
        "Iops":             v.get("Iops"),
        "Throughput":       v.get("Throughput"),
        "Encrypted":        v["Encrypted"],
        "AvailabilityZone": v["AvailabilityZone"],
        "SnapshotId":       v.get("SnapshotId"),
        "InstanceId":       v["Attachments"][0]["InstanceId"] if v.get("Attachments") else None,
        "Device":           v["Attachments"][0]["Device"]     if v.get("Attachments") else None,
        "Tags":             v.get("Tags", []),
    } for v in raw_volumes]

    # EC2 Instances
    reservations = paginate(ec2, "describe_instances", "Reservations")
    instances = []
    ami_ids = set()
    for r in reservations:
        for i in r["Instances"]:
            ami_ids.add(i["ImageId"])
            instances.append({
                "InstanceId":       i["InstanceId"],
                "Name":             next((t["Value"] for t in i.get("Tags", []) if t["Key"] == "Name"), None),
                "InstanceType":     i["InstanceType"],
                "State":            i["State"]["Name"],
                "Hypervisor":       i.get("Hypervisor"),
                "PlatformDetails":  i.get("PlatformDetails"),
                "ImageId":          i["ImageId"],
                "AvailabilityZone": i["Placement"]["AvailabilityZone"],
                "RootDeviceName":   i.get("RootDeviceName"),
                "Architecture":     i.get("Architecture"),
                "OwnerId":          r["OwnerId"],
                "Tags":             i.get("Tags", []),
            })

    # AMIs referenced by the instances above
    amis = []
    if ami_ids:
        resp = ec2.describe_images(ImageIds=list(ami_ids))
        amis = [{
            "ImageId":      a["ImageId"],
            "Name":         a.get("Name"),
            "Description":  a.get("Description"),
            "Platform":     a.get("Platform"),
            "Architecture": a.get("Architecture"),
        } for a in resp.get("Images", [])]

    # Snapshots owned by this account
    raw_snapshots = paginate(ec2, "describe_snapshots", "Snapshots", OwnerIds=["self"])
    snapshots = [{
        "SnapshotId": s["SnapshotId"],
        "VolumeId":   s.get("VolumeId"),
        "VolumeSize": s.get("VolumeSize"),
        "StartTime":  s["StartTime"].isoformat(),
        "State":      s["State"],
        "Encrypted":  s["Encrypted"],
        "Tags":       s.get("Tags", []),
    } for s in raw_snapshots]

    # DLM lifecycle policies (nice to have — ignore if region doesn't support it)
    dlm = session.client("dlm", region_name=region)
    try:
        dlm_policies = dlm.get_lifecycle_policies().get("Policies", [])
    except ClientError:
        dlm_policies = []

    # AWS Backup plans (nice to have — ignore if region doesn't support it)
    backup_client = session.client("backup", region_name=region)
    try:
        raw_plans = paginate(backup_client, "list_backup_plans", "BackupPlansList")
        backup_plans = [{
            "BackupPlanId":   b["BackupPlanId"],
            "BackupPlanName": b["BackupPlanName"],
            "CreationDate":   b["CreationDate"].isoformat(),
        } for b in raw_plans]
    except ClientError:
        backup_plans = []

    return {
        "account_id":   account_id,
        "region":       region,
        "scanned_at":   datetime.now(timezone.utc).isoformat(),
        "volumes":      volumes,
        "instances":    instances,
        "amis":         amis,
        "snapshots":    snapshots,
        "dlm_policies": dlm_policies,
        "backup_plans": backup_plans,
    }


# ── Per-account scan ───────────────────────────────────────────────────────────

def scan_account(account_id, role_name, caller_account_id):
    """Assume role in account_id, then scan all its regions in parallel."""
    session = session_for_account(account_id, role_name, caller_account_id)
    if session is None:
        return []

    ec2 = session.client("ec2", region_name="us-east-1")
    regions = [r["RegionName"] for r in ec2.describe_regions()["Regions"]]

    records = []
    with ThreadPoolExecutor(max_workers=MAX_REGION_WORKERS) as pool:
        futures = {pool.submit(scan_region, session, account_id, r): r for r in regions}
        for future in as_completed(futures):
            region = futures[future]
            try:
                records.append(future.result())
            except Exception as e:
                log(f"  [warn] {account_id}/{region}: {e}")
    return records


# ── Account list ───────────────────────────────────────────────────────────────

def list_accounts(ou, include, exclude):
    """Return the list of account IDs to scan."""
    if include:
        return [a for a in include if a not in exclude]
    org = boto3.client("organizations")
    if ou:
        raw = paginate(org, "list_accounts_for_parent", "Accounts", ParentId=ou)
    else:
        raw = paginate(org, "list_accounts", "Accounts")
    return [a["Id"] for a in raw if a["Status"] == "ACTIVE" and a["Id"] not in exclude]


# ── StackSet lifecycle ─────────────────────────────────────────────────────────

def _get_root_ou_id():
    org = boto3.client("organizations")
    return org.list_roots()["Roots"][0]["Id"]


def _stackset_targets(ou, include):
    """Return the DeploymentTargets dict for create/delete stack instances."""
    if include:
        return {"Accounts": include}
    return {"OrganizationalUnitIds": [ou or _get_root_ou_id()]}


def _wait_for_stackset_op(cf, operation_id):
    while True:
        resp = cf.describe_stack_set_operation(
            StackSetName=STACKSET_NAME,
            OperationId=operation_id,
        )
        status = resp["StackSetOperation"]["Status"]
        if status == "SUCCEEDED":
            return
        if status in ("FAILED", "STOPPED"):
            raise RuntimeError(f"StackSet operation ended with status: {status}")
        log("  Waiting for StackSet operation to complete...")
        time.sleep(15)


def deploy_stackset(management_account_id, ou, include):
    """Create StackSet and deploy DatafyDiscoveryRole to all target accounts."""
    cf = boto3.client("cloudformation")

    log(f"Creating StackSet '{STACKSET_NAME}'...")
    try:
        cf.create_stack_set(
            StackSetName=STACKSET_NAME,
            Description=(
                "Datafy Discovery — read-only role for EBS/EC2 inventory. "
                "Created by discovery.py and auto-deleted after the scan."
            ),
            TemplateBody=DISCOVERY_ROLE_TEMPLATE,
            Parameters=[{
                "ParameterKey":   "ManagementAccountId",
                "ParameterValue": management_account_id,
            }],
            Capabilities=["CAPABILITY_NAMED_IAM"],
            PermissionModel="SERVICE_MANAGED",
            AutoDeployment={"Enabled": False},
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "NameAlreadyExistsException":
            log(f"  StackSet '{STACKSET_NAME}' already exists — reusing it.")
        else:
            raise

    log("Deploying role to accounts (this may take a few minutes)...")
    op = cf.create_stack_instances(
        StackSetName=STACKSET_NAME,
        DeploymentTargets=_stackset_targets(ou, include),
        Regions=["us-east-1"],   # IAM is global — one region is enough
        OperationPreferences={
            "MaxConcurrentPercentage":    100,
            "FailureTolerancePercentage": 50,   # tolerate accounts where deployment fails
        },
    )
    _wait_for_stackset_op(cf, op["OperationId"])
    log("Role deployed.")


def teardown_stackset(ou, include):
    """Delete all stack instances then the StackSet itself."""
    cf = boto3.client("cloudformation")
    log(f"Removing StackSet '{STACKSET_NAME}'...")

    try:
        op = cf.delete_stack_instances(
            StackSetName=STACKSET_NAME,
            DeploymentTargets=_stackset_targets(ou, include),
            Regions=["us-east-1"],
            RetainStacks=False,
            OperationPreferences={
                "MaxConcurrentPercentage":    100,
                "FailureTolerancePercentage": 100,
            },
        )
        _wait_for_stackset_op(cf, op["OperationId"])
    except ClientError as e:
        log(f"  [warn] Could not delete stack instances: {e.response['Error']['Message']}")
        log(f"  Please delete StackSet '{STACKSET_NAME}' manually in the CloudFormation console.")
        return

    try:
        cf.delete_stack_set(StackSetName=STACKSET_NAME)
        log("StackSet removed.")
    except ClientError as e:
        log(f"  [warn] Could not delete StackSet: {e.response['Error']['Message']}")
        log(f"  Please delete StackSet '{STACKSET_NAME}' manually in the CloudFormation console.")


# ── Entry point ────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description=(
            f"Datafy Discovery Tool v{VERSION} — inventories EBS volumes and EC2 instances "
            "across AWS accounts. Read-only. Safe to run in production."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--version", action="version", version=f"Datafy Discovery Tool v{VERSION}")
    parser.add_argument(
        "--setup-role", action="store_true",
        help=(
            "Deploy a minimal read-only IAM role to child accounts via CloudFormation StackSet. "
            "The role is automatically removed after the scan completes."
        ),
    )
    parser.add_argument(
        "--role", default=DEFAULT_ROLE_NAME, metavar="ROLE_NAME",
        help=(
            f"IAM role name to assume in child accounts (default: {DEFAULT_ROLE_NAME}). "
            "Ignored when --setup-role is used."
        ),
    )
    parser.add_argument("--ou",      metavar="OU_ID",       help="Limit to this Organizational Unit (ou-xxxx-xxxxxxxx)")
    parser.add_argument("--include", metavar="ID1,ID2,...", help="Comma-separated account IDs to scan (instead of all accounts)")
    parser.add_argument("--exclude", metavar="ID1,ID2,...", help="Comma-separated account IDs to skip")
    parser.add_argument("--output",  metavar="FILE",        help="Output file path (default: discovery_<timestamp>.jsonl)")
    parser.add_argument("--profile", metavar="PROFILE",     help="AWS profile to use (from ~/.aws/config)")
    args = parser.parse_args()

    boto3.setup_default_session(profile_name=args.profile or None)

    include = [a.strip() for a in args.include.split(",")] if args.include else []
    exclude = {a.strip() for a in args.exclude.split(",")} if args.exclude else set()

    try:
        identity = boto3.client("sts").get_caller_identity()
    except (NoCredentialsError, PartialCredentialsError):
        print(
            "Error: no AWS credentials found.\n\n"
            "Configure credentials using one of:\n"
            "  python3 discovery.py --profile my-profile    (AWS named profile)\n"
            "  export AWS_PROFILE=my-profile                (environment variable)\n"
            "  aws configure                                (interactive setup)\n"
            "  export AWS_ACCESS_KEY_ID=...                 (explicit keys)\n"
            "         AWS_SECRET_ACCESS_KEY=...\n"
            "         AWS_SESSION_TOKEN=...                 (if using temporary credentials)\n",
            file=sys.stderr,
        )
        sys.exit(1)

    caller_account_id = identity["Account"]
    log(f"Datafy Discovery Tool v{VERSION}")
    log(f"Running as:          {identity['Arn']}")
    log(f"Management account:  {caller_account_id}")

    role_name = DISCOVERY_ROLE_NAME if args.setup_role else args.role

    if args.setup_role:
        deploy_stackset(caller_account_id, args.ou, include)

    try:
        accounts = list_accounts(args.ou, include, exclude)
        log(f"\nAccounts to scan: {len(accounts)}")

        output_file = args.output or f"discovery_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
        completed = 0
        skipped   = 0
        failed    = 0

        with open(output_file, "w") as out:
            with ThreadPoolExecutor(max_workers=MAX_ACCOUNT_WORKERS) as pool:
                futures = {
                    pool.submit(scan_account, acct, role_name, caller_account_id): acct
                    for acct in accounts
                }
                for future in as_completed(futures):
                    acct = futures[future]
                    try:
                        records = future.result()
                        if not records:
                            skipped += 1
                        else:
                            for record in records:
                                out.write(json.dumps(record) + "\n")
                            completed += 1
                            total_done = completed + skipped + failed
                            log(f"  [{total_done}/{len(accounts)}] {acct} — {len(records)} regions")
                    except Exception as e:
                        failed += 1
                        log(f"  [fail] {acct}: {e}")

        log(f"\nScanned: {completed}  Skipped (no role): {skipped}  Failed: {failed}")
        log(f"Output:  {output_file}")

    finally:
        if args.setup_role:
            teardown_stackset(args.ou, include)


if __name__ == "__main__":
    main()
