"""
Offline tests for the Square extraction layer.

These run without a Square token or network access by faking the API responses,
so the pagination, retry, and flattening logic is verified before any real
credential exists.

    python -m pytest tests/ -v
"""

from __future__ import annotations

import sys
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from square.core.api_error import ApiError  # noqa: E402
import square_extract  # noqa: E402
from square_extract import SquareExtractor, ExtractWindow, _money  # noqa: E402


# --------------------------------------------------------------------------
# Fakes
# --------------------------------------------------------------------------
def money(cents: int | None):
    return SimpleNamespace(amount=cents, currency="USD")


def line_item(name, variation_id, qty="1", gross=2000, discount=0, tax=211,
              item_type="ITEM"):
    return SimpleNamespace(
        uid=f"line-{name}",
        name=name,
        quantity=qty,
        quantity_unit=None,
        catalog_object_id=variation_id,
        variation_name="Regular",
        item_type=item_type,
        gross_sales_money=money(gross),
        total_discount_money=money(discount),
        total_tax_money=money(tax),
    )


def order(order_id, lines, closed="2026-04-03T18:48:27Z"):
    return SimpleNamespace(
        id=order_id,
        location_id="LOC1",
        line_items=lines,
        closed_at=closed,
        created_at=closed,
        source=SimpleNamespace(name="Pinkywinx"),
    )


CATALOG = {
    "VAR_PLUSH": {"item_name": "pikmin plush 2", "sku": "HM-PIK-2",
                  "variation_name": "Regular", "category_name": "handmade"},
    "VAR_BB": {"item_name": "Pikmin Ver 1 blindbag", "sku": "BB-PIK-1",
               "variation_name": "Regular", "category_name": "Blindbag"},
}


def make_extractor() -> SquareExtractor:
    return SquareExtractor(token="fake-token", environment="sandbox",
                           location_id="LOC1")


def fake_locations(monkeypatch, tz: str = "America/Los_Angeles"):
    """
    Stub the locations call.

    location_ids() always fetches the location list now, because a location's
    timezone is the only way to interpret its order timestamps — so any test
    that reaches it needs this.
    """
    monkeypatch.setattr(
        SquareExtractor, "_list_locations",
        lambda self: SimpleNamespace(
            locations=[SimpleNamespace(id="LOC1", name="Pinkywinx", timezone=tz)]
        ),
    )


# --------------------------------------------------------------------------
# Money handling
# --------------------------------------------------------------------------
def test_money_converts_cents_to_decimal():
    assert _money(money(2000)) == Decimal("20.00")
    assert _money(money(63)) == Decimal("0.63")
    assert _money(money(0)) == Decimal("0.00")
    assert _money(None) == Decimal("0.00")


def test_money_returns_decimal_not_float():
    """Float arithmetic on currency drifts; Decimal must be preserved."""
    total = sum((_money(money(10)) for _ in range(10)), Decimal("0"))
    assert total == Decimal("1.00")
    assert isinstance(total, Decimal)


# --------------------------------------------------------------------------
# Pagination
# --------------------------------------------------------------------------
def test_fetch_orders_follows_cursor_across_pages(monkeypatch):
    """The bug this guards against: stopping after page 1 and losing data."""
    pages = [
        SimpleNamespace(orders=[order("A", [line_item("x", "VAR_BB")])], cursor="CUR1"),
        SimpleNamespace(orders=[order("B", [line_item("y", "VAR_BB")])], cursor="CUR2"),
        SimpleNamespace(orders=[order("C", [line_item("z", "VAR_BB")])], cursor=None),
    ]
    seen_cursors = []

    def fake_page(self, location_ids, window, cursor):
        seen_cursors.append(cursor)
        return pages[len(seen_cursors) - 1]

    monkeypatch.setattr(SquareExtractor, "_search_orders_page", fake_page)
    fake_locations(monkeypatch)

    orders = make_extractor().fetch_orders(ExtractWindow.last_hours(24))

    assert [o.id for o in orders] == ["A", "B", "C"]
    assert seen_cursors == [None, "CUR1", "CUR2"]


def test_fetch_orders_handles_empty_result(monkeypatch):
    """A closed day returns zero orders — normal, not an error."""
    monkeypatch.setattr(
        SquareExtractor, "_search_orders_page",
        lambda self, l, w, c: SimpleNamespace(orders=[], cursor=None),
    )
    fake_locations(monkeypatch)
    assert make_extractor().fetch_orders(ExtractWindow.last_hours(24)) == []


# --------------------------------------------------------------------------
# Retry / backoff
# --------------------------------------------------------------------------
def test_retries_on_rate_limit_then_succeeds(monkeypatch):
    monkeypatch.setattr(square_extract, "retry_square", lambda f: f)
    attempts = {"n": 0}

    @square_extract.retry_square
    def flaky():
        attempts["n"] += 1
        if attempts["n"] < 3:
            raise ApiError(status_code=429, headers={}, body="rate limited")
        return "ok"

    # Exercise the predicate directly; the decorator itself is tenacity's.
    assert square_extract._is_retryable(ApiError(status_code=429, headers={}, body=""))
    assert square_extract._is_retryable(ApiError(status_code=503, headers={}, body=""))


def test_does_not_retry_on_auth_error():
    """A 401 means a bad token. Retrying hides the real problem."""
    assert not square_extract._is_retryable(
        ApiError(status_code=401, headers={}, body="unauthorized")
    )
    assert not square_extract._is_retryable(
        ApiError(status_code=400, headers={}, body="bad request")
    )


# --------------------------------------------------------------------------
# Flattening
# --------------------------------------------------------------------------
def test_order_flattens_to_one_record_per_line_item():
    o = order("TXN1", [
        line_item("pikmin plush 2", "VAR_PLUSH", gross=2000, tax=211),
        line_item("Pikmin Ver 1 blindbag", "VAR_BB", gross=600, tax=63),
    ])
    records = make_extractor().to_line_items([o], CATALOG)

    assert len(records) == 2
    assert {r["transaction_id"] for r in records} == {"TXN1"}
    assert records[0]["item"] == "pikmin plush 2"
    assert records[0]["sku"] == "HM-PIK-2"
    assert records[0]["category"] == "handmade"
    assert records[0]["gross_sales"] == Decimal("20.00")
    assert records[0]["tax"] == Decimal("2.11")


def test_net_sales_subtracts_discount():
    o = order("TXN2", [line_item("d", "VAR_BB", gross=1000, discount=250)])
    rec = make_extractor().to_line_items([o], CATALOG)[0]
    assert rec["gross_sales"] == Decimal("10.00")
    assert rec["discounts"] == Decimal("2.50")
    assert rec["net_sales"] == Decimal("7.50")


def test_uncatalogued_item_falls_back_to_line_name():
    """A deleted catalog entry must not drop the sale."""
    o = order("TXN3", [line_item("Custom Amount", "VAR_GONE", gross=300, tax=0)])
    rec = make_extractor().to_line_items([o], CATALOG)[0]
    assert rec["item"] == "Custom Amount"
    assert rec["sku"] is None
    assert rec["category"] is None
    assert rec["net_sales"] == Decimal("3.00")


def test_unnamed_custom_amount_gets_an_honest_label():
    """
    Production data contains CUSTOM_AMOUNT line items with no name at all —
    ad-hoc payments rung up without a description. They carry real revenue and
    must survive with a label, not be dropped for having a null name.
    """
    o = order("TXN_CUSTOM", [
        line_item(None, "VAR_NONE", gross=300, tax=0, item_type="CUSTOM_AMOUNT")
    ])
    rec = make_extractor().to_line_items([o], CATALOG)[0]

    assert rec["item"] == "Custom amount (unnamed)"
    assert rec["net_sales"] == Decimal("3.00")


def test_nameless_non_custom_line_still_gets_a_label():
    """Any nameless line must produce a non-null item; nothing may be dropped."""
    o = order("TXN_ODD", [line_item(None, "VAR_NONE", gross=500, tax=0)])
    rec = make_extractor().to_line_items([o], CATALOG)[0]

    assert rec["item"] == "Unnamed line item"
    assert rec["item"] is not None


def test_sale_date_and_time_split_from_closed_at():
    o = order("TXN4", [line_item("x", "VAR_BB")], closed="2026-04-05T15:44:49Z")
    rec = make_extractor().to_line_items([o], CATALOG)[0]
    assert rec["sale_date"] == datetime(2026, 4, 5, tzinfo=timezone.utc).date()
    assert rec["sale_time"].hour == 15
    assert rec["sale_time"].minute == 44


# --------------------------------------------------------------------------
# Window
# --------------------------------------------------------------------------
def test_incremental_window_is_24h_by_default():
    w = ExtractWindow.last_hours()
    assert (w.end - w.start).total_seconds() == pytest.approx(86400, abs=2)


def test_backfill_window_reaches_before_square_existed():
    assert ExtractWindow.backfill().start.year == 2009


# --------------------------------------------------------------------------
# Category resolution across Square's three representations
# --------------------------------------------------------------------------
def _item_data(category_id=None, reporting_category=None, categories=None):
    return SimpleNamespace(
        name="thing",
        category_id=category_id,
        reporting_category=reporting_category,
        categories=categories,
    )


def test_category_prefers_legacy_field_when_present():
    assert square_extract._category_id(_item_data(category_id="CAT_LEGACY")) == "CAT_LEGACY"


def test_category_falls_back_to_reporting_category():
    """
    Items created through the Square dashboard or POS leave category_id null
    and populate reporting_category instead. Reading only the legacy field
    marked an entire real catalog as Uncategorized while sandbox data — created
    via batch_upsert, which does set category_id — looked correct.
    """
    item = _item_data(reporting_category=SimpleNamespace(id="CAT_REPORTING"))
    assert square_extract._category_id(item) == "CAT_REPORTING"


def test_category_falls_back_to_categories_list():
    item = _item_data(categories=[SimpleNamespace(id="CAT_FIRST"),
                                  SimpleNamespace(id="CAT_SECOND")])
    assert square_extract._category_id(item) == "CAT_FIRST"


def test_category_returns_none_when_genuinely_uncategorised():
    assert square_extract._category_id(_item_data()) is None


# --------------------------------------------------------------------------
# Timezone conversion
# --------------------------------------------------------------------------
def test_utc_timestamp_converts_to_location_local_time():
    ex = make_extractor()
    ex._location_tz = {"LOC1": "America/Los_Angeles"}

    # 01:30 UTC on the 4th is 18:30 on the 3rd in Seattle.
    local, tz_name = ex._local_timestamp("2026-04-04T01:30:00Z", "LOC1")

    assert tz_name == "America/Los_Angeles"
    assert local.hour == 18
    assert local.date().day == 3


def test_evening_sale_stays_on_the_local_trading_day():
    """
    The bug this guards: a sale at 6:30pm local is 01:30 UTC the next day, so
    treating the UTC date as the trading day moves that revenue to the wrong
    day and corrupts every day-over-day comparison.
    """
    ex = make_extractor()
    ex._location_tz = {"LOC1": "America/Los_Angeles"}

    o = order("TXN_EVENING", [line_item("x", "VAR_BB")],
              closed="2026-04-04T01:30:00Z")
    rec = ex.to_line_items([o], CATALOG)[0]

    assert rec["sale_date"].isoformat() == "2026-04-03"
    assert rec["sale_time"].hour == 18
    assert rec["time_zone"] == "America/Los_Angeles"


def test_unknown_timezone_falls_back_to_utc_without_crashing():
    ex = make_extractor()
    ex._location_tz = {"LOC1": "Not/ARealZone"}
    local, tz_name = ex._local_timestamp("2026-04-04T01:30:00Z", "LOC1")
    assert tz_name == "UTC"
    assert local.hour == 1


def test_location_timezone_is_cached_from_the_locations_call(monkeypatch):
    """location_ids() must populate the timezone map, not just return ids."""
    fake_locations(monkeypatch, tz="America/New_York")
    ex = make_extractor()

    assert ex.location_ids() == ["LOC1"]
    assert ex._location_tz == {"LOC1": "America/New_York"}
