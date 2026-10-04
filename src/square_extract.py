"""
Square API extraction layer.

Pulls orders (and the catalog needed to label them) from the Square Connect API
and flattens them to one record per line item, matching the shape the existing
staging table expects.

Three things this handles that a naive `requests.get` would not:

  * Pagination — Square returns at most a few hundred orders per response and a
    cursor for the next page. A single busy convention day exceeds one page, so
    dropping the cursor loop silently truncates the data.
  * Rate limiting and transient failure — Square returns 429 when you query too
    fast and 5xx during incidents. Both are retryable; giving up on the first
    one loses a day of data.
  * Incremental windows — pulling the full history on every scheduled run is
    wasteful and gets slower forever. The default is a 24-hour window.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from zoneinfo import ZoneInfo

import httpx
from square.client import Square
from square.environment import SquareEnvironment
from square.core.api_error import ApiError
from tenacity import (
    retry,
    retry_if_exception,
    stop_after_attempt,
    wait_exponential,
    before_sleep_log,
)

log = logging.getLogger(__name__)

ORDERS_PAGE_LIMIT = 500      # Square's maximum for SearchOrders
RETRYABLE_STATUS = {429, 500, 502, 503, 504}


def _is_retryable(exc: BaseException) -> bool:
    """
    Retry on transport failures and on Square's throttling / server errors.
    A 401 or 400 is a bug or a bad token — retrying those just wastes time and
    hides the real problem.
    """
    if isinstance(exc, (httpx.TimeoutException, httpx.NetworkError)):
        return True
    if isinstance(exc, ApiError):
        return exc.status_code in RETRYABLE_STATUS
    return False


# Exponential backoff: ~2s, 4s, 8s, 16s, 30s. Square's rate limit window is
# short, so five attempts across ~60s clears almost all throttling.
retry_square = retry(
    retry=retry_if_exception(_is_retryable),
    wait=wait_exponential(multiplier=2, min=2, max=30),
    stop=stop_after_attempt(5),
    before_sleep=before_sleep_log(log, logging.WARNING),
    reraise=True,
)


def _dump(model) -> object:
    """
    Serialise an SDK response to plain JSON-able data for archiving.

    Pydantic models expose model_dump; falling back keeps this working if the
    SDK ever returns something else rather than losing the archive entirely.
    """
    if hasattr(model, "model_dump"):
        return model.model_dump(mode="json", exclude_none=True)
    if hasattr(model, "dict"):
        return model.dict()
    return {"unserialisable": str(type(model))}


def _category_id(item_data) -> str | None:
    """
    Resolve an item's category id across Square's three representations.

    `category_id` is the legacy field and is what the Catalog API populates for
    items created programmatically. Items created through the Square dashboard
    or the POS app populate `reporting_category` and `categories` instead, and
    leave `category_id` null — so reading only the legacy field silently
    categorises an entire real catalog as unknown, while sandbox data created
    via batch_upsert looks perfectly fine.
    """
    if item_data.category_id:
        return item_data.category_id
    if item_data.reporting_category and item_data.reporting_category.id:
        return item_data.reporting_category.id
    if item_data.categories:
        for category in item_data.categories:
            if category.id:
                return category.id
    return None


def _line_item_name(line, catalog_name: str | None) -> str:
    """
    Resolve a display name for a line item, in priority order.

    Real production data contains line items with no name at all — Square's
    CUSTOM_AMOUNT type, an ad-hoc payment rung up without a description. Those
    are genuine sales carrying genuine revenue, so they must not be dropped;
    they just need an honest label. Falling back to the itemization type keeps
    them visible and clearly marked in a dashboard rather than silently
    blending into a real product.
    """
    if catalog_name:
        return catalog_name
    if line.name:
        return line.name
    if line.item_type == "CUSTOM_AMOUNT":
        return "Custom amount (unnamed)"
    return "Unnamed line item"


def _money(money) -> Decimal:
    """
    Square returns monetary amounts as integer minor units (cents) plus a
    currency code. Converting through Decimal — never float — keeps the cent
    exact; binary floating point cannot represent 0.10 and the error compounds
    across an aggregate.
    """
    if money is None or money.amount is None:
        return Decimal("0.00")
    return (Decimal(money.amount) / Decimal(100)).quantize(Decimal("0.01"))


@dataclass(frozen=True)
class ExtractWindow:
    """The time range to pull. `start` is inclusive, `end` exclusive."""
    start: datetime
    end: datetime

    @classmethod
    def last_hours(cls, hours: int = 24) -> "ExtractWindow":
        end = datetime.now(timezone.utc)
        return cls(start=end - timedelta(hours=hours), end=end)

    @classmethod
    def backfill(cls) -> "ExtractWindow":
        # Square launched in 2009; anything earlier cannot exist.
        return cls(start=datetime(2009, 1, 1, tzinfo=timezone.utc),
                   end=datetime.now(timezone.utc))

    def __str__(self) -> str:
        return f"{self.start.isoformat()} -> {self.end.isoformat()}"


class SquareExtractor:
    def __init__(self, token: str, environment: str = "production",
                 location_id: str | None = None):
        env = (SquareEnvironment.SANDBOX if environment.lower() == "sandbox"
               else SquareEnvironment.PRODUCTION)
        self.client = Square(token=token, environment=env, timeout=30.0)
        self.environment = environment
        self._location_id = location_id

        # Raw API responses, kept for the S3 bronze layer. Collected as the
        # SDK's parsed models rather than the literal HTTP bytes — faithful to
        # the payload, and it survives the SDK re-serialising it.
        self.raw_payloads: dict[str, list] = {"orders": [], "catalog": []}

        # location_id -> IANA timezone. Square timestamps are UTC; a booth's
        # trading day is local. See _local_timestamp.
        self._location_tz: dict[str, str] = {}

        log.info("Square client initialised against %s", environment)

    # -- locations ------------------------------------------------------
    @retry_square
    def _list_locations(self):
        return self.client.locations.list()

    def location_ids(self) -> list[str]:
        """
        Return the location ids to query, and cache each location's timezone.

        The location list is fetched even when a single location is configured,
        because the timezone is needed to interpret every order timestamp and
        there is no other source for it.
        """
        locations = self._list_locations()
        all_locations = locations.locations or []

        for loc in all_locations:
            if loc.id and loc.timezone:
                self._location_tz[loc.id] = loc.timezone

        if self._location_id:
            return [self._location_id]

        ids = [loc.id for loc in all_locations if loc.id]
        names = {loc.id: loc.name for loc in all_locations}
        log.info("Discovered %d location(s): %s", len(ids),
                 ", ".join(f"{names[i]} ({i}, {self._location_tz.get(i, 'UTC')})"
                           for i in ids))
        return ids

    def _local_timestamp(self, iso_utc: str, location_id: str | None):
        """
        Convert a UTC API timestamp into the selling location's local time.

        Square returns closed_at in UTC. A convention in Seattle that ran
        1pm-6pm local appears as 20:00-01:00 UTC, which does two damaging
        things: the hourly sales curve is shifted by the offset, and every sale
        after 5pm local lands on the *following* UTC date — silently moving
        revenue between trading days and corrupting any day-over-day analysis.

        The business's day is the local day, so the conversion happens here,
        once, before the date and time are ever separated.
        """
        moment = datetime.fromisoformat(iso_utc.replace("Z", "+00:00"))
        tz_name = self._location_tz.get(location_id or "")

        if not tz_name:
            log.warning("No timezone known for location %s; treating %s as UTC",
                        location_id, iso_utc)
            return moment, "UTC"

        try:
            return moment.astimezone(ZoneInfo(tz_name)), tz_name
        except Exception:
            log.warning("Unrecognised timezone %r for location %s; using UTC",
                        tz_name, location_id)
            return moment, "UTC"

    # -- catalog --------------------------------------------------------
    @retry_square
    def _list_catalog_page(self, cursor: str | None, types: str):
        return self.client.catalog.list(cursor=cursor, types=types).response

    def catalog_lookup(self) -> dict[str, dict]:
        """
        Build variation_id -> {item_name, sku, category_name}.

        Order line items reference a catalog *variation* id, not the item, and
        carry no category at all. Without this lookup every sale would be
        uncategorised — which is why the CSV export had a Category column but
        the raw API does not.
        """
        categories: dict[str, str] = {}
        items: dict[str, dict] = {}
        variations: dict[str, dict] = {}

        cursor = None
        pages = 0
        while True:
            page = self._list_catalog_page(cursor, "ITEM,CATEGORY,ITEM_VARIATION")
            pages += 1
            self.raw_payloads["catalog"].append(_dump(page))
            for obj in (page.objects or []):
                if obj.type == "CATEGORY" and obj.category_data:
                    categories[obj.id] = obj.category_data.name
                elif obj.type == "ITEM" and obj.item_data:
                    items[obj.id] = {
                        "name": obj.item_data.name,
                        "category_id": _category_id(obj.item_data),
                    }
                elif obj.type == "ITEM_VARIATION" and obj.item_variation_data:
                    variations[obj.id] = {
                        "item_id": obj.item_variation_data.item_id,
                        "sku": obj.item_variation_data.sku,
                        "variation_name": obj.item_variation_data.name,
                    }
            cursor = page.cursor
            if not cursor:
                break

        lookup: dict[str, dict] = {}
        for var_id, var in variations.items():
            item = items.get(var["item_id"] or "", {})
            lookup[var_id] = {
                "item_name": item.get("name"),
                "sku": var["sku"],
                "variation_name": var["variation_name"],
                "category_name": categories.get(item.get("category_id") or ""),
            }

        log.info("Catalog loaded over %d page(s): %d categories, %d items, "
                 "%d variations", pages, len(categories), len(items), len(variations))
        return lookup

    # -- orders ---------------------------------------------------------
    @retry_square
    def _search_orders_page(self, location_ids: list[str], window: ExtractWindow,
                            cursor: str | None):
        from square.types.search_orders_query import SearchOrdersQuery
        from square.types.search_orders_filter import SearchOrdersFilter
        from square.types.search_orders_date_time_filter import SearchOrdersDateTimeFilter
        from square.types.search_orders_sort import SearchOrdersSort
        from square.types.time_range import TimeRange

        query = SearchOrdersQuery(
            filter=SearchOrdersFilter(
                date_time_filter=SearchOrdersDateTimeFilter(
                    closed_at=TimeRange(
                        start_at=window.start.isoformat(),
                        end_at=window.end.isoformat(),
                    )
                ),
                # COMPLETED only: an OPEN order is a cart still in progress and
                # a CANCELED one never took money. Including either would
                # inflate revenue.
                state_filter={"states": ["COMPLETED"]},
            ),
            # Square requires the sort field to match the filtered timestamp.
            sort=SearchOrdersSort(sort_field="CLOSED_AT", sort_order="ASC"),
        )
        return self.client.orders.search(
            location_ids=location_ids,
            query=query,
            cursor=cursor,
            limit=ORDERS_PAGE_LIMIT,
            return_entries=False,
        )

    def fetch_orders(self, window: ExtractWindow,
                     location_ids: list[str] | None = None) -> list:
        """Page through every order in the window, following Square's cursor."""
        location_ids = location_ids or self.location_ids()
        if not location_ids:
            log.warning("No Square locations available; nothing to extract")
            return []

        orders, cursor, page = [], None, 0
        while True:
            response = self._search_orders_page(location_ids, window, cursor)
            self.raw_payloads["orders"].append(_dump(response))
            batch = response.orders or []
            orders.extend(batch)
            page += 1
            log.info("Page %d: %d orders (running total %d)", page, len(batch), len(orders))

            cursor = response.cursor
            if not cursor:
                break

        log.info("Extracted %d order(s) for window %s", len(orders), window)
        return orders

    # -- flatten --------------------------------------------------------
    def to_line_items(self, orders: list, catalog: dict[str, dict]) -> list[dict]:
        """
        Flatten orders into one record per line item — the grain of the fact
        table. An order with three different items becomes three records.
        """
        records: list[dict] = []

        for order in orders:
            closed = order.closed_at or order.created_at
            if closed:
                closed_dt, tz_name = self._local_timestamp(closed, order.location_id)
            else:
                closed_dt, tz_name = None, "UTC"

            for line in (order.line_items or []):
                meta = catalog.get(line.catalog_object_id or "", {})

                records.append({
                    "sale_date": closed_dt.date() if closed_dt else None,
                    "sale_time": closed_dt.time() if closed_dt else None,
                    "time_zone": tz_name,
                    "category": meta.get("category_name"),
                    # The catalog name is authoritative; the line-item name is a
                    # snapshot taken at sale time and drifts if an item is renamed.
                    # Both can be absent — see _line_item_name.
                    "item": _line_item_name(line, meta.get("item_name")),
                    "qty": Decimal(line.quantity) if line.quantity else Decimal(0),
                    "price_point_name": line.variation_name or meta.get("variation_name"),
                    "sku": meta.get("sku"),
                    "gross_sales": _money(line.gross_sales_money),
                    "discounts": _money(line.total_discount_money),
                    "net_sales": _money(line.gross_sales_money) - _money(line.total_discount_money),
                    "tax": _money(line.total_tax_money),
                    "transaction_id": order.id,
                    "location": order.location_id,
                    "unit": line.quantity_unit.measurement_unit.type if line.quantity_unit else "ea",
                    "count": Decimal(line.quantity) if line.quantity else Decimal(0),
                    "itemization_type": line.item_type,
                    "channel": (order.source.name if order.source else None),
                    "device_name_key": None,   # not exposed on the Orders API
                    "convention_day": None,    # derived downstream from sale_date
                    "source_file": f"square_api:{self.environment}",
                })

        log.info("Flattened %d order(s) into %d line item(s)", len(orders), len(records))
        return records
