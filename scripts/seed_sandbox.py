#!/usr/bin/env python3
"""
Seed a Square SANDBOX account with catalog data and orders.

Development utility, not part of the production pipeline. A fresh sandbox has
no catalog and no orders, so there is nothing for the extractor to pull. This
builds a realistic catalog (categories, items, SKUs, prices taken from the
real convention exports) and replays the transactions against it.

Known limitation: Square assigns `created_at` / `closed_at` server-side and
does not accept a backdated value. Seeded orders therefore carry today's
timestamp, not the original April 2026 dates. That is fine for exercising the
pipeline end to end; true historical timestamps only arrive with production
credentials.

Refuses to run against production — seeding real payment data would be
destructive.

Usage:
    python scripts/seed_sandbox.py --source "../RAW DATA" --dry-run
    python scripts/seed_sandbox.py --source "../RAW DATA"
"""

from __future__ import annotations

import argparse
import csv
import logging
import re
import sys
import uuid
from collections import OrderedDict, defaultdict
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

logging.basicConfig(level=logging.INFO, format="%(levelname)-8s %(message)s")
log = logging.getLogger("seed")

CARD_NONCE_OK = "cnon:card-nonce-ok"   # Square's sandbox test card
CATALOG_BATCH_SIZE = 200


def slug(text: str) -> str:
    return re.sub(r"[^a-zA-Z0-9]+", "_", (text or "none").strip().lower()).strip("_")


def cents(value: str) -> int:
    """'$20.00' -> 2000. Parenthesised values are refunds and become negative."""
    s = (value or "").strip()
    negative = s.startswith("(") and s.endswith(")")
    s = re.sub(r"[$,()]", "", s)
    amount = int((Decimal(s or "0") * 100).to_integral_value())
    return -amount if negative else amount


# ---------------------------------------------------------------------------
# Parse the source exports
# ---------------------------------------------------------------------------
def read_source(source_dir: Path):
    """Return (catalog_spec, transactions) derived from the CSV exports."""
    items: "OrderedDict[str, dict]" = OrderedDict()
    transactions: dict[str, list] = defaultdict(list)

    files = sorted(source_dir.glob("item_sakura_day*.csv"))
    if not files:
        sys.exit(f"No item_sakura_day*.csv found in {source_dir}")

    for path in files:
        with path.open() as fh:
            for row in csv.DictReader(fh):
                name = (row.get("Item") or "").strip()
                if not name:
                    continue

                sku = (row.get("SKU") or "").strip() or None
                nk = sku or name
                qty = row.get("Qty") or "1"
                unit_price = cents(row["Gross Sales"]) // max(int(float(qty)), 1)

                # The export writes the literal string "None" for items that
                # were rung up without a category. Creating a category actually
                # named "None" would bake that artefact into the catalog.
                category = (row.get("Category") or "").strip()
                if category.lower() in ("", "none"):
                    category = None

                if nk not in items:
                    items[nk] = {
                        "natural_key": nk,
                        "name": name,
                        "sku": sku,
                        "category": category,
                        "price_cents": max(unit_price, 0),
                    }

                transactions[row["Transaction ID"]].append(
                    {"natural_key": nk, "quantity": str(int(float(qty)))}
                )

    categories = sorted({i["category"] for i in items.values() if i["category"]})
    log.info("Parsed %d file(s): %d unique item(s), %d categor(ies), %d transaction(s)",
             len(files), len(items), len(categories), len(transactions))
    return categories, items, transactions


# ---------------------------------------------------------------------------
# Build catalog
# ---------------------------------------------------------------------------
def build_catalog_objects(categories: list[str], items: dict) -> list[dict]:
    """
    Square's batch_upsert accepts temporary client-side ids prefixed with '#'.
    Objects can reference each other by those temporary ids within one request;
    the response maps each to its permanent server id.
    """
    objects: list[dict] = [
        {
            "type": "CATEGORY",
            "id": f"#cat_{slug(name)}",
            "category_data": {"name": name},
        }
        for name in categories
    ]

    for item in items.values():
        item_id = f"#item_{slug(item['natural_key'])}"
        variation = {
            "type": "ITEM_VARIATION",
            "id": f"#var_{slug(item['natural_key'])}",
            "item_variation_data": {
                "item_id": item_id,
                "name": "Regular",
                "pricing_type": "FIXED_PRICING",
                "price_money": {"amount": item["price_cents"], "currency": "USD"},
            },
        }
        if item["sku"]:
            variation["item_variation_data"]["sku"] = item["sku"]

        item_data = {"name": item["name"], "variations": [variation]}
        if item["category"]:
            item_data["category_id"] = f"#cat_{slug(item['category'])}"

        objects.append({"type": "ITEM", "id": item_id, "item_data": item_data})

    return objects


def upsert_catalog(client, objects: list[dict]) -> dict[str, str]:
    """Upsert in batches; return {temporary_id: permanent_id}."""
    mapping: dict[str, str] = {}

    for start in range(0, len(objects), CATALOG_BATCH_SIZE):
        chunk = objects[start:start + CATALOG_BATCH_SIZE]
        response = client.catalog.batch_upsert(
            idempotency_key=str(uuid.uuid4()),
            batches=[{"objects": chunk}],
        )
        for entry in (response.id_mappings or []):
            mapping[entry.client_object_id] = entry.object_id
        log.info("Upserted catalog batch of %d object(s)", len(chunk))

    log.info("Catalog seeded: %d id mapping(s)", len(mapping))
    return mapping


# ---------------------------------------------------------------------------
# Create and pay orders
# ---------------------------------------------------------------------------
def create_orders(client, location_id: str, transactions: dict,
                  id_map: dict[str, str]) -> int:
    created = 0

    for index, (original_txn_id, lines) in enumerate(transactions.items(), start=1):
        line_items = []
        for line in lines:
            variation_id = id_map.get(f"#var_{slug(line['natural_key'])}")
            if not variation_id:
                log.warning("No catalog id for %s; skipping line", line["natural_key"])
                continue
            line_items.append({
                "catalog_object_id": variation_id,
                "quantity": line["quantity"],
            })

        if not line_items:
            continue

        # Deterministic idempotency keys: re-running the seed updates the same
        # orders instead of creating a second copy of the whole dataset.
        order_key = f"seed-order-{original_txn_id}"
        pay_key = f"seed-pay-{original_txn_id}"

        order_response = client.orders.create(
            idempotency_key=order_key,
            order={
                "location_id": location_id,
                "line_items": line_items,
                "reference_id": original_txn_id[:40],
                "state": "OPEN",
            },
        )
        order = order_response.order
        total = order.total_money.amount if order.total_money else 0

        if total > 0:
            # Paying the order transitions it to COMPLETED, which is the state
            # the extractor filters on. An unpaid order stays OPEN and would
            # never appear in the pipeline.
            client.payments.create(
                source_id=CARD_NONCE_OK,
                idempotency_key=pay_key,
                amount_money={"amount": total, "currency": "USD"},
                order_id=order.id,
                location_id=location_id,
                autocomplete=True,
            )

        created += 1
        if index % 10 == 0:
            log.info("  %d/%d orders created", index, len(transactions))

    log.info("Created and paid %d order(s)", created)
    return created


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", default="../RAW DATA")
    ap.add_argument("--dry-run", action="store_true",
                    help="parse and build payloads without calling Square")
    args = ap.parse_args()

    from config import get_settings, require

    settings = get_settings()
    require(settings, "SQUARE_ACCESS_TOKEN")

    environment = settings.get("SQUARE_ENVIRONMENT", "production").lower()
    if environment != "sandbox" and not args.dry_run:
        sys.exit("Refusing to seed a non-sandbox environment. "
                 "Set SQUARE_ENVIRONMENT=sandbox in your .env first.")

    categories, items, transactions = read_source(Path(args.source))
    objects = build_catalog_objects(categories, items)

    if args.dry_run:
        log.info("Dry run — %d catalog object(s) and %d order(s) would be created",
                 len(objects), len(transactions))
        sample = objects[len(categories)] if len(objects) > len(categories) else objects[0]
        log.info("Sample payload: %s", sample)
        return 0

    from square.client import Square
    from square.environment import SquareEnvironment

    client = Square(token=settings["SQUARE_ACCESS_TOKEN"],
                    environment=SquareEnvironment.SANDBOX, timeout=30.0)

    location_id = settings.get("SQUARE_LOCATION_ID")
    if not location_id:
        locations = client.locations.list().locations or []
        if not locations:
            sys.exit("No sandbox location found.")
        location_id = locations[0].id
    log.info("Seeding location %s", location_id)

    id_map = upsert_catalog(client, objects)
    create_orders(client, location_id, transactions, id_map)

    log.info("Done. Re-run scripts/test_square_connection.py to confirm.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
