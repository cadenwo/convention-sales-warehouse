{{ config(materialized='table', tags=['marts']) }}

/*
    Grain: one row per item per trading day — including the days an item sold
    nothing.

    fact_sales_line records what happened. That is correct for a transactional
    fact, and it is also why it cannot answer "what stopped selling": an item
    that sold nothing on Day 3 simply has no Day 3 row, so a day-over-day
    calculation has no neighbour to compare against and returns null. The
    largest declines — an item going to zero — vanish from the chart that
    exists to show declines.

    This model manufactures the missing rows. dim_item is crossed with the
    trading days from dim_date, actual sales are joined on, and absences become
    explicit zeros.

    Zero-filling is only honest when absence provably means zero, and here it
    does: fact_sales_line is a complete record of sales on these dates, so an
    item with no row genuinely sold none. (A missing sensor reading would be a
    different case — that is unknown, not zero, and filling it would fabricate
    a measurement.)

    Deliberately not a replacement for fact_sales_line. That one stays at
    line-item grain for basket analysis and transaction counts; this one is a
    daily aggregate for trend and stock questions. Two facts, two grains, one
    conformed set of dimensions.

    Non-trading days are excluded, so the pre-convention terminal test does not
    generate a day of phantom zero rows for every item in the catalog.
*/

with trading_days as (

    -- The day labels ride along rather than being looked up. This is an
    -- aggregate reporting table, and carrying its own grain labels means a
    -- consumer needs one relationship (to dim_item) instead of two. The
    -- redundancy is real and deliberate: dim_date remains the single source
    -- of these values, and they are copied here, not recomputed.
    select
        date_key,
        full_date,
        convention_day,
        day_in_event,
        event_name
    from {{ ref('dim_date') }}
    where is_trading_day

),

grid as (

    -- Every combination that *should* exist, whether or not it does.
    select
        i.item_key,
        i.item_name,
        i.category_name,
        d.date_key,
        d.full_date,
        d.convention_day,
        d.day_in_event,
        d.event_name
    from {{ ref('dim_item') }} i
    cross join trading_days d

),

actual as (

    select
        item_key,
        date_key,
        sum(quantity)                  as quantity,
        sum(net_sales)                 as net_sales,
        sum(gross_sales)               as gross_sales,
        count(distinct transaction_id) as transactions
    from {{ ref('fact_sales_line') }}
    group by item_key, date_key

)

select
    {{ surrogate_key(['g.item_key', 'g.date_key']) }} as item_day_key,

    g.item_key,
    g.item_name,
    g.category_name,

    g.date_key,
    g.full_date,
    g.convention_day,
    g.day_in_event,
    g.event_name,

    coalesce(a.quantity, 0)     as quantity,
    coalesce(a.net_sales, 0)    as net_sales,
    coalesce(a.gross_sales, 0)  as gross_sales,
    coalesce(a.transactions, 0) as transactions,

    -- Distinguishes a manufactured row from a real one. Not redundant with
    -- quantity = 0: a refund or a zero-quantity line would be a real row that
    -- happens to net to nothing, and that is a different fact from "this item
    -- was not sold at all today".
    case when a.item_key is null then false else true end as sold_that_day

from grid g
left join actual a
       on a.item_key = g.item_key
      and a.date_key = g.date_key
