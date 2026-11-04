#!/usr/bin/env python3
"""Collect real disk utilization for the sampled instances.

Two tiers, both writing utilization.jsonl (one `instance` record per instance):

  cloudwatch  Reads disk_used_percent from the CWAgent namespace. Touches no instance.
              Billed (a few cents at most) and bounded by a hard $1 cap.
  ssm         Runs the fixed DatafyDiskUsage SSM document (df + lsblk) on the instances.
              Requires explicit approval (--yes). Free of AWS charges.

Both default to a PLAN: they print what would happen (targets, cost, exact command) and
change nothing. Add --yes to execute. Nothing is ever sent anywhere but your own AWS.

  collect_utilization.py plan  cloudwatch|ssm   show the plan
  collect_utilization.py run   cloudwatch|ssm --yes
"""
import argparse
import json
import os
import re
import time
from datetime import datetime, timedelta, timezone

from common import (BudgetExceeded, CostBudget, UTILIZATION_FILE, append_jsonl, log, now_iso, read_discovery,
                    read_jsonl, volume_index, workspace)

DOC_NAME = "DatafyDiskUsage"
FALLBACK_DOC = "AWS-RunShellScript"
# The ONLY command this tool ever runs on an instance. Identical to the DatafyDiskUsage
# document's content (iam/datafy-disk-usage.cfn.yaml); the test suite asserts they match.
REMOTE_COMMAND = ("echo '---DF---'; df -PT -B1 2>/dev/null; "
                  "echo '---LSBLK---'; lsblk -J -o NAME,SERIAL,SIZE,TYPE,MOUNTPOINT 2>/dev/null || true")
SSM_BATCH = 50          # SendCommand target limit
CW_QUERY_BATCH = 500    # GetMetricData query limit
PSEUDO_FS = {"tmpfs", "devtmpfs", "overlay", "squashfs", "proc", "sysfs", "cgroup", "cgroup2", "efivarfs",
             "iso9660", "ramfs", "nfs", "nfs4", "efs", "fuse", "fuse.sshfs", "autofs"}


# ── parsing ────────────────────────────────────────────────────────────────

def vol_from_serial(serial):
    """EBS exposes its volume id as the NVMe serial, with the dash removed."""
    s = (serial or "").strip()
    return "vol-" + s[3:] if re.fullmatch(r"vol[0-9a-f]{8,17}", s) else None


def parse_df(text):
    rows = []
    for line in text.strip().splitlines()[1:]:
        p = line.split(None, 6)
        if len(p) < 7 or not p[0].startswith("/dev/") or p[1] in PSEUDO_FS:
            continue
        try:
            size, used, avail = int(p[2]), int(p[3]), int(p[4])
        except ValueError:
            continue
        rows.append({"device": p[0], "fstype": p[1], "size_bytes": size, "used_bytes": used,
                     "avail_bytes": avail, "used_pct": round(100.0 * used / (used + avail), 1) if used + avail else 0.0,
                     "mountpoint": p[6]})
    return rows


def _walk(node, chain, found):
    chain = chain + [node]
    for c in node.get("children") or []:
        _walk(c, chain, found)
    found.setdefault(node["name"], []).append(chain)


def device_volumes(lsblk_json):
    """{device basename: sorted set of volume ids reachable up the device tree}."""
    try:
        tree = json.loads(lsblk_json)
    except ValueError:
        return {}
    found = {}
    for top in tree.get("blockdevices", []):
        _walk(top, [], found)
    out = {}
    for name, chains in found.items():
        vols = set()
        for chain in chains:
            for n in chain:
                v = vol_from_serial(n.get("serial"))
                if v:
                    vols.add(v)
        out[name] = sorted(vols)
    return out


def parse_ssm_output(text):
    """-> (mounts, note). Each mount carries volume_id (or None) and volume_ids (>1 for LVM/RAID)."""
    df_part, _, lsblk_part = text.partition("---LSBLK---")
    df_part = df_part.replace("---DF---", "")
    mounts = parse_df(df_part)
    dev_vols = device_volumes(lsblk_part) if lsblk_part.strip() else {}
    for m in mounts:
        vols = dev_vols.get(os.path.basename(m["device"]), [])
        m["volume_ids"] = vols
        m["volume_id"] = vols[0] if len(vols) == 1 else None
    note = None if dev_vols else "lsblk unavailable: mounts could not be tied to volumes by serial"
    return mounts, note


def norm_device(dev):
    """/dev/sdf1, /dev/xvdf, xvdf1 -> 'xvdf' (Xen-style names; NVMe names cannot be mapped this way)."""
    d = os.path.basename(dev or "")
    d = re.sub(r"^sd", "xvd", d)
    return re.sub(r"p?\d+$", "", d) if d.startswith("xvd") else d


def map_by_name(mounts, attached):
    """Fallback when serials are missing. attached: [{'VolumeId','Device'}]. Only certain matches are made."""
    by_dev = {}
    for a in attached:
        by_dev.setdefault(norm_device(a.get("Device")), []).append(a["VolumeId"])
    for m in mounts:
        if m.get("volume_id"):
            continue
        v = by_dev.get(norm_device(m["device"]), [])
        if len(v) == 1:
            m["volume_id"] = v[0]
    return mounts


# ── clients ────────────────────────────────────────────────────────────────

class Sessions:
    """One boto3 session per (account, region), assuming a role into other accounts."""

    def __init__(self, profile=None, role="OrganizationAccountAccessRole"):
        import boto3
        self._boto3, self.role = boto3, role
        self.base = boto3.Session(profile_name=profile) if profile else boto3.Session()
        self.caller = self.base.client("sts").get_caller_identity()["Account"]
        self._cache = {}

    def client(self, service, account, region):
        k = (account, region)
        if k not in self._cache:
            if account == self.caller:
                self._cache[k] = self.base
            else:
                c = self.base.client("sts").assume_role(
                    RoleArn="arn:aws:iam::%s:role/%s" % (account, self.role),
                    RoleSessionName="datafy-explorer")["Credentials"]
                self._cache[k] = self._boto3.Session(
                    aws_access_key_id=c["AccessKeyId"], aws_secret_access_key=c["SecretAccessKey"],
                    aws_session_token=c["SessionToken"])
        return self._cache[k].client(service, region_name=region)


def targets_by_scope(ws, instance_ids):
    """Group instance ids by (account, region) using discovery data."""
    inst = {}
    for r in read_discovery(ws):
        if r.get("record_type") == "region":
            for i in r.get("instances", []):
                inst[i["InstanceId"]] = (r["account_id"], r["region"], i)
    scopes, unknown = {}, []
    for iid in instance_ids:
        if iid in inst:
            a, g, i = inst[iid]
            scopes.setdefault((a, g), []).append(iid)
        else:
            unknown.append(iid)
    return scopes, unknown


def already_done(ws, source):
    return {r["instance_id"] for r in read_jsonl(os.path.join(ws, UTILIZATION_FILE))
            if r.get("record_type") == "instance" and r.get("source") == source and r.get("status") == "ok"}


def record(ws, iid, account, region, source, status, reason=None, mounts=None):
    append_jsonl(os.path.join(ws, UTILIZATION_FILE), {
        "record_type": "instance", "instance_id": iid, "account_id": account, "region": region,
        "source": source, "status": status, "reason": reason, "mounts": mounts or [], "collected_at": now_iso()})


# ── SSM tier ───────────────────────────────────────────────────────────────

def ssm_plan(ws, instance_ids, use_fallback=False):
    todo = [i for i in instance_ids if i not in already_done(ws, "ssm_df")]
    scopes, unknown = targets_by_scope(ws, todo)
    return {
        "tier": "ssm", "document": FALLBACK_DOC if use_fallback else DOC_NAME,
        "command": REMOTE_COMMAND, "instances": todo, "skipped_already_done": len(instance_ids) - len(todo),
        "unknown_instances": unknown, "scopes": {"%s/%s" % k: v for k, v in scopes.items()},
        "estimated_aws_cost_usd": 0.0,
        "note": "SSM Run Command is free. Output is returned inline, never written to S3.",
    }


def run_ssm(ws, instance_ids, sessions, use_fallback=False, poll=2.0, timeout=120, sleep=time.sleep):
    plan = ssm_plan(ws, instance_ids, use_fallback)
    idx = volume_index(read_discovery(ws))
    attached = {}
    for e in idx.values():
        if e["instance"]:
            attached.setdefault(e["instance"]["InstanceId"], []).append(e["volume"])
    scopes, _ = targets_by_scope(ws, plan["instances"])
    stats = {"ok": 0, "failed": 0, "skipped": 0}
    for (account, region), ids in scopes.items():
        try:
            ssm = sessions.client("ssm", account, region)
            info = {}
            for i in range(0, len(ids), SSM_BATCH):
                resp = ssm.describe_instance_information(
                    Filters=[{"Key": "InstanceIds", "Values": ids[i:i + SSM_BATCH]}])
                for x in resp.get("InstanceInformationList", []):
                    info[x["InstanceId"]] = x
        except Exception as e:  # noqa: BLE001 - recorded, not hidden
            for iid in ids:
                record(ws, iid, account, region, "ssm_df", "failed", "ssm:DescribeInstanceInformation: %s" % _err(e))
                stats["failed"] += 1
            continue
        ready = []
        for iid in ids:
            x = info.get(iid)
            if not x:
                record(ws, iid, account, region, "ssm_df", "skipped", "not_managed: no SSM agent or instance profile")
                stats["skipped"] += 1
            elif x.get("PingStatus") != "Online":
                record(ws, iid, account, region, "ssm_df", "skipped", "ssm_offline: ping status %s" % x.get("PingStatus"))
                stats["skipped"] += 1
            elif x.get("PlatformType") != "Linux":
                record(ws, iid, account, region, "ssm_df", "skipped", "windows_unsupported")
                stats["skipped"] += 1
            else:
                ready.append(iid)
        for i in range(0, len(ready), SSM_BATCH):
            batch = ready[i:i + SSM_BATCH]
            try:
                params = {"commands": [REMOTE_COMMAND]} if use_fallback else {}
                cmd = ssm.send_command(InstanceIds=batch, DocumentName=plan["document"], Parameters=params,
                                       Comment="Datafy disk utilization (read-only)", TimeoutSeconds=60)
                cid = cmd["Command"]["CommandId"]
            except Exception as e:  # noqa: BLE001
                for iid in batch:
                    record(ws, iid, account, region, "ssm_df", "failed", "ssm:SendCommand: %s" % _err(e))
                    stats["failed"] += 1
                continue
            for iid in batch:
                st, out, why = _wait_invocation(ssm, cid, iid, poll, timeout, sleep)
                if st != "Success":
                    record(ws, iid, account, region, "ssm_df", "failed", why or "command %s" % st)
                    stats["failed"] += 1
                    continue
                mounts, note = parse_ssm_output(out)
                map_by_name(mounts, attached.get(iid, []))
                record(ws, iid, account, region, "ssm_df", "partial" if note else "ok", note, mounts)
                stats["ok"] += 1
    return stats


def _wait_invocation(ssm, cid, iid, poll, timeout, sleep):
    deadline = time.time() + timeout
    while True:
        try:
            r = ssm.get_command_invocation(CommandId=cid, InstanceId=iid)
        except Exception as e:  # noqa: BLE001
            code = getattr(e, "response", {}).get("Error", {}).get("Code")
            if code == "InvocationDoesNotExist" and time.time() < deadline:
                sleep(poll)
                continue
            return "Failed", "", "ssm:GetCommandInvocation: %s" % _err(e)
        st = r.get("Status")
        if st in ("Success", "Failed", "TimedOut", "Cancelled", "Undeliverable", "Terminated", "DeliveryTimedOut",
                  "ExecutionTimedOut", "AccessDenied", "NoInstancesInTag", "LimitExceeded"):
            return st, r.get("StandardOutputContent", ""), (r.get("StandardErrorContent") or "")[:200] or None
        if time.time() >= deadline:
            return "TimedOut", "", "timed out waiting for the command"
        sleep(poll)


def _err(e):
    code = getattr(e, "response", {}).get("Error", {}).get("Code")
    return "%s: %s" % (code, str(e)[:160]) if code else str(e)[:200]


# ── CloudWatch tier ────────────────────────────────────────────────────────

def cw_plan(ws, instance_ids, budget):
    todo = [i for i in instance_ids if i not in already_done(ws, "cloudwatch")]
    # one ListMetrics per instance, then ~2 mounts per instance as a planning assumption
    units = {"ListMetrics": len(todo), "GetMetricData": len(todo) * 2}
    est = budget.estimate(units)
    keep = todo
    if est > budget.cap:
        per = budget.estimate({"ListMetrics": 1, "GetMetricData": 2})
        keep = todo[:int((budget.cap + 1e-12) // per)]
        units = {"ListMetrics": len(keep), "GetMetricData": len(keep) * 2}
        est = budget.estimate(units)
    return {"tier": "cloudwatch", "instances": keep, "dropped_to_fit_budget": len(todo) - len(keep),
            "billed_units": units, "estimated_aws_cost_usd": round(est, 5), "cap_usd": budget.cap,
            "note": "Needs the CloudWatch Agent publishing disk_used_percent. Instances without it are recorded as "
                    "'no_agent_metrics' and are candidates for the ssm tier."}


def run_cloudwatch(ws, instance_ids, sessions, budget, now=None):
    plan = cw_plan(ws, instance_ids, budget)
    idx = volume_index(read_discovery(ws))
    attached = {}
    for e in idx.values():
        if e["instance"]:
            attached.setdefault(e["instance"]["InstanceId"], []).append(e["volume"])
    scopes, _ = targets_by_scope(ws, plan["instances"])
    now = now or datetime.now(timezone.utc)
    stats = {"ok": 0, "failed": 0, "skipped": 0, "stopped_for_budget": False}
    for (account, region), ids in scopes.items():
        try:
            cw = sessions.client("cloudwatch", account, region)
        except Exception as e:  # noqa: BLE001
            for iid in ids:
                record(ws, iid, account, region, "cloudwatch", "failed", "sts:AssumeRole: %s" % _err(e))
                stats["failed"] += 1
            continue
        for iid in ids:
            try:
                budget.charge("ListMetrics", 1)
                metrics = _list_disk_metrics(cw, iid)
                if not metrics:
                    record(ws, iid, account, region, "cloudwatch", "skipped", "no_agent_metrics")
                    stats["skipped"] += 1
                    continue
                budget.charge("GetMetricData", len(metrics))
                pct = _latest(cw, metrics, now)
            except BudgetExceeded as e:
                log("stopping: %s" % e)
                stats["stopped_for_budget"] = True
                return stats | {"budget": budget.summary()}
            except Exception as e:  # noqa: BLE001
                record(ws, iid, account, region, "cloudwatch", "failed", _err(e))
                stats["failed"] += 1
                continue
            mounts = _cw_mounts(metrics, pct, attached.get(iid, []))
            record(ws, iid, account, region, "cloudwatch", "ok" if mounts else "skipped",
                   None if mounts else "no_recent_datapoints", mounts)
            stats["ok" if mounts else "skipped"] += 1
    return stats | {"budget": budget.summary()}


def _list_disk_metrics(cw, iid):
    out, token = [], None
    while True:
        kw = {"Namespace": "CWAgent", "MetricName": "disk_used_percent",
              "Dimensions": [{"Name": "InstanceId", "Value": iid}]}
        if token:
            kw["NextToken"] = token
        r = cw.list_metrics(**kw)
        out += r.get("Metrics", [])
        token = r.get("NextToken")
        if not token:
            return out


def _latest(cw, metrics, now):
    res = {}
    for i in range(0, len(metrics), CW_QUERY_BATCH):
        chunk = metrics[i:i + CW_QUERY_BATCH]
        q = [{"Id": "m%d" % (i + j), "MetricStat": {"Metric": m, "Period": 300, "Stat": "Maximum"},
              "ReturnData": True} for j, m in enumerate(chunk)]
        r = cw.get_metric_data(MetricDataQueries=q, StartTime=now - timedelta(hours=3), EndTime=now,
                               ScanBy="TimestampDescending")
        for x in r.get("MetricDataResults", []):
            if x.get("Values"):
                res[x["Id"]] = x["Values"][0]
    return {int(k[1:]): v for k, v in res.items()}


def _cw_mounts(metrics, pct_by_i, attached):
    mounts = []
    for i, m in enumerate(metrics):
        if i not in pct_by_i:
            continue
        d = {x["Name"]: x["Value"] for x in m["Dimensions"]}
        mounts.append({"mountpoint": d.get("path"), "device": d.get("device"), "fstype": d.get("fstype"),
                       "used_pct": round(pct_by_i[i], 1), "volume_id": None, "volume_ids": []})
    map_by_name(mounts, attached)
    # certain case: "/" with a single attached volume on a root device
    roots = [m for m in mounts if m["mountpoint"] == "/" and not m["volume_id"]]
    if roots and attached:
        names = {a["VolumeId"] for a in attached if (a.get("Device") or "") in ("/dev/xvda", "/dev/sda1")}
        if len(names) == 1:
            roots[0]["volume_id"] = next(iter(names))
    by_vol = {a["VolumeId"]: a for a in attached}
    for m in mounts:  # CloudWatch gives a percentage only: derive bytes from the provisioned size (approximate)
        v = by_vol.get(m["volume_id"])
        if v and v.get("Size"):
            m["size_bytes"] = int(v["Size"]) * 2 ** 30
            m["used_bytes"] = int(m["size_bytes"] * m["used_pct"] / 100)
            m["avail_bytes"] = m["size_bytes"] - m["used_bytes"]
            m["derived"] = True
    return mounts


# ── CLI ────────────────────────────────────────────────────────────────────

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("action", choices=["plan", "run"])
    ap.add_argument("tier", choices=["cloudwatch", "ssm"])
    ap.add_argument("--workspace")
    ap.add_argument("--profile")
    ap.add_argument("--role", default="OrganizationAccountAccessRole")
    ap.add_argument("--instances", help="comma-separated instance ids (default: sample.json)")
    ap.add_argument("--yes", action="store_true", help="approve and execute")
    ap.add_argument("--use-aws-runshellscript", action="store_true",
                    help="use the stock AWS-RunShellScript document if DatafyDiskUsage is not deployed")
    a = ap.parse_args(argv)
    ws = workspace(a.workspace)
    if a.instances:
        ids = [x for x in a.instances.split(",") if x]
    else:
        with open(os.path.join(ws, "sample.json")) as f:
            ids = json.load(f)["instances"]
    budget = CostBudget()
    plan = cw_plan(ws, ids, budget) if a.tier == "cloudwatch" else ssm_plan(ws, ids, a.use_aws_runshellscript)
    if a.action == "plan" or not a.yes:
        print(json.dumps(plan, indent=1))
        if a.action == "run":
            raise SystemExit("not approved: re-run with --yes after the customer confirms the plan above")
        return
    sessions = Sessions(a.profile, a.role)
    if a.tier == "cloudwatch":
        stats = run_cloudwatch(ws, ids, sessions, budget)
    else:
        stats = run_ssm(ws, ids, sessions, a.use_aws_runshellscript)
    print(json.dumps(stats))


if __name__ == "__main__":
    main()
