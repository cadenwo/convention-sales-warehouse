#!/usr/bin/env python3
"""
Export the star schema to CSV for a BI tool that cannot reach Redshift.

    python scripts/export_star_schema.py

Tableau Desktop Public Edition and Desktop Free Edition connect to files and
local databases, not to cloud-hosted warehouses. This dumps the marts so those
tools can read what the pipeline built.

Writes to exports/, which is gitignored — these files carry the booth's actual
revenue, and the published dashboard indexes it deliberately. Keep them local.

Not part of the scheduled pipeline. A hand-run utility, which is why it lives
in scripts/ rather than being wired into run_pipeline.py.
"""

from __future__ import annotations

import csv
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from config import get_settings  # noqa: E402

EXPORT_DIR = Path(__file__).resolve().parent.parent / "exports"

# dim_date first so a human opening the folder meets the grain before the facts.
TABLES = [
    ("warehouse.dim_date", "dim_date.csv"),
    ("warehouse.dim_category", "dim_category.csv"),
    ("warehouse.dim_item", "dim_item.csv"),
    ("warehouse.fact_sales_line", "fact_sales_line.csv"),
    ("warehouse.fact_item_daily", "fact_item_daily.csv"),
    ("warehouse.fact_item_pairs", "fact_item_pairs.csv"),
    ("warehouse.bridge_item_pair", "bridge_item_pair.csv"),
]

# Never leaves the warehouse. These columns feed no chart and are dropped here
# rather than relying on someone remembering to hide them in the BI tool.
EXCLUDE_COLUMNS = {"location_id", "device_name_key"}


def main() -> int:
    import psycopg2

    settings = get_settings()
    EXPORT_DIR.mkdir(exist_ok=True)

    conn = psycopg2.connect(
        host=settings["PGHOST"],
        port=settings.get("PGPORT", "5439"),
        dbname=settings["PGDATABASE"],
        user=settings["PGUSER"],
        password=settings["PGPASSWORD"],
        sslmode=settings.get("PGSSLMODE", "require"),
        connect_timeout=60,
    )

    try:
        for table, filename in TABLES:
            with conn.cursor() as cur:
                cur.execute(f"SELECT * FROM {table}")
                names = [d[0] for d in cur.description]
                keep = [i for i, n in enumerate(names) if n not in EXCLUDE_COLUMNS]
                rows = cur.fetchall()

            path = EXPORT_DIR / filename
            with path.open("w", newline="") as fh:
                writer = csv.writer(fh)
                writer.writerow([names[i] for i in keep])
                for row in rows:
                    writer.writerow([row[i] for i in keep])

            dropped = sorted(set(names) & EXCLUDE_COLUMNS)
            note = f"  (dropped {', '.join(dropped)})" if dropped else ""
            print(f"{filename:24} {len(rows):>5} rows{note}")
    finally:
        conn.close()

    print(f"\nWrote to {EXPORT_DIR}")
    # Tableau relationships must form a tree. These six edges are the whole
    # model; adding a seventh (fact_item_daily to dim_date, say) makes a loop
    # and Tableau refuses it.
    print("Relate them in Tableau as a tree, no loops:")
    print("  fact_sales_line  - dim_date          on date_key")
    print("  fact_sales_line  - dim_item          on item_key")
    print("  dim_item         - dim_category      on category_key")
    print("  dim_item         - fact_item_daily   on item_key")
    print("  dim_item         - bridge_item_pair  on item_key")
    print("  bridge_item_pair - fact_item_pairs   on item_pair_key")
    return 0


if __name__ == "__main__":
    sys.exit(main())
