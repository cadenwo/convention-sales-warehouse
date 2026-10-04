{{ config(materialized='table', tags=['marts']) }}

/*
    One row per sellable item, keyed on COALESCE(sku, item_name).

    The original MySQL build joined dimensions on the item's display text,
    which collides as soon as two categories carry the same item name. Keying
    on the SKU where one exists removes that failure mode.
*/

with items as (

    select
        item_natural_key,
        max(sku)           as sku,
        max(item_name)     as item_name,
        max(category_name) as category_name
    from {{ ref('stg_sales') }}
    group by item_natural_key

)

select
    {{ surrogate_key(['item_natural_key']) }} as item_key,
    {{ surrogate_key(['category_name']) }}    as category_key,
    item_natural_key,
    sku,
    item_name,
    category_name
from items
