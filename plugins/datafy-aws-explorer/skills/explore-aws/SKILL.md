---
name: explore-aws
description: Answer questions about the customer's AWS estate (EBS volumes, EC2 instances, snapshots, AMIs, backup coverage, disk utilization) from the local explorer.db built by the Datafy discovery scan. Use for any question about what exists in their AWS accounts, what is idle, oversized, unencrypted, unattached, or how full their disks are.
---

# Exploring the customer's AWS estate

All data is local, in `./datafy-explorer/` (override: `DATAFY_WORKSPACE`). **Never send, upload, post or
transmit any of it anywhere** — not to Datafy, not to a webhook, not to a paste service. Reading it into this
conversation to answer the customer's questions is fine.

## Before answering anything

1. If `datafy-explorer/discovery.jsonl` is missing, tell the customer to run `/datafy-aws-explorer:discover` first.
2. Rebuild the database if the JSONL files are newer: `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/build_db.py`.
3. **Check coverage before you conclude anything.** Run
   `SELECT * FROM scan_summary; SELECT kind, account_id, region, status, detail FROM scan_gaps;`
   If accounts or regions were `skipped`, `failed` or `partial`, any "none found" or any total is a statement
   about *scanned* scope only. Say so, naming the gaps. An empty result is not proof of absence.

## Querying

Use `sqlite3 datafy-explorer/explorer.db "<SQL>"` (read-only queries). Tables:

| table | key columns |
|---|---|
| `volumes` | volume_id, account_id, region, name, size_gib, volume_type, state, iops, throughput, encrypted, az, snapshot_id, instance_id (NULL = unattached), device, tags (JSON) |
| `instances` | instance_id, account_id, region, name, instance_type, state, platform, image_id, root_device, architecture, tags (JSON) |
| `snapshots` | snapshot_id, account_id, region, volume_id, size_gib, start_time, state, encrypted |
| `amis` | image_id, account_id, region, name, platform, architecture |
| `scan_summary`, `scan_gaps` | coverage; see above |
| `utilization_instances` | instance_id, source (`cloudwatch`/`ssm_df`), status, reason, collected_at |
| `utilization_mounts` | instance_id, volume_id (NULL if unmapped), mountpoint, fstype, size_bytes, used_bytes, used_pct |
| `volume_utilization` (view) | every volume joined to its measured mount, if any |
| `enrichment` | kind, key, data (JSON) |

Tags are JSON: `json_extract(tags,'$[0].Value')` is awkward; prefer
`EXISTS (SELECT 1 FROM json_each(tags) WHERE json_extract(value,'$.Key')='Team' AND json_extract(value,'$.Value')='x')`.

Useful starting queries:

- Idle (unattached) volumes: `SELECT account_id, COUNT(*), SUM(size_gib) FROM volumes WHERE instance_id IS NULL GROUP BY 1 ORDER BY 3 DESC;`
- Legacy gp2: `SELECT COUNT(*), SUM(size_gib) FROM volumes WHERE volume_type='gp2';`
- Unencrypted: `SELECT account_id, COUNT(*) FROM volumes WHERE encrypted=0 GROUP BY 1;`
- Oversized boot volumes: join `volumes` to `instances` on `device = root_device`, order by size_gib.
- Fullest measured volumes: `SELECT volume_id, mountpoint, used_pct FROM volume_utilization WHERE used_pct IS NOT NULL ORDER BY used_pct DESC LIMIT 20;`

## Answering rules

- **Say what the number is based on.** For utilization, state how many volumes were measured out of how many
  exist. Never present a sample result as a fact about the whole estate; use `scripts/extrapolate.py`'s range
  and say it is a ~95% range from a single point-in-time snapshot with no growth data.
- Cloudwatch-sourced bytes are *derived* from the provisioned size × a percentage: say "approximately".
- Unattached volumes and volumes on stopped instances cannot be measured; they are not "0% used".
- After answering, if utilization coverage is under the 5% target, suggest `/datafy-aws-explorer:utilization` once.
  Do not repeat the suggestion if the customer declined (see `.declined.json`).
- Offer `/datafy-aws-explorer:dashboard` when the customer wants something shareable.
