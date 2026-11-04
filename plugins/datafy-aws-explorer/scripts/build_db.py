#!/usr/bin/env python3
"""Build explorer.db (SQLite) from the workspace JSONL files.

Tables: scan_summary, scan_gaps, volumes, instances, snapshots, amis,
        utilization_instances, utilization_mounts, enrichment.
The database is rebuilt from scratch every time; the JSONL files are the source of truth.
"""
import argparse
import json
import os
import sqlite3

from common import (DB_FILE, DISCOVERY_FILE, ENRICHMENT_FILE, UTILIZATION_FILE, read_jsonl, workspace, log)

SCHEMA = """
CREATE TABLE scan_summary(tool_version TEXT, scanned_at TEXT, interrupted INT, accounts_total INT,
  accounts_scanned INT, accounts_skipped INT, accounts_failed INT, regions_scanned INT,
  regions_partial INT, regions_failed INT);
CREATE TABLE scan_gaps(kind TEXT, account_id TEXT, region TEXT, status TEXT, detail TEXT);
CREATE TABLE volumes(volume_id TEXT PRIMARY KEY, account_id TEXT, region TEXT, name TEXT, size_gib INT,
  volume_type TEXT, state TEXT, iops INT, throughput INT, encrypted INT, az TEXT, snapshot_id TEXT,
  instance_id TEXT, device TEXT, tags TEXT);
CREATE TABLE instances(instance_id TEXT PRIMARY KEY, account_id TEXT, region TEXT, name TEXT,
  instance_type TEXT, state TEXT, platform TEXT, image_id TEXT, az TEXT, root_device TEXT,
  architecture TEXT, tags TEXT);
CREATE TABLE snapshots(snapshot_id TEXT, account_id TEXT, region TEXT, volume_id TEXT, size_gib INT,
  start_time TEXT, state TEXT, encrypted INT, tags TEXT);
CREATE TABLE amis(image_id TEXT, account_id TEXT, region TEXT, name TEXT, platform TEXT, architecture TEXT);
CREATE TABLE utilization_instances(instance_id TEXT, account_id TEXT, region TEXT, source TEXT,
  status TEXT, reason TEXT, collected_at TEXT);
CREATE TABLE utilization_mounts(instance_id TEXT, volume_id TEXT, source TEXT, mountpoint TEXT, device TEXT,
  fstype TEXT, size_bytes INT, used_bytes INT, avail_bytes INT, used_pct REAL, collected_at TEXT);
CREATE TABLE tags(resource_type TEXT, resource_id TEXT, account_id TEXT, region TEXT, key TEXT, value TEXT);
CREATE TABLE dlm_policies(account_id TEXT, region TEXT, policy_id TEXT, description TEXT, state TEXT,
  policy_type TEXT, raw TEXT);
CREATE TABLE backup_plans(account_id TEXT, region TEXT, plan_id TEXT, plan_name TEXT, raw TEXT);
CREATE TABLE enrichment(kind TEXT, key TEXT, account_id TEXT, region TEXT, data TEXT);
CREATE VIEW volumes_full AS
  SELECT v.*, i.name AS instance_name, i.instance_type, i.state AS instance_state, i.platform AS instance_platform,
         (v.device = i.root_device) AS is_root, (v.instance_id IS NULL) AS is_unattached
  FROM volumes v LEFT JOIN instances i ON i.instance_id = v.instance_id;
CREATE VIEW snapshot_age AS
  SELECT s.*, CAST(julianday('now') - julianday(s.start_time) AS INT) AS age_days,
         (s.volume_id IS NOT NULL AND s.volume_id NOT IN (SELECT volume_id FROM volumes)) AS source_volume_gone
  FROM snapshots s;
CREATE VIEW volume_utilization AS
  SELECT v.*, m.mountpoint, m.fstype, m.used_bytes, m.size_bytes AS fs_size_bytes, m.used_pct, m.source AS util_source
  FROM volumes v LEFT JOIN utilization_mounts m ON m.volume_id = v.volume_id;
"""


def j(v):
    return json.dumps(v, separators=(",", ":")) if v is not None else None


def build(ws):
    path = os.path.join(ws, DB_FILE)
    if os.path.exists(path):
        os.remove(path)
    db = sqlite3.connect(path)
    db.executescript(SCHEMA)
    for r in read_jsonl(os.path.join(ws, DISCOVERY_FILE)):
        t = r.get("record_type")
        if t == "summary":
            db.execute("INSERT INTO scan_summary VALUES(?,?,?,?,?,?,?,?,?,?)", (
                r.get("tool_version"), r.get("scanned_at"), int(bool(r.get("interrupted"))),
                r.get("accounts_total"), r.get("accounts_scanned"), r.get("accounts_skipped"),
                r.get("accounts_failed"), r.get("regions_scanned"), r.get("regions_partial"),
                r.get("regions_failed")))
        elif t == "account":
            db.execute("INSERT INTO scan_gaps VALUES('account',?,NULL,?,?)",
                       (r.get("account_id"), r.get("status"), r.get("reason")))
        elif t == "region":
            a, g = r["account_id"], r["region"]
            if r.get("status") != "ok":
                db.execute("INSERT INTO scan_gaps VALUES('region',?,?,?,?)",
                           (a, g, r.get("status"), "; ".join(r.get("errors", []))))
            for v in r.get("volumes", []):
                db.execute("INSERT OR REPLACE INTO volumes VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (
                    v["VolumeId"], a, g, v.get("Name"), v.get("Size"), v.get("VolumeType"), v.get("State"),
                    v.get("Iops"), v.get("Throughput"), int(bool(v.get("Encrypted"))), v.get("AvailabilityZone"),
                    v.get("SnapshotId"), v.get("InstanceId"), v.get("Device"), j(v.get("Tags"))))
            for kind, rid_key, items in (("volume", "VolumeId", r.get("volumes", [])),
                                         ("instance", "InstanceId", r.get("instances", [])),
                                         ("snapshot", "SnapshotId", r.get("snapshots", []))):
                for it in items:
                    for t in it.get("Tags") or []:
                        db.execute("INSERT INTO tags VALUES(?,?,?,?,?,?)",
                                   (kind, it.get(rid_key), a, g, t.get("Key"), t.get("Value")))
            for d in r.get("dlm_policies", []):
                db.execute("INSERT INTO dlm_policies VALUES(?,?,?,?,?,?,?)", (
                    a, g, d.get("PolicyId"), d.get("Description"), d.get("State"), d.get("PolicyType"), j(d)))
            for b in r.get("backup_plans", []):
                db.execute("INSERT INTO backup_plans VALUES(?,?,?,?,?)", (
                    a, g, b.get("BackupPlanId"), b.get("BackupPlanName"), j(b)))
            for i in r.get("instances", []):
                db.execute("INSERT OR REPLACE INTO instances VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", (
                    i["InstanceId"], a, g, i.get("Name"), i.get("InstanceType"), i.get("State"),
                    i.get("PlatformDetails"), i.get("ImageId"), i.get("AvailabilityZone"),
                    i.get("RootDeviceName"), i.get("Architecture"), j(i.get("Tags"))))
            for s in r.get("snapshots", []):
                db.execute("INSERT INTO snapshots VALUES(?,?,?,?,?,?,?,?,?)", (
                    s.get("SnapshotId"), a, g, s.get("VolumeId"), s.get("VolumeSize", s.get("Size")),
                    s.get("StartTime"), s.get("State"), int(bool(s.get("Encrypted"))), j(s.get("Tags"))))
            for m in r.get("amis", []):
                db.execute("INSERT INTO amis VALUES(?,?,?,?,?,?)", (
                    m.get("ImageId"), a, g, m.get("Name"), m.get("PlatformDetails", m.get("Platform")),
                    m.get("Architecture")))
    for r in read_jsonl(os.path.join(ws, UTILIZATION_FILE)):
        if r.get("record_type") == "instance":
            db.execute("INSERT INTO utilization_instances VALUES(?,?,?,?,?,?,?)", (
                r.get("instance_id"), r.get("account_id"), r.get("region"), r.get("source"),
                r.get("status"), r.get("reason"), r.get("collected_at")))
            for m in r.get("mounts", []):
                db.execute("INSERT INTO utilization_mounts VALUES(?,?,?,?,?,?,?,?,?,?,?)", (
                    r.get("instance_id"), m.get("volume_id"), r.get("source"), m.get("mountpoint"),
                    m.get("device"), m.get("fstype"), m.get("size_bytes"), m.get("used_bytes"),
                    m.get("avail_bytes"), m.get("used_pct"), r.get("collected_at")))
    for r in read_jsonl(os.path.join(ws, ENRICHMENT_FILE)):
        db.execute("INSERT INTO enrichment VALUES(?,?,?,?,?)",
                   (r.get("kind"), r.get("key"), r.get("account_id"), r.get("region"), j(r.get("data"))))
    db.commit()
    counts = {t: db.execute("SELECT COUNT(*) FROM %s" % t).fetchone()[0]
              for t in ("volumes", "instances", "snapshots", "utilization_mounts")}
    db.close()
    return path, counts


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--workspace")
    a = ap.parse_args(argv)
    path, counts = build(workspace(a.workspace))
    log("built %s" % path)
    print(json.dumps(counts))


if __name__ == "__main__":
    main()
