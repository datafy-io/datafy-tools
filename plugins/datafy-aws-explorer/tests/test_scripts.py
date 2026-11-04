import hashlib
import io
import json
import os
import re
import sqlite3
import tempfile
import unittest

from helpers import ROOT, make_estate, write_ws

import build_db
import collect_utilization as cu
import common
import extrapolate
import fetch_scanner
import sample_volumes as sv


class Sampling(unittest.TestCase):
    def setUp(self):
        self.idx = common.volume_index(make_estate(400))

    def test_excludes_unmeasurable(self):
        pop = sv.measurable(self.idx)
        for e in pop.values():
            self.assertEqual(e["instance"]["State"], "running")
        self.assertLess(len(pop), len(self.idx))

    def test_five_percent_with_floor_and_ceiling(self):
        self.assertEqual(sv.target_size(1000), 50)
        self.assertEqual(sv.target_size(100), 10)      # floor
        self.assertEqual(sv.target_size(6), 6)         # never more than exists
        self.assertEqual(sv.target_size(100000), 500)  # ceiling
        self.assertEqual(sv.target_size(0), 0)

    def test_deterministic_and_stratified(self):
        a = sv.draw(self.idx, set())
        b = sv.draw(self.idx, set())
        self.assertEqual(a["volumes"], b["volumes"])
        types = {self.idx[v]["volume"]["VolumeType"] for v in a["volumes"]}
        self.assertEqual(types, {"gp2", "gp3", "io1"})
        self.assertEqual(len(a["volumes"]), a["target"])
        self.assertNotEqual(a["volumes"], sv.draw(self.idx, set(), seed="other")["volumes"])

    def test_cumulative_skips_measured(self):
        first = sv.draw(self.idx, set())
        second = sv.draw(self.idx, set(first["volumes"]))
        self.assertFalse(set(first["volumes"]) & set(second["volumes"]))
        self.assertEqual(second["volumes"], [])  # target already met

    def test_allocate_more_strata_than_slots(self):
        alloc = sv.allocate({("a",): 50, ("b",): 5, ("c",): 3}, 2)
        self.assertEqual(sum(alloc.values()), 2)
        self.assertEqual(alloc[("a",)], 1)


class Extrapolation(unittest.TestCase):
    def test_no_range_when_sample_tiny(self):
        idx = common.volume_index(make_estate(200))
        vols = list(sv.measurable(idx))[:4]
        out = extrapolate.estimate(idx, {v: 50.0 for v in vols})
        self.assertIsNone(out["range"])

    def test_range_brackets_truth_and_is_clamped(self):
        idx = common.volume_index(make_estate(400))
        pop = sorted(sv.measurable(idx))
        meas = {v: 20.0 + (i % 5) for i, v in enumerate(pop[::4])}
        out = extrapolate.estimate(idx, meas)
        lo, hi = out["range"]["used_pct"]
        self.assertTrue(0 <= lo <= 22 <= hi <= 100, out)
        self.assertIn("point-in-time", out["note"])


DF = """Filesystem     Type 1-blocks       Used  Available Capacity Mounted on
/dev/nvme0n1p1 xfs  107361579008 21474836480 85886742528 21% /
tmpfs          tmpfs  8000000000          0 8000000000  0% /dev/shm
/dev/nvme1n1   ext4  536603975680 429496729600 107107246080 81% /data
/dev/mapper/vg-lv xfs 100000000000 50000000000 50000000000 50% /lvm
"""
LSBLK = json.dumps({"blockdevices": [
    {"name": "nvme0n1", "serial": "vol0aaaaaaaaaaaaaaaa", "type": "disk",
     "children": [{"name": "nvme0n1p1", "serial": None, "type": "part", "mountpoint": "/"}]},
    {"name": "nvme1n1", "serial": "vol0bbbbbbbbbbbbbbbb", "type": "disk", "mountpoint": "/data"},
    {"name": "nvme2n1", "serial": "vol0cccccccccccccccc", "type": "disk", "children": [
        {"name": "vg-lv", "serial": None, "type": "lvm", "mountpoint": "/lvm"}]},
    {"name": "nvme3n1", "serial": "vol0dddddddddddddddd", "type": "disk", "children": [
        {"name": "vg-lv", "serial": None, "type": "lvm", "mountpoint": "/lvm"}]},
]})


class Parsing(unittest.TestCase):
    def test_serial_to_volume_id(self):
        self.assertEqual(cu.vol_from_serial("vol0aaaaaaaaaaaaaaaa"), "vol-0aaaaaaaaaaaaaaaa")
        self.assertIsNone(cu.vol_from_serial("Amazon EC2 NVMe"))

    def test_parse_ssm_output(self):
        mounts, note = cu.parse_ssm_output("---DF---\n" + DF + "---LSBLK---\n" + LSBLK)
        by = {m["mountpoint"]: m for m in mounts}
        self.assertNotIn("/dev/shm", by)
        self.assertEqual(by["/"]["volume_id"], "vol-0aaaaaaaaaaaaaaaa")
        self.assertEqual(by["/data"]["volume_id"], "vol-0bbbbbbbbbbbbbbbb")
        self.assertEqual(by["/data"]["used_pct"], 80.0)
        # LVM across two disks is NOT attributed to a single volume
        self.assertIsNone(by["/lvm"]["volume_id"])
        self.assertEqual(len(by["/lvm"]["volume_ids"]), 2)
        self.assertIsNone(note)

    def test_missing_lsblk_is_flagged(self):
        mounts, note = cu.parse_ssm_output("---DF---\n" + DF + "---LSBLK---\n")
        self.assertTrue(note)
        self.assertTrue(all(m["volume_id"] is None for m in mounts))

    def test_name_fallback_only_when_certain(self):
        m = [{"device": "/dev/xvdf1", "volume_id": None}, {"device": "/dev/xvdg", "volume_id": None}]
        cu.map_by_name(m, [{"VolumeId": "vol-1", "Device": "/dev/sdf"},
                           {"VolumeId": "vol-2", "Device": "/dev/xvdg"}, {"VolumeId": "vol-3", "Device": "/dev/xvdg"}])
        self.assertEqual(m[0]["volume_id"], "vol-1")
        self.assertIsNone(m[1]["volume_id"])  # ambiguous: two volumes claim xvdg


class Budget(unittest.TestCase):
    def test_cap_is_not_overridable(self):
        self.assertEqual(common.CostBudget(cap=50).cap, 1.0)

    def test_charge_refuses_over_cap(self):
        b = common.CostBudget()
        b.charge("GetMetricData", 99000)  # $0.99
        with self.assertRaises(common.BudgetExceeded):
            b.charge("GetMetricData", 2000)
        self.assertLess(b.spent, 1.0)

    def test_plan_trims_to_fit(self):
        ws = write_ws(make_estate(40))
        ids = ["i-%d%05d" % (0, i) for i in range(1, 20)]
        plan = cu.cw_plan(ws, ids, common.CostBudget(cap=0.00005))
        self.assertGreater(plan["dropped_to_fit_budget"], 0)
        self.assertLessEqual(plan["estimated_aws_cost_usd"], 0.00005 + 1e-9)

    def test_five_percent_of_big_estate_is_cheap(self):
        b = common.CostBudget()
        self.assertLess(b.estimate({"ListMetrics": 500, "GetMetricData": 1000}), 0.05)


class FakeSSM:
    def __init__(self, managed, outputs, fail_send=False):
        self.managed, self.outputs, self.fail_send, self.sent = managed, outputs, fail_send, []

    def describe_instance_information(self, Filters):
        ids = Filters[0]["Values"]
        return {"InstanceInformationList": [
            {"InstanceId": i, "PingStatus": self.managed[i][0], "PlatformType": self.managed[i][1]}
            for i in ids if i in self.managed]}

    def send_command(self, **kw):
        if self.fail_send:
            raise RuntimeError("boom")
        self.sent.append(kw)
        return {"Command": {"CommandId": "c-1"}}

    def get_command_invocation(self, CommandId, InstanceId):
        st, out = self.outputs[InstanceId]
        return {"Status": st, "StandardOutputContent": out, "StandardErrorContent": "err" if st != "Success" else ""}


class FakeSessions:
    def __init__(self, **svc):
        self.svc = svc

    def client(self, service, account, region):
        return self.svc[service]


class SsmRun(unittest.TestCase):
    def test_statuses_and_fixed_command(self):
        ws = write_ws(make_estate(40))
        ids = ["i-000001", "i-000002", "i-000003", "i-000004", "i-000005"]
        ssm = FakeSSM(
            managed={"i-000001": ("Online", "Linux"), "i-000002": ("ConnectionLost", "Linux"),
                     "i-000003": ("Online", "Windows"), "i-000004": ("Online", "Linux")},
            outputs={"i-000001": ("Success", "---DF---\n" + DF + "---LSBLK---\n" + LSBLK),
                     "i-000004": ("Failed", "")})
        stats = cu.run_ssm(ws, ids, FakeSessions(ssm=ssm), poll=0, sleep=lambda s: None)
        self.assertEqual(stats, {"ok": 1, "failed": 1, "skipped": 3})
        recs = {r["instance_id"]: r for r in common.read_jsonl(os.path.join(ws, "utilization.jsonl"))}
        self.assertTrue(recs["i-000005"]["reason"].startswith("not_managed"))
        self.assertTrue(recs["i-000002"]["reason"].startswith("ssm_offline"))
        self.assertEqual(recs["i-000003"]["reason"], "windows_unsupported")
        self.assertEqual(recs["i-000001"]["status"], "ok")
        # only the fixed document was ever invoked
        self.assertEqual(len(ssm.sent), 1)
        self.assertEqual(ssm.sent[0]["DocumentName"], "DatafyDiskUsage")
        self.assertNotIn("commands", ssm.sent[0]["Parameters"])

    def test_cumulative_skip(self):
        ws = write_ws(make_estate(40))
        cu.record(ws, "i-000001", "111111111111", "us-east-1", "ssm_df", "ok", None, [])
        self.assertEqual(cu.ssm_plan(ws, ["i-000001", "i-000002"])["instances"], ["i-000002"])

    def test_send_failure_is_recorded_not_raised(self):
        ws = write_ws(make_estate(40))
        ssm = FakeSSM({"i-000001": ("Online", "Linux")}, {}, fail_send=True)
        stats = cu.run_ssm(ws, ["i-000001"], FakeSessions(ssm=ssm), poll=0, sleep=lambda s: None)
        self.assertEqual(stats["failed"], 1)

    def test_remote_command_matches_cloudformation_document(self):
        cfn = open(os.path.join(ROOT, "iam", "datafy-disk-usage.cfn.yaml")).read()
        line = [l for l in cfn.splitlines() if "---DF---" in l][0].strip()[3:-1]  # strip '- "' and '"'
        self.assertEqual(line, cu.REMOTE_COMMAND)

    def test_policy_allows_sendcommand_only_on_our_document(self):
        pol = json.load(open(os.path.join(ROOT, "iam", "ssm-sendcommand-policy.json")))
        send = [s for s in pol["Statement"] if s["Action"] == "ssm:SendCommand"][0]
        self.assertIn("arn:aws:ssm:*:*:document/DatafyDiskUsage", send["Resource"])
        self.assertFalse(any("AWS-RunShellScript" in r for r in send["Resource"]))


class RoleTemplate(unittest.TestCase):
    def test_role_runs_only_our_document_and_trusts_only_the_management_account(self):
        t = open(os.path.join(ROOT, "iam", "datafy-explorer-role.cfn.yaml")).read()
        self.assertIn("document/DatafyDiskUsage", t)
        self.assertNotIn("AWS-RunShellScript", t)
        # no action wildcard (an ARN like arn:aws:ssm:*:*:document/... is fine)
        self.assertIsNone(re.search(r"[\[\s,]\w+:\*[\],\s]", t))
        self.assertNotIn("Action: \"*\"", t)
        self.assertIn("${ManagementAccountId}:root", t)
        self.assertEqual(t.count("sts:AssumeRole"), 1)


class FakeCW:
    def __init__(self, with_metrics, per=1):
        self.with_metrics, self.per, self.calls = with_metrics, per, {"list": 0, "get": 0}

    def list_metrics(self, **kw):
        self.calls["list"] += 1
        iid = kw["Dimensions"][0]["Value"]
        if iid not in self.with_metrics:
            return {"Metrics": []}
        return {"Metrics": [{"Namespace": "CWAgent", "MetricName": "disk_used_percent", "Dimensions": [
            {"Name": "InstanceId", "Value": iid}, {"Name": "path", "Value": "/" if k == 0 else "/m%d" % k},
            {"Name": "device", "Value": "xvda1" if k == 0 else "xvdz%d" % k}, {"Name": "fstype", "Value": "xfs"}]}
            for k in range(self.per)]}

    def get_metric_data(self, MetricDataQueries, **kw):
        self.calls["get"] += 1
        return {"MetricDataResults": [{"Id": q["Id"], "Values": [42.0]} for q in MetricDataQueries]}


class CloudWatchRun(unittest.TestCase):
    def test_records_and_charges(self):
        ws = write_ws(make_estate(40))
        cw, b = FakeCW({"i-000001"}), common.CostBudget()
        stats = cu.run_cloudwatch(ws, ["i-000001", "i-000002"], FakeSessions(cloudwatch=cw), b)
        self.assertEqual((stats["ok"], stats["skipped"]), (1, 1))
        recs = {r["instance_id"]: r for r in common.read_jsonl(os.path.join(ws, "utilization.jsonl"))}
        self.assertEqual(recs["i-000002"]["reason"], "no_agent_metrics")
        m = recs["i-000001"]["mounts"][0]
        self.assertEqual((m["used_pct"], m["volume_id"], m["derived"]), (42.0, "vol-000001", True))
        self.assertEqual(b.calls, {"ListMetrics": 2, "GetMetricData": 1})

    def test_stops_when_budget_would_be_exceeded(self):
        ws = write_ws(make_estate(40))
        # the plan assumes 2 metrics/instance; an instance that really has 3 breaks that assumption
        b = common.CostBudget(cap=0.00003)
        stats = cu.run_cloudwatch(ws, ["i-000001"], FakeSessions(cloudwatch=FakeCW({"i-000001"}, per=3)), b)
        self.assertTrue(stats["stopped_for_budget"])
        self.assertLessEqual(b.spent, 0.00003 + 1e-12)


class Fetch(unittest.TestCase):
    def test_lock_lists_every_binary_with_a_sha256(self):
        lock = fetch_scanner.load_lock()
        self.assertGreaterEqual(len(lock["assets"]), 7)
        for name, sha in lock["assets"].items():
            self.assertRegex(sha, r"^[0-9a-f]{64}$", name)
        self.assertTrue(lock["base_url"].startswith("https://github.com/datafy-io/"))

    def test_checksum_mismatch_refuses(self):
        class R(io.BytesIO):
            __enter__ = lambda s: s
            __exit__ = lambda s, *a: None
        lock = {"base_url": "https://x/", "assets": {"a.py": hashlib.sha256(b"good").hexdigest()}}
        d = tempfile.mkdtemp()
        with self.assertRaises(SystemExit):
            fetch_scanner.fetch("a.py", d, lock, opener=lambda u: R(b"evil"))
        self.assertFalse(os.path.exists(os.path.join(d, "a.py")))
        self.assertTrue(fetch_scanner.fetch("a.py", d, lock, opener=lambda u: R(b"good")))


class FetchCertFallback(unittest.TestCase):
    def test_no_ca_certs_falls_back_to_curl_and_still_verifies(self):
        import ssl
        import subprocess
        import urllib.error
        from unittest import mock
        good = b"scanner-bytes"
        lock = {"base_url": "https://x/", "assets": {"a.py": hashlib.sha256(good).hexdigest()}}

        def no_certs(url):
            raise urllib.error.URLError(ssl.SSLCertVerificationError("CERTIFICATE_VERIFY_FAILED"))

        def fake_curl(cmd, **kw):
            open(cmd[cmd.index("-o") + 1], "wb").write(good)
            return subprocess.CompletedProcess(cmd, 0)

        d = tempfile.mkdtemp()
        with mock.patch("fetch_scanner.shutil.which", return_value="/usr/bin/curl"), \
                mock.patch("fetch_scanner.subprocess.run", side_effect=fake_curl) as run:
            self.assertTrue(fetch_scanner.fetch("a.py", d, lock, opener=no_certs))
            self.assertIn("--proto", run.call_args[0][0])
        # and a tampered curl download is still refused
        with mock.patch("fetch_scanner.shutil.which", return_value="/usr/bin/curl"), \
                mock.patch("fetch_scanner.subprocess.run",
                           side_effect=lambda cmd, **kw: (open(cmd[cmd.index("-o") + 1], "wb").write(b"evil"),
                                                          subprocess.CompletedProcess(cmd, 0))[1]):
            with self.assertRaises(SystemExit):
                fetch_scanner.fetch("b.py", tempfile.mkdtemp(),
                                    {"base_url": "https://x/", "assets": {"b.py": hashlib.sha256(good).hexdigest()}},
                                    opener=no_certs)

    def test_other_network_errors_do_not_trigger_curl(self):
        import urllib.error
        from unittest import mock
        def refused(url):
            raise urllib.error.URLError(ConnectionRefusedError())
        lock = {"base_url": "https://x/", "assets": {"a.py": "0" * 64}}
        with mock.patch("fetch_scanner.subprocess.run") as run:
            with self.assertRaises(SystemExit):
                fetch_scanner.fetch("a.py", tempfile.mkdtemp(), lock, opener=refused)
            run.assert_not_called()


class Db(unittest.TestCase):
    def test_build_and_join(self):
        ws = write_ws(make_estate(40))
        cu.record(ws, "i-000001", "111111111111", "us-east-1", "ssm_df", "ok", None,
                  [{"mountpoint": "/", "volume_id": "vol-000001", "used_pct": 33.0, "size_bytes": 10, "used_bytes": 3}])
        path, counts = build_db.build(ws)
        db = sqlite3.connect(path)
        self.assertEqual(counts["volumes"], 40)
        self.assertEqual(db.execute("SELECT used_pct FROM volume_utilization WHERE volume_id='vol-000001'").fetchone()[0], 33.0)
        self.assertEqual(db.execute("SELECT accounts_total FROM scan_summary").fetchone()[0], 2)

    def test_gaps_are_recorded(self):
        recs = make_estate(20)
        recs.insert(0, {"record_type": "account", "account_id": "9", "status": "skipped", "reason": "denied"})
        recs[1]["status"], recs[1]["errors"] = "partial", ["ec2:DescribeVolumes: AccessDenied"]
        ws = write_ws(recs)
        db = sqlite3.connect(build_db.build(ws)[0])
        kinds = sorted(r[0] for r in db.execute("SELECT kind FROM scan_gaps"))
        self.assertEqual(kinds, ["account", "region"])


if __name__ == "__main__":
    unittest.main()
