#!/usr/bin/env python3
"""
Smoke test for the Square API credentials — no Postgres required.

Confirms that SQUARE_ACCESS_TOKEN (from .env, Secrets Manager, or the shell
environment) actually authenticates and can see locations, catalog, and
orders. Run this before touching the database at all, so a credential problem
and a database problem never get confused with each other.

Usage:
    python scripts/test_square_connection.py
"""

from __future__ import annotations

import logging
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

logging.basicConfig(level=logging.INFO, format="%(levelname)-8s %(message)s")
log = logging.getLogger("smoke_test")


def main() -> int:
    from config import get_settings, require
    from square_extract import SquareExtractor, ExtractWindow

    settings = get_settings()
    require(settings, "SQUARE_ACCESS_TOKEN")

    env = settings.get("SQUARE_ENVIRONMENT", "production")
    print(f"\nTesting against Square {env.upper()}\n" + "-" * 40)

    extractor = SquareExtractor(
        token=settings["SQUARE_ACCESS_TOKEN"],
        environment=env,
        location_id=settings.get("SQUARE_LOCATION_ID"),
    )

    print("\n[1/3] Locations")
    ids = extractor.location_ids()
    if not ids:
        print("  No locations found. In a fresh sandbox, create one from the "
              "Developer Dashboard under Sandbox Test Accounts.")
        return 1
    print(f"  OK — {len(ids)} location(s): {ids}")

    print("\n[2/3] Catalog")
    catalog = extractor.catalog_lookup()
    print(f"  OK — {len(catalog)} item variation(s) resolved")
    if not catalog:
        print("  Catalog is empty. Add a test item in the Sandbox Dashboard "
              "or via the Catalog API before running the full pipeline.")

    print("\n[3/3] Orders (full history — this is a one-time check, not the "
          "incremental window the real pipeline uses)")
    orders = extractor.fetch_orders(ExtractWindow.backfill(), ids)
    print(f"  OK — {len(orders)} order(s) found")
    if orders:
        records = extractor.to_line_items(orders, catalog)
        print(f"       -> {len(records)} line item(s) after flattening")
        sample = records[0]
        print(f"       sample: {sample['item']!r} x{sample['qty']} "
              f"= ${sample['net_sales']} on {sample['sale_date']}")
    else:
        print("  No orders yet. If this is a brand-new sandbox, generate a "
              "test payment from the Developer Dashboard first.")

    print("\nSquare connection verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
