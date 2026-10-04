#!/usr/bin/env python3
"""
Sakura-Con Sales Pipeline — entrypoint.

    Square API  ->  S3 raw archive (bronze)
                ->  raw_data.sales_line_items  ->  dbt  ->  star schema

This is the EL half of an ELT pipeline: it extracts from Square, applies only
the cleaning that must happen before data lands (PII removal, currency
parsing), and loads to the raw layer. Every relational transformation — the
staging views and the star schema — belongs to dbt, which runs afterwards.

Designed to run either on a laptop or as a Fargate task. Everything it needs
comes from configuration, it logs structurally to stdout (which CloudWatch
captures verbatim), and it exits 0 on success / 1 on failure so the scheduler
can tell whether the run actually worked.

    python scripts/run_pipeline.py --backfill --init   # first run, full history
    python scripts/run_pipeline.py                     # scheduled: last 24h
    python scripts/run_pipeline.py --lookback-hours 72 # catch up after an outage
    python scripts/run_pipeline.py --skip-dbt          # load only, no transform
"""

from __future__ import annotations

import argparse
import io
import logging
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

SQL_DIR = Path(__file__).resolve().parent.parent / "sql"

STAGING_COLS = [
    "sale_date", "sale_time", "time_zone", "category", "item", "qty",
    "price_point_name", "sku", "gross_sales", "discounts", "net_sales", "tax",
    "transaction_id", "location", "unit", "count", "itemization_type",
    "channel", "device_name_key", "convention_day", "source_file",
]


def configure_logging(level: str = "INFO") -> None:
    """
    Structured stdout logging. CloudWatch ingests whatever a container writes to
    stdout, so `print` would produce untimestamped, unlevelled lines that are
    impossible to filter during an incident. Stack traces go through the same
    handler via log.exception().
    """
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)-8s %(name)s | %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S%z",
        stream=sys.stdout,
        force=True,
    )
    # httpx logs every request at INFO; too noisy for a pipeline log.
    logging.getLogger("httpx").setLevel(logging.WARNING)


log = logging.getLogger("pipeline")


def connect_postgres(settings: dict):
    """
    Connect to the warehouse, tolerating a Redshift Serverless cold start.

    Serverless scales compute to zero when idle and resumes on the first
    connection, which routinely takes 30-60 seconds. This pipeline runs once a
    day, so *every* scheduled run arrives at a cold warehouse — a short timeout
    here does not fail fast, it fails daily. It passes on a laptop only because
    a developer has usually just queried the thing by hand.

    Retries are narrowed to errors that look like a cold start. A wrong
    password is also an OperationalError, and burning four minutes to rediscover
    a typo would be worse than failing immediately.
    """
    import psycopg2
    from tenacity import (
        before_sleep_log, retry, retry_if_exception, stop_after_attempt, wait_fixed,
    )

    COLD_START_SIGNS = ("timeout expired", "could not connect", "connection refused",
                        "server closed the connection unexpectedly")

    def _is_cold_start(exc: BaseException) -> bool:
        if not isinstance(exc, psycopg2.OperationalError):
            return False
        message = str(exc).lower()
        return any(sign in message for sign in COLD_START_SIGNS)

    @retry(
        retry=retry_if_exception(_is_cold_start),
        wait=wait_fixed(10),
        stop=stop_after_attempt(3),
        before_sleep=before_sleep_log(log, logging.WARNING),
        reraise=True,
    )
    def _connect():
        return psycopg2.connect(
            host=settings["PGHOST"],
            port=settings.get("PGPORT", "5432"),
            dbname=settings["PGDATABASE"],
            user=settings["PGUSER"],
            password=settings["PGPASSWORD"],
            sslmode=settings.get("PGSSLMODE", "require"),
            connect_timeout=60,
        )

    return _connect()


def _split_statements(sql: str) -> list[str]:
    """
    Split a SQL file into individual statements.

    Deliberately simple: strips `--` line comments, then splits on semicolons.
    Adequate because these files contain no semicolons inside string literals or
    identifiers. A file that did would need a real parser (sqlparse), and the
    right response would be to add the dependency rather than complicate this.
    """
    lines = [ln.split("--", 1)[0] for ln in sql.splitlines()]
    return [s.strip() for s in " ".join(lines).split(";") if s.strip()]


def run_sql_file(conn, path: Path) -> None:
    """
    Execute a SQL file one statement at a time, committing after each.

    Not merely tidiness. Redshift parses and validates an entire multi-statement
    batch before executing any of it, so a file that creates a schema and then
    references it fails validation — the schema does not exist yet at parse
    time. PostgreSQL executes sequentially and never sees the problem, which is
    exactly the kind of difference that passes locally and fails in production.
    """
    statements = _split_statements(path.read_text())
    log.info("Executing %s (%d statement(s))", path.name, len(statements))

    with conn.cursor() as cur:
        for i, statement in enumerate(statements, start=1):
            try:
                cur.execute(statement)
            except Exception:
                log.error("Statement %d/%d failed: %s",
                          i, len(statements), statement[:200])
                raise

            if cur.description:
                cols = [d.name for d in cur.description]
                for row in cur.fetchall():
                    log.info("  %s", dict(zip(cols, row)))

            # Commit per statement so later statements can see earlier DDL.
            conn.commit()


def _records_to_csv(records: list[dict]) -> str:
    """Serialise records to CSV text in STAGING_COLS order, nulls as empty."""
    import csv

    buf = io.StringIO()
    writer = csv.writer(buf)
    for r in records:
        writer.writerow(["" if r.get(c) is None else r.get(c) for c in STAGING_COLS])
    return buf.getvalue()


def _clear_target(cur, dates: list, full_refresh: bool) -> None:
    """
    Make the load idempotent.

    A scheduled pipeline WILL be re-run — a transient failure, a manual retry, a
    duplicated schedule event. Appending blindly would double-count revenue every
    time, so the dates in this batch are removed before it is inserted.
    """
    if full_refresh:
        log.info("Full refresh: truncating raw_data.sales_line_items")
        cur.execute("TRUNCATE raw_data.sales_line_items;")
    elif dates:
        # `IN %s` with a tuple rather than `= ANY(%s)`: psycopg2 expands the
        # tuple into a literal list, which both engines accept. Redshift has no
        # real array support, so ANY(array) fails there.
        cur.execute(
            "DELETE FROM raw_data.sales_line_items WHERE sale_date IN %s;",
            (tuple(dates),),
        )
        log.info("Cleared %d existing row(s) for %d date(s) in this batch",
                 cur.rowcount, len(dates))


def _load_postgres(cur, records: list[dict]) -> None:
    """
    PostgreSQL path: stream the batch straight down the open connection.

    COPY ... FROM STDIN is a PostgreSQL protocol feature. Redshift does not
    implement it — see _load_redshift.
    """
    buf = io.StringIO(_records_to_csv(records))
    cur.copy_expert(
        f"COPY raw_data.sales_line_items ({', '.join(STAGING_COLS)}) "
        "FROM STDIN WITH (FORMAT csv, NULL '')",
        buf,
    )


def _load_redshift(cur, records: list[dict], settings: dict) -> None:
    """
    Redshift path: stage the batch to S3, then COPY from there.

    Redshift's COPY reads only from S3, EMR, EC2, SSH or DynamoDB — never from a
    client stream. This is not merely a compatibility workaround: loading via S3
    lets every compute slice read a slice of the file in parallel, which is why
    it is the canonical Redshift load path at any real volume.

    Requires an IAM role attached to the Redshift namespace with read access to
    the bucket (REDSHIFT_IAM_ROLE).
    """
    import gzip
    import uuid

    import boto3

    bucket = settings.get("S3_RAW_BUCKET")
    iam_role = settings.get("REDSHIFT_IAM_ROLE")
    if not bucket or not iam_role:
        raise SystemExit(
            "Loading to Redshift requires S3_RAW_BUCKET and REDSHIFT_IAM_ROLE. "
            "Redshift cannot accept a client-side stream, so the batch must be "
            "staged to S3 first."
        )

    prefix = settings.get("S3_RAW_PREFIX", "sakuracon").strip("/")
    key = f"{prefix}/_staging/load_{uuid.uuid4().hex}.csv.gz"
    body = gzip.compress(_records_to_csv(records).encode())

    s3 = boto3.client("s3", region_name=settings.get("AWS_REGION", "us-east-1"))
    s3.put_object(Bucket=bucket, Key=key, Body=body)
    log.info("Staged %d record(s) to s3://%s/%s (%d bytes gz)",
             len(records), bucket, key, len(body))

    try:
        cur.execute(
            f"COPY raw_data.sales_line_items ({', '.join(STAGING_COLS)}) "
            f"FROM 's3://{bucket}/{key}' "
            f"IAM_ROLE '{iam_role}' "
            "FORMAT AS CSV GZIP "
            "EMPTYASNULL BLANKSASNULL "
            "DATEFORMAT 'auto' TIMEFORMAT 'auto';"
        )
    except Exception:
        # Leave the staged file behind on failure — it is the artefact you need
        # to diagnose a COPY error, and STL_LOAD_ERRORS references it by name.
        log.error("COPY failed; staged file kept at s3://%s/%s", bucket, key)
        raise

    # Clean up only on success. The bronze archive already holds the raw payload
    # for replay, so this intermediate file has no further purpose.
    s3.delete_object(Bucket=bucket, Key=key)


def load_staging(conn, records: list[dict], full_refresh: bool,
                 settings: dict) -> int:
    """
    Load the batch into raw_data.sales_line_items, idempotently.

    The mechanism differs by engine — see the two helpers above — but the
    semantics are identical: after this returns, the raw table contains exactly
    one copy of every record in the batch, however many times it has been run.
    """
    if not records:
        log.info("No records to load")
        return 0

    warehouse = settings.get("WAREHOUSE_TYPE", "postgres").lower()
    dates = sorted({r["sale_date"] for r in records if r["sale_date"]})

    with conn.cursor() as cur:
        _clear_target(cur, dates, full_refresh)

        if warehouse == "redshift":
            _load_redshift(cur, records, settings)
        else:
            _load_postgres(cur, records)

        cur.execute("SELECT COUNT(*) FROM raw_data.sales_line_items;")
        total = cur.fetchone()[0]

    conn.commit()
    log.info("Loaded %d record(s) via %s; raw_data.sales_line_items now holds %d row(s)",
             len(records), warehouse, total)
    return len(records)


def run_dbt(settings: dict) -> None:
    """
    Hand the transform to dbt.

    `dbt build` runs models and their tests together in dependency order and
    stops at the first failure, so a test that catches bad data prevents the
    downstream models from being built on top of it. A non-zero return code
    propagates up and fails the whole task, which is what makes a bad load
    visible in EventBridge rather than silently producing a wrong dashboard.
    """
    import subprocess

    dbt_dir = Path(__file__).resolve().parent.parent / "dbt"
    env = os.environ.copy()
    # dbt reads connection details from the same settings the loader used, so
    # there is never a second place where credentials can drift.
    for key in ("PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD"):
        if settings.get(key):
            env[key] = str(settings[key])
    # dbt target follows the warehouse type: the `prod` profile uses the
    # redshift adapter, `dev` uses postgres. One setting, not two that can
    # disagree about which engine they are talking to.
    default_target = ("prod" if settings.get("WAREHOUSE_TYPE", "").lower() == "redshift"
                      else "dev")
    env.setdefault("DBT_TARGET", os.environ.get("DBT_TARGET", default_target))
    env["DBT_PROFILES_DIR"] = str(dbt_dir)

    log.info("Running dbt build (target=%s)", env["DBT_TARGET"])

    # Invoke dbt as a module through the *same* interpreter running this script,
    # rather than relying on a `dbt` console script being on PATH. pip installs
    # console scripts to a bin directory that is frequently not on PATH (and
    # says so, in a warning nobody reads), and on a machine with several Pythons
    # a bare `dbt` can easily belong to a different environment than the one
    # holding psycopg2 and the Square SDK.
    result = subprocess.run(
        [sys.executable, "-m", "dbt.cli.main", "build", "--project-dir", str(dbt_dir)],
        env=env, capture_output=True, text=True,
    )

    if result.returncode != 0 and "No module named dbt" in (result.stderr or ""):
        raise RuntimeError(
            "dbt is not installed in this interpreter "
            f"({sys.executable}). Install it with:\n"
            f"    {sys.executable} -m pip install -r requirements.txt\n"
            "Note dbt requires Python 3.10 or newer."
        )

    for line in result.stdout.splitlines():
        if line.strip():
            log.info("dbt | %s", line.rstrip())

    if result.returncode != 0:
        for line in result.stderr.splitlines():
            if line.strip():
                log.error("dbt | %s", line.rstrip())
        raise RuntimeError(f"dbt build failed with exit code {result.returncode}")

    log.info("dbt build completed")


def extract(settings: dict, args) -> list[dict]:
    from archive import build_archiver
    from square_extract import SquareExtractor, ExtractWindow

    extractor = SquareExtractor(
        token=settings["SQUARE_ACCESS_TOKEN"],
        environment=settings.get("SQUARE_ENVIRONMENT", "production"),
        location_id=settings.get("SQUARE_LOCATION_ID"),
    )

    window = (ExtractWindow.backfill() if args.backfill
              else ExtractWindow.last_hours(args.lookback_hours))
    log.info("Extract window: %s", window)

    catalog = extractor.catalog_lookup()
    orders = extractor.fetch_orders(window)

    # Archive before flattening. The catalog is archived too and matters more
    # than the orders: it is the mutable half. Items get renamed and categories
    # reorganised, so without a snapshot a future rebuild would join these
    # sales to a catalog that no longer describes them.
    archiver = build_archiver(settings)
    if archiver:
        extracted_at = window.end
        archiver.archive("square_catalog", extractor.raw_payloads["catalog"], extracted_at)
        archiver.archive("square_orders", extractor.raw_payloads["orders"], extracted_at)

    return extractor.to_line_items(orders, catalog)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--backfill", action="store_true",
                    help="pull all history instead of the recent window")
    ap.add_argument("--lookback-hours", type=int, default=24,
                    help="size of the incremental window (default 24)")
    ap.add_argument("--init", action="store_true",
                    help="(re)create the raw schema before loading")
    ap.add_argument("--skip-dbt", action="store_true",
                    help="load the raw layer only; do not run the transform")
    ap.add_argument("--log-level", default=os.environ.get("LOG_LEVEL", "INFO"))
    args = ap.parse_args()

    configure_logging(args.log_level)

    try:
        from config import get_settings, require

        settings = get_settings()
        require(settings, "SQUARE_ACCESS_TOKEN", "PGHOST", "PGDATABASE",
                "PGUSER", "PGPASSWORD")

        records = extract(settings, args)

        conn = connect_postgres(settings)
        log.info("Connected to %s/%s", settings["PGHOST"], settings["PGDATABASE"])
        try:
            if args.init:
                run_sql_file(conn, SQL_DIR / "01_schema.sql")
            load_staging(conn, records, args.backfill or args.init, settings)
        finally:
            conn.close()

        if args.skip_dbt:
            log.info("Skipping dbt (--skip-dbt)")
        else:
            run_dbt(settings)

    except SystemExit:
        raise
    except Exception:
        # Full stack trace to stdout so CloudWatch captures it, then a non-zero
        # exit so EventBridge/Fargate records the task as FAILED rather than
        # silently "completed".
        log.exception("Pipeline failed")
        return 1

    log.info("Pipeline completed successfully")
    return 0


if __name__ == "__main__":
    sys.exit(main())
