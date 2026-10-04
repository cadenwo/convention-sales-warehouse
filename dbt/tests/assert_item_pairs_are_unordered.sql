/*
    Every pair must be stored exactly once, in one direction, and never as an
    item with itself.

    The `a.item_key < b.item_key` condition in fact_item_pairs is the whole
    thing keeping that true. Relax it to `<>` and every pair appears twice —
    A+B and B+A — so a "bought together 3 times" reads as two separate rows of
    3, and a top-N list fills with mirrored duplicates that look like distinct
    findings. Drop the condition entirely and every item pairs with itself,
    which outranks everything real.

    Both failures produce a chart that renders perfectly and says something
    false, so the invariant is asserted rather than assumed.
*/

select
    item_pair_key,
    item_a_key,
    item_b_key,
    item_a,
    item_b,
    baskets
from {{ ref('fact_item_pairs') }}
where item_a_key >= item_b_key
