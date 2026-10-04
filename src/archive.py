"""
Raw payload archiving — the bronze layer.

Every extraction writes what the Square API actually returned to S3, before any
flattening, PII scrubbing, or type coercion. Nothing in the pipeline reads it
back during a normal run; it exists for two reasons that only matter later.

**The Square API is a live view, not a historical record.** Catalog items get
renamed and deleted, categories get reorganised, refunds mutate orders after
the fact. Re-running a backfill six months from now would join today's sales to
tomorrow's catalog and silently produce different answers for the same
historical period. An archived payload freezes what the API said at the moment
it was asked.

**Reprocessing without re-extraction.** If a bug turns up in the flattening or
the transform, the warehouse can be rebuilt from these files — no API rate
limits, no risk of inheriting whatever has changed upstream since.

Layout:

    s3://<bucket>/<prefix>/square_orders/extracted_date=2026-08-28/orders_<ts>.json.gz
    s3://<bucket>/<prefix>/square_catalog/extracted_date=2026-08-28/catalog_<ts>.json.gz

Partitioning by extraction date (not sale date) is deliberate: the question this
layer answers is "what did the API say when we asked", so the partition key is
when we asked. Gzip because JSON compresses roughly 10:1 and S3 bills by byte.
"""

from __future__ import annotations

import gzip
import json
import logging
from datetime import datetime, timezone

log = logging.getLogger(__name__)


class S3Archiver:
    """
    Writes raw payloads to S3. Best-effort by design.

    An archiving failure must never fail the pipeline: the warehouse load is the
    thing the business depends on, and losing one day of archive is recoverable
    while a failed load is not. Failures are logged loudly and swallowed.
    """

    def __init__(self, bucket: str, prefix: str = "sakuracon",
                 region: str | None = None):
        import boto3

        self.bucket = bucket
        self.prefix = prefix.strip("/")
        self.client = boto3.client("s3", region_name=region or "us-east-1")
        log.info("Raw archive enabled: s3://%s/%s/", bucket, self.prefix)

    def _key(self, dataset: str, extracted_at: datetime) -> str:
        return (
            f"{self.prefix}/{dataset}/"
            f"extracted_date={extracted_at.date().isoformat()}/"
            f"{dataset}_{extracted_at.strftime('%Y%m%dT%H%M%SZ')}.json.gz"
        )

    def archive(self, dataset: str, payload: object,
                extracted_at: datetime | None = None) -> str | None:
        """Write one payload. Returns the S3 URI, or None if archiving failed."""
        extracted_at = extracted_at or datetime.now(timezone.utc)
        key = self._key(dataset, extracted_at)

        try:
            body = gzip.compress(
                json.dumps(payload, default=str, separators=(",", ":")).encode()
            )
            self.client.put_object(
                Bucket=self.bucket,
                Key=key,
                Body=body,
                ContentType="application/json",
                ContentEncoding="gzip",
            )
        except Exception:
            # Never fail the run over the archive. See class docstring.
            log.exception("Failed to archive %s to s3://%s/%s — continuing",
                          dataset, self.bucket, key)
            return None

        uri = f"s3://{self.bucket}/{key}"
        log.info("Archived %s (%d bytes gzipped) -> %s", dataset, len(body), uri)
        return uri


def build_archiver(settings: dict) -> S3Archiver | None:
    """
    Return an archiver when a bucket is configured, otherwise None.

    Local development and the test suite run without S3 entirely; the pipeline
    logs that archiving is off rather than requiring AWS credentials to exist.
    """
    bucket = settings.get("S3_RAW_BUCKET")
    if not bucket:
        log.info("S3_RAW_BUCKET not set — raw archiving disabled")
        return None

    return S3Archiver(
        bucket=bucket,
        prefix=settings.get("S3_RAW_PREFIX", "sakuracon"),
        region=settings.get("AWS_REGION"),
    )
