/*
    Every pair must resolve, through the bridge, to exactly its own two items.

    The bridge is what lets "what sells with X?" find X whichever side of the
    pair it was stored on. A pair missing a member row silently disappears when
    that item is selected; a pair with a wrong member shows up under an
    unrelated item. Both render as a plausible chart.

    Together with the unique test on pair_member_key, this pins each pair's
    bridge rows to exactly {item_a, item_b}: two rows, both of them members.
*/

select
    p.item_pair_key,
    p.pair_label,
    count(b.item_key) as bridge_rows,
    sum(case when b.item_key in (p.item_a_key, p.item_b_key) then 1 else 0 end)
        as member_rows
from {{ ref('fact_item_pairs') }} p
left join {{ ref('bridge_item_pair') }} b
       on b.item_pair_key = p.item_pair_key
group by p.item_pair_key, p.pair_label
having count(b.item_key) <> 2
    or sum(case when b.item_key in (p.item_a_key, p.item_b_key) then 1 else 0 end) <> 2
