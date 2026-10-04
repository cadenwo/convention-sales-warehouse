{{ config(materialized='table', tags=['marts']) }}

/*
    Grain: one row per item per pair. Exactly two rows for every row in
    fact_item_pairs.

    A bridge table, resolving the many-to-many between items and pairs.

    fact_item_pairs stores each pair once, as (item_a, item_b), in hash order.
    That is right for counting — storing both directions would double every
    basket — and wrong for filtering. "What sells with Pikmin plush 2?" has to
    find the item whichever column it landed in, and a relationship on
    item_a_key alone finds an arbitrary subset of its pairs.

    Relating dim_item -> bridge_item_pair -> fact_item_pairs fixes that without
    touching the fact: an item filter selects bridge rows, the bridge selects
    pairs, and each pair's baskets are still counted once.
*/

with pairs as (

    select item_pair_key, item_a_key, item_b_key
    from {{ ref('fact_item_pairs') }}

),

members as (

    select item_pair_key, item_a_key as item_key from pairs
    union all
    select item_pair_key, item_b_key as item_key from pairs

)

select
    {{ surrogate_key(['item_pair_key', 'item_key']) }} as pair_member_key,
    item_pair_key,
    item_key
from members
