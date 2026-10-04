{{ config(materialized='table', tags=['marts']) }}

/*
    Grain: one row per unordered pair of items that appeared in the same
    transaction, per event, with the number of baskets containing both.

    Market basket analysis, at the scale this booth actually operates at. The
    question is "what should we bundle next April", and the answer comes from
    which things people already reach for together.

    Computed here rather than in the BI tool because it needs a self-join on
    transaction_id. A BI tool can be made to do that, but the join fans the
    fact table out and every other sheet built on the same source starts
    double-counting. One model, one grain, no side effects.

    Three details make the pair list correct rather than merely plausible:

      a.item_key < b.item_key   drops self-pairs (an item with itself) and
                                mirrored duplicates (A+B and B+A counted as
                                two different pairs). Comparing the hashed
                                keys gives a stable, arbitrary ordering —
                                arbitrary is fine, consistent is what matters.

      select distinct in lines  a transaction can contain the same item on two
                                lines (a second scan, a split quantity). Without
                                the distinct, that basket would pair the item
                                with itself and inflate every pair it takes part
                                in.

      event in the grain        a basket happens on one date, so a pair never
                                straddles two conventions. But without the
                                event in the grain, every convention's baskets
                                would be summed into one row, and no dashboard
                                filter could separate them again.

    Not filtered to pairs seen more than once. A single co-occurrence is weak
    evidence, but it is evidence, and the threshold belongs to whoever is
    asking rather than to the model.

    Because the item order is arbitrary, item_a_key and item_b_key are the
    wrong columns to filter on: an item lands in either one depending on its
    hash. Filter by item through bridge_item_pair instead.
*/

with lines as (

    -- One row per transaction per item, regardless of how many lines that
    -- item occupied in the basket. The event is constant within a
    -- transaction, so carrying it here changes no counts.
    select distinct
        d.event_key,
        d.event_name,
        f.transaction_id,
        f.item_key,
        i.item_name
    from {{ ref('fact_sales_line') }} f
    join {{ ref('dim_item') }} i on i.item_key = f.item_key
    join {{ ref('dim_date') }} d on d.date_key = f.date_key
    where d.is_trading_day

),

pairs as (

    select
        a.event_key,
        a.event_name,
        a.item_key  as item_a_key,
        b.item_key  as item_b_key,
        a.item_name as item_a,
        b.item_name as item_b,
        count(*)    as baskets
    from lines a
    join lines b
      on  a.transaction_id = b.transaction_id
      and a.item_key < b.item_key
    group by 1, 2, 3, 4, 5, 6

)

select
    {{ surrogate_key(['event_key', 'item_a_key', 'item_b_key']) }} as item_pair_key,

    event_key,
    event_name,

    item_a_key,
    item_b_key,
    item_a,
    item_b,

    -- Pre-built so a chart can put the pair on one axis without a calculated
    -- field. || concatenates on both Postgres and Redshift. Unique within an
    -- event, not across events: the same two items can sell together at more
    -- than one convention, and both rows are correct.
    item_a || '  +  ' || item_b as pair_label,

    baskets

from pairs
