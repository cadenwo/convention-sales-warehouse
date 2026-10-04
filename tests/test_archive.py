"""
Tests for the S3 bronze layer.

Runs without AWS credentials or network by substituting a fake S3 client, so
the key layout, compression, and — most importantly — the failure behaviour are
all verified offline.
"""

from __future__ import annotations

import gzip
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from archive import S3Archiver, build_archiver  # noqa: E402


class FakeS3:
    """Records put_object calls instead of talking to AWS."""

    def __init__(self, fail: bool = False):
        self.puts: list[dict] = []
        self.fail = fail

    def put_object(self, **kwargs):
        if self.fail:
            raise RuntimeError("AccessDenied: not authorized to perform s3:PutObject")
        self.puts.append(kwargs)
        return {"ETag": "fake"}


@pytest.fixture
def archiver():
    """
    Build an archiver around a fake client without running __init__, which
    would construct a real boto3 session.
    """
    fake = FakeS3()
    a = S3Archiver.__new__(S3Archiver)
    a.bucket = "test-bucket"
    a.prefix = "sakuracon"
    a.client = fake
    return a, fake


AT = datetime(2026, 8, 28, 14, 30, 5, tzinfo=timezone.utc)


# --------------------------------------------------------------------------
# Key layout
# --------------------------------------------------------------------------
def test_key_partitions_by_extraction_date(archiver):
    a, fake = archiver
    a.archive("square_orders", {"orders": []}, AT)

    key = fake.puts[0]["Key"]
    assert key == (
        "sakuracon/square_orders/extracted_date=2026-08-28/"
        "square_orders_20260828T143005Z.json.gz"
    )


def test_two_runs_same_day_do_not_overwrite(archiver):
    """A backfill and a scheduled run on the same day must both survive."""
    a, fake = archiver
    a.archive("square_orders", {"n": 1}, datetime(2026, 8, 28, 9, 0, 0, tzinfo=timezone.utc))
    a.archive("square_orders", {"n": 2}, datetime(2026, 8, 28, 17, 0, 0, tzinfo=timezone.utc))

    keys = [p["Key"] for p in fake.puts]
    assert len(set(keys)) == 2


# --------------------------------------------------------------------------
# Payload
# --------------------------------------------------------------------------
def test_payload_is_gzipped_json_and_round_trips(archiver):
    a, fake = archiver
    payload = [{"id": "ORDER1", "total_money": {"amount": 2000, "currency": "USD"}}]
    a.archive("square_orders", payload, AT)

    body = fake.puts[0]["Body"]
    assert fake.puts[0]["ContentEncoding"] == "gzip"
    assert json.loads(gzip.decompress(body)) == payload


def test_non_json_types_are_stringified_not_fatal(archiver):
    """Decimals and datetimes appear in Square payloads; they must not crash."""
    from decimal import Decimal

    a, fake = archiver
    a.archive("square_orders", {"amount": Decimal("20.00"), "at": AT}, AT)

    restored = json.loads(gzip.decompress(fake.puts[0]["Body"]))
    assert restored["amount"] == "20.00"


# --------------------------------------------------------------------------
# Failure behaviour — the important one
# --------------------------------------------------------------------------
def test_archive_failure_returns_none_and_does_not_raise():
    """
    Losing an archive write is recoverable; failing the warehouse load is not.
    An S3 outage or a missing IAM permission must never take the pipeline down.
    """
    a = S3Archiver.__new__(S3Archiver)
    a.bucket, a.prefix, a.client = "test-bucket", "sakuracon", FakeS3(fail=True)

    assert a.archive("square_orders", {"orders": []}, AT) is None


def test_archive_returns_uri_on_success(archiver):
    a, _ = archiver
    uri = a.archive("square_catalog", {"objects": []}, AT)
    assert uri.startswith("s3://test-bucket/sakuracon/square_catalog/")


# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
def test_build_archiver_returns_none_without_bucket():
    """Local development and CI run with no S3 at all."""
    assert build_archiver({}) is None
    assert build_archiver({"S3_RAW_BUCKET": ""}) is None


def test_build_archiver_constructs_when_bucket_present(monkeypatch):
    created = {}

    class FakeBoto:
        @staticmethod
        def client(name, region_name=None):
            created["service"] = name
            created["region"] = region_name
            return FakeS3()

    monkeypatch.setitem(sys.modules, "boto3", FakeBoto)

    a = build_archiver({"S3_RAW_BUCKET": "my-bucket", "AWS_REGION": "us-west-2"})
    assert a is not None
    assert a.bucket == "my-bucket"
    assert created == {"service": "s3", "region": "us-west-2"}
