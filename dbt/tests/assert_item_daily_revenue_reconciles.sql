/*
    Densifying must not invent or lose revenue.

    Adding rows to a fact table is exactly the operation that can silently
    duplicate measures — a cross join with a slightly wrong grain fans the
    left side out, every joined row is counted twice, and the totals inflate
    while every individual number still looks reasonable.

    So the total from fact_item_daily must equal the total from
    fact_sales_line over the same trading days, to the cent. The zeros added
    nothing; they only made absence visible.
*/

with densified as (

    select round(sum(net_sales), 2) as total
    from {{ ref('fact_item_daily') }}

),

source as (

    select round(sum(f.net_sales), 2) as total
    from {{ ref('fact_sales_line') }} f
    join {{ ref('dim_date') }} d on d.date_key = f.date_key
    where d.is_trading_day

)

select
    d.total as densified_total,
    s.total as source_total
from densified d
cross join source s
where d.total <> s.total
