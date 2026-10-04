-- =====================================================================
-- Raw landing zone
--
-- This is the only DDL the Python job owns. Everything downstream —
-- staging views and the warehouse star schema — is built and owned by dbt,
-- so the transform layer has exactly one definition rather than two that
-- can drift apart.
--
-- Layers:
--     raw_data   this file; written by the extract-load job
--     staging    dbt views (cleaned, typed)
--     warehouse  dbt tables (the star schema)
--
-- Runs against both PostgreSQL and Redshift: no IDENTITY columns, no
-- Postgres-only types.
-- =====================================================================

-- Named raw_data, not raw: RAW is a reserved word in Redshift, and a schema
-- called `raw` fails to parse unless quoted at every single reference. Renaming
-- once is cheaper than remembering to write "raw" forever.
CREATE SCHEMA IF NOT EXISTS raw_data;

-- CASCADE is required, not lazy: once dbt has run, staging.stg_sales is a view
-- selecting from this table, and a bare DROP fails with DependentObjectsStillExist.
-- Everything CASCADE removes is dbt-owned and rebuilt by the `dbt build` that
-- runs seconds later in the same task, so nothing is lost. Without this, --init
-- succeeds exactly once and fails on every subsequent run.
DROP TABLE IF EXISTS raw_data.sales_line_items CASCADE;

CREATE TABLE raw_data.sales_line_items (
    sale_date          date,
    sale_time          time,
    time_zone          varchar(64),
    category           varchar(256),
    item               varchar(512),
    qty                decimal(12,2),
    price_point_name   varchar(256),
    sku                varchar(128),
    gross_sales        decimal(12,2),
    discounts          decimal(12,2),
    net_sales          decimal(12,2),
    tax                decimal(12,2),
    transaction_id     varchar(128),
    location           varchar(128),
    unit               varchar(64),
    count              decimal(12,2),
    itemization_type   varchar(64),
    channel            varchar(256),

    -- SHA-256 pseudonym of the till operator's device, never the name itself.
    device_name_key    varchar(64),

    convention_day     varchar(32),
    source_file        varchar(256)
);
