/*
    The load audit, as a test.

    Every dollar that lands in staging must appear in the fact table. A
    mismatch means a join dropped rows — the exact failure the original
    UPDATE ... JOIN approach concealed. Returning any row fails the build.

    Tolerance is 1 cent to absorb rounding in the numeric cast, not to paper
    over missing rows: a single dropped line item is at least several dollars.
*/

with staging_total as (
    select sum(net_sales) as total from {{ ref('stg_sales') }}
),

fact_total as (
    select sum(net_sales) as total from {{ ref('fact_sales_line') }}
)

select
    staging_total.total as staging_net_sales,
    fact_total.total    as fact_net_sales,
    abs(staging_total.total - fact_total.total) as difference
from staging_total
cross join fact_total
where abs(staging_total.total - fact_total.total) > 0.01
