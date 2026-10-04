/*
    Row-count parity between staging and the fact table.

    Revenue reconciliation alone would not catch a dropped $0 line (a
    comped item, a zero-value promo), so the count is checked separately.
*/

with counts as (
    select
        (select count(*) from {{ ref('stg_sales') }})       as staging_rows,
        (select count(*) from {{ ref('fact_sales_line') }}) as fact_rows
)

select *
from counts
where staging_rows != fact_rows
