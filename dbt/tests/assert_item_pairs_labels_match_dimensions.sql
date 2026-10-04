/*
    The names and event label copied onto fact_item_pairs must still agree
    with the dimensions they came from.

    Same contract as assert_item_daily_labels_match_dimensions: the copies
    exist so a chart needs no extra relationship, and they are a fair trade
    only if something checks they are still true. A stale copy renders
    perfectly and says the wrong thing.
*/

with events as (

    -- dim_date has one row per date; the event label is constant per event.
    select distinct event_key, event_name
    from {{ ref('dim_date') }}

)

select
    p.item_pair_key,
    p.item_a,     ia.item_name as dim_item_a,
    p.item_b,     ib.item_name as dim_item_b,
    p.event_name, e.event_name as dim_event_name
from {{ ref('fact_item_pairs') }} p
join {{ ref('dim_item') }} ia on ia.item_key = p.item_a_key
join {{ ref('dim_item') }} ib on ib.item_key = p.item_b_key
join events e on e.event_key = p.event_key
where p.item_a     <> ia.item_name
   or p.item_b     <> ib.item_name
   or p.event_name <> e.event_name
