/*
    fact_item_daily must hold exactly (items × trading days) rows.

    This is the assertion that the densification actually happened. A cross
    join that silently degrades — a join condition creeping in, dim_item losing
    rows, is_trading_day changing meaning — would produce a table that still
    looks plausible and still charts, but with the zeros missing again. The
    failure mode of this model is silence, so the test has to be arithmetic
    rather than a spot check.

    Counted with cross joins rather than scalar subqueries in the select list,
    which Redshift handles inconsistently.
*/

with item_count as (
    select count(*) as n from {{ ref('dim_item') }}
),

day_count as (
    select count(*) as n from {{ ref('dim_date') }} where is_trading_day
),

row_count as (
    select count(*) as n from {{ ref('fact_item_daily') }}
)

select
    i.n            as items,
    d.n            as trading_days,
    i.n * d.n      as expected_rows,
    r.n            as actual_rows
from item_count i
cross join day_count d
cross join row_count r
where i.n * d.n <> r.n
