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
import signal
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError, NoCredentialsError, PartialCredentialsError

# ── Configuration ──────────────────────────────────────────────────────────────
VERSION             = "0.2.0"
DEFAULT_ROLE_NAME   = "OrganizationAccountAccessRole"
DISCOVERY_ROLE_NAME = "DatafyDiscoveryRole"
STACKSET_NAME       = "DatafyDiscovery"
SESSION_NAME        = "DatafyDiscovery"
SESSION_DURATION    = 3600   # seconds — 1 hour
MAX_ACCOUNT_WORKERS = 20     # accounts scanned in parallel
MAX_REGION_WORKERS  = 10     # regions scanned in parallel per account
AMI_BATCH_SIZE      = 100    # DescribeImages rejects unbounded ImageIds lists
MAX_ERROR_CHARS     = 400    # keep error strings readable in the output file

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
                        "Statement": [
                            {
                                "Sid": "EC2DescribeReadOnly",
                                "Effect": "Allow",
                                "Resource": "*",
                                "Action": [
                                    "ec2:DescribeVolumes",
                                    "ec2:DescribeInstances",
                                    "ec2:DescribeRegions",
                                    "ec2:DescribeImages",
                                    "ec2:DescribeSnapshots",
                                ],
                            },
                            {
                                "Sid": "DLMPoliciesReadOnly",
                                "Effect": "Allow",
                                "Resource": "arn:aws:dlm:*:*:policy/*",
                                "Action": ["dlm:GetLifecyclePolicies"],
                            },
                            {
                                "Sid": "BackupPlansReadOnly",
                                "Effect": "Allow",
                                "Resource": "arn:aws:backup:*:*:backup-plan:*",
                                "Action": ["backup:ListBackupPlans"],
                            },
                        ],
                    },
                }],
            },
        }
    },
})


# ── Utilities ──────────────────────────────────────────────────────────────────

def log(msg):
    """Progress and diagnostics, on stderr.

    The tool has one product — the JSONL file named by --output — and stdout is
    left clean for the caller. An operator who redirects stdout must still see
    that accounts were skipped; problems scrolling into /dev/null is part of how
    DT-11095 stayed invisible. bash and Go do the same.
    """
    print(msg, file=sys.stderr, flush=True)


def paginate(client, method, key, **kwargs):
    """Collect all pages for a paginated boto3 call."""
    results = []
    paginator = client.get_paginator(method)
    for page in paginator.paginate(**kwargs):
        results.extend(page.get(key, []))
    return results


def now_utc():
    return iso_z(datetime.now(timezone.utc))


def iso_z(dt):
    """RFC3339 in UTC with a Z suffix.

    isoformat() renders "+00:00", which the Go SDK does not — the parity
    harness catches the mismatch. Z is what the README documents.
    """
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def condense(exc):
    """Squash an exception into one short line fit for a JSON field."""
    if isinstance(exc, ClientError):
        err = exc.response.get("Error", {})
        text = f"{err.get('Code', 'Error')}: {err.get('Message', str(exc))}"
    else:
        text = f"{type(exc).__name__}: {exc}"
    return " ".join(text.split())[:MAX_ERROR_CHARS]


def chunked(items, size):
    for i in range(0, len(items), size):
        yield items[i:i + size]


def account_record(account_id, status, reason):
    """
    An account that was never scanned. Without this the account leaves no trace
    in the file the customer sends us — only in stdout, which is not part of
    what gets shared. (DT-11095)
    """
    return {
        "record_type": "account",
        "account_id":  account_id,
        "status":      status,
        "reason":      reason,
        "scanned_at":  now_utc(),
    }


def session_for_account(account_id, role_name, caller_account_id):
    """
    Return a boto3 Session scoped to account_id by assuming role_name.
    Raises on failure so the caller can record why the account was skipped.
    """
    if account_id == caller_account_id:
        return boto3.Session(profile_name=boto3.DEFAULT_SESSION.profile_name)
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


# ── Per-region scan ────────────────────────────────────────────────────────────

def scan_region(session, account_id, region):
    """
    Collect all discovery data for one account + region. Always returns a dict.

    Each AWS call is attempted independently and its failure recorded, so the
    record can distinguish a region that is genuinely empty from one that was
    denied or unreachable. Previously any failure raised out of this function
    and the region silently disappeared from the output. (DT-11095)
    """
    errors = []
    stats  = {"calls": 0, "failures": 0}

    def attempt(api, fn, default):
        stats["calls"] += 1
        try:
            return fn()
        except Exception as e:                       # noqa: BLE001 — any failure must be reported
            stats["failures"] += 1
            errors.append(f"{api}: {condense(e)}")
            return default

    ec2 = session.client("ec2", region_name=region)

    # EBS Volumes
    raw_volumes = attempt(
        "ec2:DescribeVolumes",
        lambda: paginate(ec2, "describe_volumes", "Volumes"),
        [],
    )
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
    reservations = attempt(
        "ec2:DescribeInstances",
        lambda: paginate(ec2, "describe_instances", "Reservations"),
        [],
    )
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

    # AMIs referenced by the instances above. Looked up in batches: DescribeImages
    # rejects a request carrying every AMI id in a large region.
    amis = []
    if ami_ids:
        def fetch_amis():
            found = []
            for batch in chunked(sorted(ami_ids), AMI_BATCH_SIZE):
                resp = ec2.describe_images(ImageIds=batch)
                found.extend(resp.get("Images", []))
            return found

        amis = [{
            "ImageId":      a["ImageId"],
            "Name":         a.get("Name"),
            "Description":  a.get("Description"),
            "Platform":     a.get("Platform") or "",
            "Architecture": a.get("Architecture"),
        } for a in attempt("ec2:DescribeImages", fetch_amis, [])]

    # Snapshots owned by this account
    raw_snapshots = attempt(
        "ec2:DescribeSnapshots",
        lambda: paginate(ec2, "describe_snapshots", "Snapshots", OwnerIds=["self"]),
        [],
    )
    snapshots = [{
        "SnapshotId": s["SnapshotId"],
        "VolumeId":   s.get("VolumeId"),
        "VolumeSize": s.get("VolumeSize"),
        "StartTime":  iso_z(s["StartTime"]),
        "State":      s["State"],
        "Encrypted":  s["Encrypted"],
        "Tags":       s.get("Tags", []),
    } for s in raw_snapshots]

    # DLM lifecycle policies
    dlm = session.client("dlm", region_name=region)
    dlm_policies = attempt(
        "dlm:GetLifecyclePolicies",
        lambda: dlm.get_lifecycle_policies().get("Policies", []),
        [],
    )

    # AWS Backup plans
    backup_client = session.client("backup", region_name=region)
    raw_plans = attempt(
        "backup:ListBackupPlans",
        lambda: paginate(backup_client, "list_backup_plans", "BackupPlansList"),
        [],
    )
    backup_plans = [{
        "BackupPlanId":   b["BackupPlanId"],
        "BackupPlanName": b["BackupPlanName"],
        "CreationDate":   iso_z(b["CreationDate"]),
    } for b in raw_plans]

    if stats["failures"] == 0:
        status = "ok"
    elif stats["failures"] >= stats["calls"]:
        status = "failed"
    else:
        status = "partial"

    return {
        "record_type":  "region",
        "account_id":   account_id,
        "region":       region,
        "status":       status,
        "scanned_at":   now_utc(),
        "errors":       sorted(set(errors)),
        "volumes":      volumes,
        "instances":    instances,
        "amis":         amis,
        "snapshots":    snapshots,
        "dlm_policies": dlm_policies,
        "backup_plans": backup_plans,
    }


# ── Per-account scan ───────────────────────────────────────────────────────────

def scan_account(account_id, role_name, caller_account_id):
    """
    Assume role in account_id, then scan all its regions in parallel.

    Always returns a non-empty list of records. An account or region that could
    not be scanned is represented by a record explaining why, rather than being
    dropped from the output. (DT-11095)
    """
    try:
        session = session_for_account(account_id, role_name, caller_account_id)
    except Exception as e:                           # noqa: BLE001
        reason = f"cannot assume role {role_name}: {condense(e)}"
        log(f"  [skip] {account_id}: {reason}")
        return [account_record(account_id, "skipped", reason)]

    try:
        ec2 = session.client("ec2", region_name="us-east-1")
        regions = [r["RegionName"] for r in ec2.describe_regions()["Regions"]]
    except Exception as e:                           # noqa: BLE001
        reason = f"cannot list regions: {condense(e)}"
        log(f"  [fail] {account_id}: {reason}")
        return [account_record(account_id, "failed", reason)]

    if not regions:
        reason = "ec2:DescribeRegions returned no enabled regions"
        log(f"  [fail] {account_id}: {reason}")
        return [account_record(account_id, "failed", reason)]

    records = []
    with ThreadPoolExecutor(max_workers=MAX_REGION_WORKERS) as pool:
        futures = {pool.submit(scan_region, session, account_id, r): r for r in regions}
        for future in as_completed(futures):
            region = futures[future]
            try:
                records.append(future.result())
            except Exception as e:                   # noqa: BLE001
                log(f"  [warn] {account_id}/{region}: {e}")
                records.append({
                    "record_type":  "region",
                    "account_id":   account_id,
                    "region":       region,
                    "status":       "failed",
                    "scanned_at":   now_utc(),
                    "errors":       [f"region scan failed unexpectedly: {condense(e)}"],
                    "volumes":      [],
                    "instances":    [],
                    "amis":         [],
                    "snapshots":    [],
                    "dlm_policies": [],
                    "backup_plans": [],
                })

    failed  = [r["region"] for r in records if r["status"] == "failed"]
    partial = [r["region"] for r in records if r["status"] == "partial"]
    if partial:
        log(f"         {account_id} partial: {' '.join(sorted(partial))}")
    if failed:
        log(f"         {account_id} failed:  {' '.join(sorted(failed))}")
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

    # Route SIGTERM through the same path as Ctrl+C, so a run killed by a
    # timeout or a supervisor still writes out what it has collected.
    #
    # Which signal arrived is remembered so the process can exit 128+signal the
    # way bash and Go do. A supervising script has to be able to tell an
    # interrupted run from a clean one; exiting 0 after an interrupt claims the
    # scan covered the whole org when it did not. (DT-11095)
    interrupt_signal = [signal.SIGINT]

    def _on_sigterm(signum, _frame):
        interrupt_signal[0] = signum
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, _on_sigterm)

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
        tally = {
            "accounts_skipped": 0,
            "accounts_failed":  0,
            "regions_scanned":  0,
            "regions_partial":  0,
            "regions_failed":   0,
        }
        done = 0
        interrupted = False

        # Checked up front — a scan that cannot write its results is worth
        # failing immediately, not after an hour of API calls. The message has
        # to name the path: an unhandled OSError tells the operator the tool
        # broke, not that their --output argument is wrong.
        try:
            out_file = open(output_file, "w")
        except OSError as e:
            print(f"Error: cannot write output file '{output_file}' — {e.strerror}. "
                  "Check the directory exists and is writable.", file=sys.stderr)
            sys.exit(1)

        with out_file as out:
            # Records are written as each account completes, so an interrupted
            # run keeps everything already collected — a large org can easily be
            # Ctrl+C'd or killed by a timeout. (DT-11095)
            try:
                with ThreadPoolExecutor(max_workers=MAX_ACCOUNT_WORKERS) as pool:
                    futures = {
                        pool.submit(scan_account, acct, role_name, caller_account_id): acct
                        for acct in accounts
                    }
                    for future in as_completed(futures):
                        acct = futures[future]
                        try:
                            records = future.result()
                        except Exception as e:       # noqa: BLE001
                            reason = f"account scan failed unexpectedly: {condense(e)}"
                            log(f"  [fail] {acct}: {reason}")
                            records = [account_record(acct, "failed", reason)]

                        for record in records:
                            out.write(json.dumps(record) + "\n")
                            if record["record_type"] == "account":
                                tally[f"accounts_{record['status']}"] += 1
                            elif record["status"] == "ok":
                                tally["regions_scanned"] += 1
                            elif record["status"] == "partial":
                                tally["regions_partial"] += 1
                            else:
                                tally["regions_failed"] += 1

                        done += 1
                        if records and records[0]["record_type"] == "region":
                            log(f"  [{done}/{len(accounts)}] {acct} — {len(records)} regions")
            except KeyboardInterrupt:
                interrupted = True
                log("\nInterrupted — writing out the results collected so far...")

            # Accounts that never reported are still named, so the gap is visible.
            if interrupted and done < len(accounts):
                for acct in accounts[done:]:
                    out.write(json.dumps(account_record(
                        acct, "failed", "run interrupted before this account finished")) + "\n")
                    tally["accounts_failed"] += 1

            # Last line of the file, so a truncated upload is obvious and coverage
            # is answerable from the shared file alone. (DT-11095)
            summary = {
                "record_type":      "summary",
                "tool_version":     VERSION,
                "scanned_at":       now_utc(),
                "interrupted":      interrupted,
                "accounts_total":   len(accounts),
                "accounts_scanned": len(accounts) - tally["accounts_skipped"] - tally["accounts_failed"],
                "accounts_skipped": tally["accounts_skipped"],
                "accounts_failed":  tally["accounts_failed"],
                "regions_scanned":  tally["regions_scanned"],
                "regions_partial":  tally["regions_partial"],
                "regions_failed":   tally["regions_failed"],
            }
            out.write(json.dumps(summary) + "\n")

        if interrupted:
            log("\nRun was interrupted — the results below are partial.")
        log(f"\nAccounts: {summary['accounts_total']} total, {summary['accounts_scanned']} scanned, "
            f"{summary['accounts_skipped']} skipped, {summary['accounts_failed']} failed")
        log(f"Regions:  {summary['regions_scanned']} scanned, {summary['regions_partial']} partial, "
            f"{summary['regions_failed']} failed")
        log(f"Output:   {output_file}")
        if any(summary[k] for k in ("accounts_skipped", "accounts_failed",
                                    "regions_partial", "regions_failed")):
            log("\nSome accounts or regions were not fully scanned. Every one is recorded in")
            log(f"{output_file} with a status and a reason — send the file as-is.")

        # Conventional 128+signal, matching bash and Go, so a wrapper can tell
        # an interrupted run from a complete one. The results written above are
        # still valid — just partial.
        if interrupted:
            sys.exit(128 + interrupt_signal[0])

    finally:
        if args.setup_role:
            teardown_stackset(args.ou, include)


if __name__ == "__main__":
    main()
