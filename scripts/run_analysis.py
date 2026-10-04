#!/usr/bin/env python3
"""
Run the analysis queries against the warehouse and print the results.

The queries live in sql/03_analysis.sql, one per numbered block. Keeping them
in a plain .sql file rather than embedded in Python means they can be pasted
straight into a SQL console, a BI tool, or an interview screen-share without
untangling them from application code.

    python scripts/run_analysis.py           # all queries
    python scripts/run_analysis.py --only 7  # just the velocity query
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

SQL_FILE = Path(__file__).resolve().parent.parent / "sql" / "03_analysis.sql"


def parse_queries(sql: str) -> list[tuple[str, str]]:
    """
    Split the analysis file into (title, sql) pairs.

    Each block starts with a numbered comment banner; the title is taken from
    that line so output is labelled without duplicating the names here.
    """
    blocks, title, body = [], None, []

    for line in sql.splitlines():
        heading = re.match(r"^--\s*(\d+\..+)$", line.strip())
        if heading:
            if title and any(l.strip() for l in body):
                blocks.append((title, "\n".join(body)))
            title, body = heading.group(1).strip(), []
            continue
        if not line.strip().startswith("--"):
            body.append(line)

    if title and any(l.strip() for l in body):
        blocks.append((title, "\n".join(body)))

    return [(t, q.strip().rstrip(";")) for t, q in blocks if q.strip().rstrip(";")]


def render(cursor) -> str:
    """Format a result set as a simple aligned table."""
    if not cursor.description:
        return "  (no rows)"

    cols = [d.name for d in cursor.description]
    rows = [[("" if v is None else str(v)) for v in row] for row in cursor.fetchall()]
    if not rows:
        return "  (no rows)"

    widths = [max(len(c), *(len(r[i]) for r in rows)) for i, c in enumerate(cols)]
    out = ["  " + "  ".join(c.ljust(widths[i]) for i, c in enumerate(cols)),
           "  " + "  ".join("-" * w for w in widths)]
    out += ["  " + "  ".join(r[i].ljust(widths[i]) for i in range(len(cols)))
            for r in rows]
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", type=int, help="run only the query with this number")
    args = ap.parse_args()

    from config import get_settings, require
    import psycopg2

    settings = get_settings()
    require(settings, "PGHOST", "PGDATABASE", "PGUSER", "PGPASSWORD")

    queries = parse_queries(SQL_FILE.read_text())
    if args.only:
        queries = [q for q in queries if q[0].startswith(f"{args.only}.")]
        if not queries:
            sys.exit(f"No query numbered {args.only} in {SQL_FILE.name}")

    conn = psycopg2.connect(
        host=settings["PGHOST"], port=settings.get("PGPORT", "5439"),
        dbname=settings["PGDATABASE"], user=settings["PGUSER"],
        password=settings["PGPASSWORD"],
        sslmode=settings.get("PGSSLMODE", "require"), connect_timeout=30,
    )

    try:
        for title, sql in queries:
            print(f"\n{'=' * 72}\n{title}\n{'=' * 72}")
            with conn.cursor() as cur:
                try:
                    cur.execute(sql)
                    print(render(cur))
                except Exception as exc:
                    conn.rollback()
                    print(f"  FAILED: {exc}")
    finally:
        conn.close()

    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
