/*
    Every day belonging to an event must have taken at least as much as the
    cheapest catalog item costs.

    This is the invariant behind dim_date's is_trading_day flag, asserted
    independently of the model that produces it. Without it the threshold is a
    comment: someone simplifying the CTEs later could drop the filter, the
    phantom event would come back, and nothing would fail.

    ITEM only, matching dim_date — a CUSTOM_AMOUNT is an arbitrary charge typed
    at the terminal, not a product with a price.
*/

with catalog_floor as (

    select min(gross_sales / quantity) as floor_amount
    from {{ ref('stg_sales') }}
    where itemization_type = 'ITEM'
      and quantity > 0
      and gross_sales > 0

),

event_day_revenue as (

    select
        d.full_date,
        d.event_name,
        sum(f.net_sales) as day_net_sales
    from {{ ref('fact_sales_line') }} f
    join {{ ref('dim_date') }} d on d.date_key = f.date_key
    where d.is_trading_day
    group by d.full_date, d.event_name

)

select
    e.full_date,
    e.event_name,
    e.day_net_sales,
    c.floor_amount
from event_day_revenue e
cross join catalog_floor c
where e.day_net_sales < c.floor_amount
