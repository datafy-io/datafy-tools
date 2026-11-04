"""Shared helpers for the Datafy AWS Explorer scripts.

Design rules every script follows:
  * Nothing is ever sent to Datafy. The only hosts contacted are the customer's own
    AWS endpoints and github.com (to download the pinned scanner release).
  * Every billed AWS call goes through CostBudget, which refuses to exceed the cap.
  * Results are written to the workspace as they arrive, so an interrupted run keeps
    its data.
"""
import json
import os
import sys
from datetime import datetime, timezone

WORKSPACE_DIRNAME = "datafy-explorer"
DISCOVERY_FILE = "discovery.jsonl"
UTILIZATION_FILE = "utilization.jsonl"
ENRICHMENT_FILE = "enrichment.jsonl"
INVENTORY_FILE = "ssm_inventory.jsonl"
DB_FILE = "explorer.db"
DASHBOARD_FILE = "dashboard.html"
DECLINED_FILE = ".declined.json"

# Hard ceiling on AWS spend per run, in USD. Not user-overridable.
MAX_SPEND_USD = 1.00

# Sampling defaults.
SAMPLE_FRACTION = 0.05
SAMPLE_FLOOR = 10
SAMPLE_CEILING = 500


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg):
    """Progress goes to stderr; stdout is reserved for results."""
    print(msg, file=sys.stderr, flush=True)


def workspace(path=None, create=True):
    """Return the workspace dir, creating it (and a local .gitignore) if needed."""
    explicit = path or os.environ.get("DATAFY_WORKSPACE")
    root = os.path.abspath(explicit or WORKSPACE_DIRNAME)
    if not explicit:
        # Already inside the workspace (e.g. a script was run from there)? Use it, don't nest a second one.
        cwd = os.getcwd()
        if os.path.basename(cwd) == WORKSPACE_DIRNAME and (
                os.path.exists(os.path.join(cwd, DISCOVERY_FILE)) or os.path.exists(os.path.join(cwd, DB_FILE))):
            root = cwd
    if create:
        os.makedirs(root, exist_ok=True)
        gi = os.path.join(root, ".gitignore")
        if not os.path.exists(gi):
            with open(gi, "w") as f:
                f.write("# Customer data. Never commit.\n*\n")
    return root


def read_jsonl(path):
    out = []
    if not os.path.exists(path):
        return out
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except ValueError:
                continue
    return out


def append_jsonl(path, rec):
    """Append one record and flush, so an interrupt loses at most the line in flight."""
    with open(path, "a") as f:
        f.write(json.dumps(rec, separators=(",", ":")) + "\n")
        f.flush()


def read_discovery(ws):
    """Region records etc. from the scanner file (which is JSONL, one object per line)."""
    return read_jsonl(os.path.join(ws, DISCOVERY_FILE))


def ssm_reachable(ws):
    """Set of instance ids SSM can reach (online, Linux), or None if no inventory has been taken yet."""
    import os as _os
    path = _os.path.join(ws, INVENTORY_FILE)
    if not _os.path.exists(path):
        return None
    return {r["instance_id"] for r in read_jsonl(path)
            if r.get("record_type") == "ssm" and r.get("managed") and r.get("ping_status") == "Online"
            and r.get("platform_type") == "Linux"}


def volume_index(records):
    """{volume_id: {account_id, region, volume, instance}} from discovery records."""
    idx = {}
    for r in records:
        if r.get("record_type") != "region":
            continue
        insts = {i["InstanceId"]: i for i in r.get("instances", [])}
        for v in r.get("volumes", []):
            idx[v["VolumeId"]] = {
                "account_id": r["account_id"],
                "region": r["region"],
                "volume": v,
                "instance": insts.get(v.get("InstanceId")),
            }
    return idx


class BudgetExceeded(Exception):
    pass


class CostBudget:
    """Tracks billed AWS requests against a hard USD cap.

    Prices are deliberately rounded UP so the counter over-estimates, never under.
      GetMetricData: $0.01 per 1,000 metrics requested
      ListMetrics:   $0.01 per 1,000 requests
    Free calls (EC2 Describe*, SSM, Auto Scaling Describe*, Pricing) are not counted.
    """

    PRICE_PER_1000 = {"GetMetricData": 0.01, "ListMetrics": 0.01}

    def __init__(self, cap=MAX_SPEND_USD):
        self.cap = min(cap, MAX_SPEND_USD)  # the ceiling is not overridable
        self.spent = 0.0
        self.calls = {}

    def cost_of(self, api, units):
        return self.PRICE_PER_1000[api] * units / 1000.0

    def estimate(self, plan):
        """plan: {api: units}. Returns the total USD estimate."""
        return sum(self.cost_of(a, u) for a, u in plan.items())

    def can_afford(self, api, units):
        return self.spent + self.cost_of(api, units) <= self.cap + 1e-12

    def charge(self, api, units):
        if not self.can_afford(api, units):
            raise BudgetExceeded(
                "%s x%d would exceed the $%.2f cap (spent $%.4f)" % (api, units, self.cap, self.spent))
        self.spent += self.cost_of(api, units)
        self.calls[api] = self.calls.get(api, 0) + units

    def summary(self):
        return {"cap_usd": self.cap, "spent_usd": round(self.spent, 6), "billed_units": dict(self.calls)}
