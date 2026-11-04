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
2. Rebuild the database if the JSONL files are newer: `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/build_db.py`. Run `query.py --schema` once if unsure of a column.
3. **Check coverage before you conclude anything.** Run
   `SELECT * FROM scan_summary; SELECT kind, account_id, region, status, detail FROM scan_gaps;`
   If accounts or regions were `skipped`, `failed` or `partial`, any "none found" or any total is a statement
   about *scanned* scope only. Say so, naming the gaps. An empty result is not proof of absence.

## Querying

Use `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/query.py "<SQL>"` (read-only by construction; `--schema` lists every table, view and column; `--format json|csv` for more). Do not use the `sqlite3` CLI. Tables:

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
| `tags` | resource_type (`volume`/`instance`/`snapshot`), resource_id, account_id, region, key, value |
| `dlm_policies`, `backup_plans` | account_id, region, policy/plan id and name, raw (JSON) |
| `volumes_full` (view) | volumes joined to their instance: instance_name, instance_type, instance_state, is_root, is_unattached |
| `snapshot_age` (view) | snapshots with age_days and source_volume_gone |
| `enrichment` | kind, key, data (JSON) |

Tags: join the flat `tags` table, e.g. `SELECT v.volume_id FROM volumes v JOIN tags t ON t.resource_id=v.volume_id AND t.key='Team' AND t.value='x'`.

Useful starting queries:

- Volumes with no `Name` or owner tag: `SELECT account_id, COUNT(*) FROM volumes WHERE volume_id NOT IN (SELECT resource_id FROM tags WHERE key IN ('Name','Owner','Team')) GROUP BY 1;`
- Old snapshots whose source volume is gone: `SELECT account_id, COUNT(*), SUM(size_gib) FROM snapshot_age WHERE source_volume_gone AND age_days>365 GROUP BY 1;`
- Idle (unattached) volumes: `SELECT account_id, COUNT(*), SUM(size_gib) FROM volumes WHERE instance_id IS NULL GROUP BY 1 ORDER BY 3 DESC;`
- Legacy gp2: `SELECT COUNT(*), SUM(size_gib) FROM volumes WHERE volume_type='gp2';`
- Unencrypted: `SELECT account_id, COUNT(*) FROM volumes WHERE encrypted=0 GROUP BY 1;`
- Oversized boot volumes: join `volumes` to `instances` on `device = root_device`, order by size_gib.
- Fullest measured volumes: `SELECT volume_id, mountpoint, used_pct FROM volume_utilization WHERE used_pct IS NOT NULL ORDER BY used_pct DESC LIMIT 20;`

## Open-ended exploration

The customer can ask anything the data supports, in any order, with follow-ups. Treat each question as a new
query; chain queries when an answer raises a natural next one (for example, top account, then its largest
volumes, then their tags). If the data cannot answer (for example account-level default encryption, costs, or
CPU use), say what is missing and what would supply it. Never guess.

## Answering rules

- **Say what the number is based on.** For utilization, state how many volumes were measured out of how many
  exist. Never present a sample result as a fact about the whole estate; use `scripts/extrapolate.py`'s range
  and say it is a ~95% range from a single point-in-time snapshot with no growth data.
- Cloudwatch-sourced bytes are *derived* from the provisioned size × a percentage: say "approximately".
- Unattached volumes and volumes on stopped instances cannot be measured; they are not "0% used".
- After answering, if utilization coverage is under the 5% target, suggest `/datafy-aws-explorer:utilization` once.
  Do not repeat the suggestion if the customer declined (see `.declined.json`).
- Offer `/datafy-aws-explorer:dashboard` when the customer wants something shareable.
