#!/usr/bin/env python3
"""Run a READ-ONLY SQL query against the local explorer.db.

  query.py "SELECT account_id, COUNT(*) FROM volumes GROUP BY 1"
  query.py --schema            tables, views and columns
  query.py --format json|table|csv   (default table)   --limit N (default 200)

The database is opened read-only, so a query cannot change or delete anything. Pure Python
stdlib: no sqlite3 CLI needed. Rows go to stdout; nothing leaves the machine.
"""
import argparse
import csv
import json
import os
import sqlite3
import sys

from common import DB_FILE, workspace


_ALLOWED = {sqlite3.SQLITE_SELECT, sqlite3.SQLITE_READ, sqlite3.SQLITE_FUNCTION, sqlite3.SQLITE_RECURSIVE}
_ALLOWED_PRAGMAS = {"table_info", "table_xinfo"}


def _authorize(action, arg1, arg2, dbname, source):
    """Reads only. Denies ATTACH/DETACH (which could touch other files), writes, DDL and most PRAGMAs."""
    if action in _ALLOWED:
        return sqlite3.SQLITE_OK
    if action == sqlite3.SQLITE_PRAGMA and (arg1 or "").lower() in _ALLOWED_PRAGMAS:
        return sqlite3.SQLITE_OK
    return sqlite3.SQLITE_DENY


def connect(ws):
    path = os.path.join(ws, DB_FILE)
    if not os.path.exists(path):
        raise SystemExit("no %s yet. Run discovery first, then build_db.py" % DB_FILE)
    db = sqlite3.connect("file:%s?mode=ro" % path, uri=True)
    db.execute("PRAGMA query_only = ON")
    db.set_authorizer(_authorize)
    return db


def schema(db):
    out = []
    for name, kind in db.execute("SELECT name, type FROM sqlite_master WHERE type IN ('table','view') ORDER BY type, name"):
        cols = [r[1] + " " + (r[2] or "") for r in db.execute("PRAGMA table_info(%s)" % name)]
        n = db.execute("SELECT COUNT(*) FROM %s" % name).fetchone()[0]
        out.append("%s %s (%d rows): %s" % (kind.upper(), name, n, ", ".join(c.strip() for c in cols)))
    return "\n".join(out)


def run(db, sql, limit):
    cur = db.execute(sql)
    cols = [d[0] for d in cur.description or []]
    rows = cur.fetchmany(limit + 1)
    return cols, rows[:limit], len(rows) > limit


def render(cols, rows, fmt):
    if fmt == "json":
        return json.dumps([dict(zip(cols, r)) for r in rows], default=str)
    if fmt == "csv":
        import io
        b = io.StringIO()
        w = csv.writer(b)
        w.writerow(cols)
        w.writerows(rows)
        return b.getvalue()
    cells = [[("" if v is None else str(v)) for v in r] for r in rows]
    widths = [max([len(c)] + [len(r[i]) for r in cells]) for i, c in enumerate(cols)]
    line = lambda r: "  ".join(v.ljust(widths[i]) for i, v in enumerate(r))
    return "\n".join([line(cols), line(["-" * w for w in widths])] + [line(r) for r in cells])


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("sql", nargs="?")
    ap.add_argument("--workspace")
    ap.add_argument("--schema", action="store_true")
    ap.add_argument("--format", choices=["table", "json", "csv"], default="table")
    ap.add_argument("--limit", type=int, default=200)
    a = ap.parse_args(argv)
    db = connect(workspace(a.workspace, create=False))
    if a.schema:
        print(schema(db))
        return
    if not a.sql:
        ap.error("give a SQL query or --schema")
    try:
        cols, rows, truncated = run(db, a.sql, a.limit)
    except sqlite3.Error as e:
        raise SystemExit("query failed: %s" % e)
    print(render(cols, rows, a.format))
    if truncated:
        print("-- truncated at %d rows; add a LIMIT or aggregate" % a.limit, file=sys.stderr)


if __name__ == "__main__":
    main()
