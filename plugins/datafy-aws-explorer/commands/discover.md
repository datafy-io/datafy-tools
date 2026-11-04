---
description: Run the read-only Datafy discovery scan against your AWS Organization, then summarize coverage
argument-hint: "[--profile NAME] [--setup-role] [--include ACCOUNTS] [--exclude ACCOUNTS]"
---

Run the discovery scan. Everything stays on this machine; nothing is sent to Datafy.

1. Confirm who we are scanning as: `aws sts get-caller-identity` (add `--profile` if given in $ARGUMENTS). Tell the
   customer the account and that the scan is read-only. Explain the access option in use:
   default `OrganizationAccountAccessRole`, or `--setup-role` (temporary StackSet role, always removed) — see the
   README next to the scanner if they are unsure. Ask before using `--setup-role`.
2. Fetch the pinned, checksum-verified scanner:
   `SCANNER=$(python3 ${CLAUDE_PLUGIN_ROOT}/scripts/fetch_scanner.py)`
3. Run it (a `.py` scanner runs with `python3`, a binary directly), writing into the workspace:
   `mkdir -p datafy-explorer && "$SCANNER" $ARGUMENTS --output datafy-explorer/discovery.jsonl`
   The scan can take minutes on large organizations; progress is on stderr.
4. `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/build_db.py`
5. Report **coverage first**: the `scan_summary` row and `scan_gaps`. Never present totals without naming
   any skipped/failed/partial scope.
6. Then a short overview (volumes and GiB, instances, top accounts, unattached GiB, gp2 share), and end with
   the utilization offer from the `disk-utilization` skill: size alone is an estimate; measuring a 5% sample
   would firm it up. Ask once; accept "no".
7. Tell the customer they can now **ask anything about their estate in this session**, in plain language, and give
   five tailored examples from what you just saw, such as: "which accounts have the most unattached volumes?",
   "show unencrypted volumes in account X", "which snapshots are older than a year and have no source volume?",
   "what instance types have the biggest boot volumes?", "which volumes have no owner tag?". Mention that a
   shareable page is available with `/datafy-aws-explorer:dashboard` but is optional.
