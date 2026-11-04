import contextlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts"))

import build_dashboard as bd  # noqa: E402

FIX = os.path.join(HERE, "fixtures")
CSP = ("default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; font-src data:; "
       "img-src data: blob:; connect-src 'none'; form-action 'none'; base-uri 'none'")


def make_ws(with_util=True, mutate_discovery=None):
    ws = tempfile.mkdtemp(prefix="dash-ws-")
    text = open(os.path.join(FIX, "discovery.jsonl")).read()
    if mutate_discovery:
        text = mutate_discovery(text)
    open(os.path.join(ws, "discovery.jsonl"), "w").write(text)
    if with_util:
        shutil.copy(os.path.join(FIX, "utilization.jsonl"), os.path.join(ws, "utilization.jsonl"))
    return ws


def build(ws):
    out = os.path.join(ws, "dashboard.html")
    with contextlib.redirect_stdout(io.StringIO()):
        bd.main(["--workspace", ws, "--out", out])
    return open(out, encoding="utf-8").read()


def scripts_of(html):
    """Inline <script> bodies (the template's own, plus the embed)."""
    return re.findall(r"<script>(.*?)</script>", html, re.S)


class TestDashboard(unittest.TestCase):
    def test_embed_present_and_csp_unchanged(self):
        html = build(make_ws())
        self.assertIn("window.__DATAFY_EMBED__=", html)
        self.assertIn('<meta http-equiv="Content-Security-Policy" content="%s">' % CSP, html)
        # the page's own policy, plus the identical one the template writes into the shareable report
        tpl = open(bd.TEMPLATE, encoding="utf-8").read()
        self.assertEqual(html.count("Content-Security-Policy"), tpl.count("Content-Security-Policy"))
        self.assertEqual(html.count("connect-src 'none'"), tpl.count("connect-src 'none'"))

    def test_embed_precedes_main_script(self):
        html = build(make_ws())
        self.assertLess(html.index("window.__DATAFY_EMBED__="), html.index("'use strict';"))

    def test_no_network_capable_code(self):
        html = build(make_ws())
        code = "\n".join(scripts_of(html))
        for needle in (r"\bfetch\s*\(", r"XMLHttpRequest", r"\bimport\s*\(", r"WebSocket", r"EventSource",
                       r"sendBeacon", r"new\s+Image\b", r"importScripts", r"<link\b", r"<iframe\b"):
            self.assertIsNone(re.search(needle, code), needle)
        self.assertNotIn("<script src", html)

    def test_http_strings_only_where_template_had_them(self):
        """Any http(s) URL in script code must be one v4 already had: release downloads, site links."""
        html = build(make_ws())
        embed, *rest = scripts_of(html)
        code = "\n".join(rest)
        allowed = ("https://github.com/datafy-io/datafy-tools/releases/download/", "https://datafy.io",
                   "http://www.w3.org/2000/svg")  # an XML namespace name, never fetched
        for url in re.findall(r"https?://[^\s'\"<>)]+", code):
            self.assertTrue(url.startswith(allowed), url)

    def test_script_breakout_is_escaped(self):
        html = build(make_ws())
        embed = html[html.index("window.__DATAFY_EMBED__="):html.index("</script>", html.index("window.__DATAFY_EMBED__="))]
        self.assertNotIn("</", embed)
        self.assertNotIn("<", embed)
        data = json.loads(embed[len("window.__DATAFY_EMBED__="):].rstrip(";"))
        self.assertIn("web</script>", data["discovery"])  # present after decoding, not before

    def test_line_separators_escaped(self):
        s = bd.js_json({"a": "x y z"})
        self.assertNotIn(" ", s)
        self.assertNotIn(" ", s)
        self.assertEqual(json.loads(s)["a"], "x y z")

    def test_discovery_only(self):
        ws = make_ws(with_util=False)
        html = build(ws)
        data = _embed(html)
        self.assertEqual(data["utilization"], [])
        self.assertIsNone(data["estimate"]["range"])
        self.assertEqual(data["estimate"]["measured"], 0)
        self.assertEqual(data["sample"]["population"], 24)
        self.assertEqual(data["sample"]["target"], 10)  # 5% of 24 is 2, floored at 10

    def test_with_utilization(self):
        data = _embed(build(make_ws()))
        self.assertEqual(len(data["utilization"]), 9)
        est = data["estimate"]
        self.assertEqual(est["measured"], 10)
        self.assertIsNotNone(est["range"])
        lo, hi = est["range"]["used_pct"]
        self.assertLessEqual(lo, hi)
        self.assertGreaterEqual(lo, 0)
        self.assertLessEqual(hi, 100)

    def test_sample_json_target_wins(self):
        ws = make_ws()
        json.dump({"target": 17}, open(os.path.join(ws, "sample.json"), "w"))
        self.assertEqual(_embed(build(ws))["sample"]["target"], 17)

    def test_missing_discovery_is_an_error(self):
        ws = tempfile.mkdtemp()
        with self.assertRaises(SystemExit):
            bd.main(["--workspace", ws])

    def test_measured_pct_takes_largest_filesystem(self):
        recs = [{"record_type": "instance", "status": "ok", "mounts": [
            {"volume_id": "vol-a", "used_pct": 10, "size_bytes": 5},
            {"volume_id": "vol-a", "used_pct": 90, "size_bytes": 50}]},
            {"record_type": "instance", "status": "failed", "mounts": [{"volume_id": "vol-b", "used_pct": 1}]}]
        self.assertEqual(bd.measured_pct(recs), {"vol-a": 90})

    def test_template_pins_match_lock(self):
        lock = json.load(open(os.path.join(HERE, "..", "scanner.lock.json")))
        tpl = open(bd.TEMPLATE, encoding="utf-8").read()
        self.assertIn("const DISCOVERY_RELEASE = '%s';" % lock["release"], tpl)
        self.assertIn("const DISCOVERY_RELEASE_AWS_TOOL_VERSION = '%s';" % lock["tool_version"], tpl)

    @unittest.skipUnless(shutil.which("node"), "node not installed")
    def test_script_syntax(self):
        html = build(make_ws())
        main = max(scripts_of(html), key=len)
        d = tempfile.mkdtemp()
        p = os.path.join(d, "page.js")
        open(p, "w").write(main)
        r = subprocess.run(["node", "--check", p], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)


def _embed(html):
    i = html.index("window.__DATAFY_EMBED__=") + len("window.__DATAFY_EMBED__=")
    return json.loads(html[i:html.index(";</script>", i)])


if __name__ == "__main__":
    unittest.main()
