{{ config(materialized='table', tags=['marts']) }}

/*
    Grain: one row per line item within an order.

    transaction_id is kept as a degenerate dimension so basket-level questions
    (items per transaction, average basket value) stay answerable without a
    separate order dimension.

    Dimension keys are recomputed with the same hash the dimensions use rather
    than joined in. A join could silently drop rows when a key fails to match;
    hashing the same input cannot.
*/

select
    {{ surrogate_key(['transaction_id', 'item_natural_key', 'sale_time']) }} as sale_line_key,

    transaction_id,
    {{ surrogate_key(['sale_date']) }}        as date_key,
    {{ surrogate_key(['item_natural_key']) }} as item_key,

    sale_time,
    -- Materialised rather than derived in the BI tool. sale_time is a TIME
    -- column, and Redshift refuses to cast TIME to TIMESTAMP — so a client that
    -- wants an hour by asking for a date part gets a type error rather than an
    -- answer. Doing it here means every consumer reads a plain integer, and the
    -- hour is defined once instead of once per dashboard.
    --
    -- extract() works identically on Postgres and Redshift; date_part() and
    -- datediff() do not, which is why this file avoids them throughout.
    cast(extract(hour from sale_time) as smallint) as hour_of_day,

    location_id,
    device_name_key,
    channel,

    quantity,
    gross_sales,
    discounts,
    net_sales,
    tax

from {{ ref('stg_sales') }}
