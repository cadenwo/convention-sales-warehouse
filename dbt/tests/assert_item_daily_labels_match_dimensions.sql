/*
    The copied labels must still agree with the dimensions they came from.

    fact_item_daily carries item_name, convention_day and event_name so a BI
    tool needs one relationship instead of three. That redundancy is the whole
    risk: a copied value can drift from its source and nothing about the table
    would look wrong — every chart still renders, with a stale label.

    So the copies are checked against dim_item and dim_date on every build.
    Denormalising is a fair trade only if something guarantees the copy is
    still true.
*/

select
    f.item_day_key,
    f.item_name       as fact_item_name,
    i.item_name       as dim_item_name,
    f.convention_day  as fact_convention_day,
    d.convention_day  as dim_convention_day,
    f.event_name      as fact_event_name,
    d.event_name      as dim_event_name
from {{ ref('fact_item_daily') }} f
join {{ ref('dim_item') }} i on i.item_key = f.item_key
join {{ ref('dim_date') }} d on d.date_key = f.date_key
where f.item_name      <> i.item_name
   or f.convention_day <> d.convention_day
   or f.event_name     <> d.event_name
