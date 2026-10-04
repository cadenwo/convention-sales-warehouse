{{ config(materialized='table', tags=['marts']) }}

/*
    One row per date on which the account recorded activity.

    Two problems are solved here, and they interact.

    1. Events, not a single timeline. The account records sales from more than
       one convention, separated by weeks of silence. Numbering days globally
       would make the March date "Day 1" and the first April date "Day 2", so
       every day-over-day and cumulative query would silently compare across
       unrelated events. Dates are therefore grouped into events with a
       gaps-and-islands pattern: a gap of more than EVENT_GAP_DAYS since the
       previous qualifying day starts a new event.

    2. Not every date with activity is a trading day. A card swipe made before
       a convention, to confirm the terminal works, produces a real order for a
       token amount. Left alone it becomes an entire one-day "event" sitting
       beside a three-day convention, which distorts every per-event average
       and puts a phantom column on the dashboard.

       The rule that separates the two is derived from the catalog rather than
       chosen: a day whose entire takings are less than the cheapest item on
       sale cannot contain a completed product sale. That floor is computed
       below from ITEM lines only. Including CUSTOM_AMOUNT lines would let a
       token charge define the floor and then clear it — the threshold would
       look principled and do nothing.

       Nothing is deleted. The date keeps its row so the fact table's foreign
       key still resolves; it is flagged with is_trading_day = false and
       excluded from event numbering.
*/

{% set event_gap_days = 7 %}

with catalog_floor as (

    -- The cheapest unit price of an actual catalog item. ITEM only: a
    -- CUSTOM_AMOUNT is an arbitrary charge typed at the terminal, not a
    -- product with a price, so it cannot define what a sale is worth.
    select min(gross_sales / quantity) as floor_amount
    from {{ ref('stg_sales') }}
    where itemization_type = 'ITEM'
      and quantity > 0
      and gross_sales > 0

),

daily as (

    select
        sale_date,
        sum(net_sales) as day_net_sales
    from {{ ref('stg_sales') }}
    where sale_date is not null
    group by sale_date

),

classified as (

    select
        d.sale_date,
        d.day_net_sales,
        -- coalesce(floor, 0) fails open: a dataset with no catalog items at all
        -- should not silently mark every day non-trading. The threshold exists
        -- to remove obvious non-days, not to gate the whole model.
        case when d.day_net_sales >= coalesce(f.floor_amount, 0)
             then true else false end as is_trading_day
    from daily d
    cross join catalog_floor f

),

gaps as (

    select
        sale_date,
        lag(sale_date) over (order by sale_date) as prev_date,
        case
            when lag(sale_date) over (order by sale_date) is null then 1
            -- Plain date subtraction rather than datediff(): both Postgres and
            -- Redshift return an integer number of days, whereas datediff() is
            -- Redshift-only and would break local development.
            when sale_date - lag(sale_date) over (order by sale_date)
                 > {{ event_gap_days }} then 1
            else 0
        end as is_event_start
    from classified
    where is_trading_day

),

events as (

    select
        sale_date,
        -- Running total of "new event" flags: every date in the same island
        -- accumulates the same number, which becomes the event's index.
        sum(is_event_start) over (order by sale_date
                                  rows between unbounded preceding and current row)
            as event_number
    from gaps

),

labelled as (

    select
        sale_date,
        event_number,
        min(sale_date) over (partition by event_number) as event_start_date,
        row_number() over (partition by event_number order by sale_date) as day_in_event
    from events

)

select
    {{ surrogate_key(['c.sale_date']) }}                    as date_key,
    c.sale_date                                            as full_date,
    c.is_trading_day,

    -- Non-trading dates get event 0 rather than null, so the not_null tests on
    -- these columns stay meaningful for the rows that matter. Queries filter on
    -- is_trading_day, which says what it means; a null would only imply it.
    {{ surrogate_key(['coalesce(l.event_number, 0)']) }}    as event_key,
    case
        when l.event_number is null then 'Non-trading day'
        else 'Event ' || cast(l.event_number as varchar)
             || ' (' || cast(l.event_start_date as varchar) || ')'
    end                                                    as event_name,
    l.event_start_date,

    case
        when l.day_in_event is null then 'Non-trading'
        else 'Day ' || cast(l.day_in_event as varchar)
    end                                                    as convention_day,
    coalesce(l.day_in_event, 0)                            as day_in_event,

    trim(to_char(c.sale_date, 'Day'))                      as day_of_week,
    -- extract(dow) is 0=Sunday on both Postgres and Redshift.
    case when extract(dow from c.sale_date) in (0, 6)
         then true else false end                          as is_weekend
from classified c
left join labelled l on l.sale_date = c.sale_date
