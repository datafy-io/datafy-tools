"""Guards for the promises the plugin makes to customers. These fail the build if broken."""
import ast
import glob
import os
import re
import unittest

from helpers import ROOT

SCRIPTS = sorted(glob.glob(os.path.join(ROOT, "scripts", "*.py")))
ALLOWED_URL = re.compile(r"^https://github\.com/datafy-io/")
BILLED_METHODS = {"get_metric_data", "list_metrics", "get_metric_statistics", "get_cost_and_usage"}
FORBIDDEN_MODULES = {"requests", "socket", "http", "httpx", "aiohttp", "smtplib", "ftplib", "telnetlib", "webbrowser"}
FORBIDDEN_CLIENTS = {"ce", "s3", "athena", "logs", "sns", "sqs"}  # no billed side channels, no uploads


def src(path):
    return open(path).read()


class NoCallingHome(unittest.TestCase):
    def test_only_fetch_scanner_may_use_the_network(self):
        for p in SCRIPTS:
            tree = ast.parse(src(p))
            for n in ast.walk(tree):
                mods = []
                if isinstance(n, ast.Import):
                    mods = [a.name.split(".")[0] for a in n.names]
                elif isinstance(n, ast.ImportFrom) and n.module:
                    mods = [n.module.split(".")[0]]
                for m in mods:
                    self.assertNotIn(m, FORBIDDEN_MODULES, "%s imports %s" % (os.path.basename(p), m))
                    if m == "urllib":
                        self.assertEqual(os.path.basename(p), "fetch_scanner.py", "urllib outside fetch_scanner")

    def test_no_urls_except_the_datafy_release_host(self):
        for p in SCRIPTS + glob.glob(os.path.join(ROOT, "scanner.lock.json")):
            for url in re.findall(r"https?://[^\s\"'<>)]+", src(p)):
                if "%s" in url or url.endswith("://"):
                    continue
                self.assertRegex(url, ALLOWED_URL, "%s contacts %s" % (os.path.basename(p), url))

    def test_only_expected_aws_clients(self):
        for p in SCRIPTS:
            for m in re.finditer(r"\.client\(\s*[\"'](\w+)[\"']", src(p)):
                self.assertNotIn(m.group(1), FORBIDDEN_CLIENTS, os.path.basename(p))

    def test_dashboard_template_blocks_network(self):
        tpl = os.path.join(ROOT, "templates", "dashboard.html")
        if os.path.exists(tpl):
            self.assertIn("connect-src 'none'", src(tpl))


class BilledCallsAreBudgeted(unittest.TestCase):
    def test_billed_apis_only_in_the_collector(self):
        for p in SCRIPTS:
            if os.path.basename(p) == "collect_utilization.py":
                continue
            for meth in BILLED_METHODS:
                self.assertNotIn(meth, src(p), "%s calls billed %s" % (os.path.basename(p), meth))

    def test_every_billed_call_is_preceded_by_a_budget_charge(self):
        lines = src(os.path.join(ROOT, "scripts", "collect_utilization.py")).splitlines()
        for i, l in enumerate(lines):
            if re.search(r"\.(get_metric_data|list_metrics)\(", l) and "def " not in l:
                # the charge happens in the caller, before the helper that makes the call
                helper = next(j for j in range(i, 0, -1) if lines[j].startswith("def "))
                name = re.match(r"def (\w+)", lines[helper]).group(1)
                callers = [k for k, x in enumerate(lines) if re.search(r"\b%s\(" % name, x) and not x.startswith("def ")]
                self.assertTrue(callers, name)
                for k in callers:
                    window = "\n".join(lines[max(0, k - 3):k])
                    self.assertIn("budget.charge(", window, "%s() called without a preceding budget.charge" % name)

    def test_budget_ceiling_constant(self):
        import common
        self.assertLessEqual(common.MAX_SPEND_USD, 1.0)


class WorkspaceIsNeverCommitted(unittest.TestCase):
    def test_workspace_gitignore_is_created(self):
        import tempfile
        import common
        d = os.path.join(tempfile.mkdtemp(), "ws")
        common.workspace(d)
        self.assertIn("*", open(os.path.join(d, ".gitignore")).read())


if __name__ == "__main__":
    unittest.main()
