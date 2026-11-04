import json
import os
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts"))


def make_estate(n_vols=100, accounts=("111111111111", "222222222222"), stopped_every=10):
    """Region records: each volume attached to its own instance; some unattached, some stopped."""
    recs = []
    for ai, acct in enumerate(accounts):
        vols, insts = [], []
        for i in range(n_vols // len(accounts)):
            iid = "i-%d%05d" % (ai, i)
            state = "stopped" if i % stopped_every == 0 else "running"
            insts.append({"InstanceId": iid, "State": state, "PlatformDetails": "Linux/UNIX",
                          "RootDeviceName": "/dev/xvda", "InstanceType": "m5.large", "Tags": []})
            vtype = ["gp2", "gp3", "io1"][i % 3]
            vols.append({"VolumeId": "vol-%d%05d" % (ai, i), "Size": [20, 100, 500, 2000][i % 4],
                         "VolumeType": vtype, "State": "in-use", "Encrypted": True, "AvailabilityZone": "us-east-1a",
                         "InstanceId": None if i % 17 == 16 else iid, "Device": "/dev/xvda", "Tags": []})
        recs.append({"record_type": "region", "account_id": acct, "region": "us-east-1", "status": "ok",
                     "scanned_at": "2026-01-01T00:00:00Z", "errors": [], "volumes": vols, "instances": insts,
                     "amis": [], "snapshots": [], "dlm_policies": [], "backup_plans": []})
    recs.append({"record_type": "summary", "tool_version": "0.2.1", "scanned_at": "2026-01-01T00:00:00Z",
                 "interrupted": False, "accounts_total": len(accounts), "accounts_scanned": len(accounts),
                 "accounts_skipped": 0, "accounts_failed": 0, "regions_scanned": len(accounts),
                 "regions_partial": 0, "regions_failed": 0})
    return recs


def write_ws(recs, ws=None):
    ws = ws or tempfile.mkdtemp(prefix="dfy-ws-")
    with open(os.path.join(ws, "discovery.jsonl"), "w") as f:
        for r in recs:
            f.write(json.dumps(r) + "\n")
    return ws
