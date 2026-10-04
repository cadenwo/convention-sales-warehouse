/*
    Within one event, a pair label must point at exactly one pair.

    pair_label used to carry a plain `unique` test. That stopped being true by
    design once pairs were grained by event: the same two items can sell
    together at more than one convention, and both rows are correct.

    What must still hold is uniqueness inside an event. Two items sharing a
    display name under different SKUs would otherwise produce two rows a chart
    cannot tell apart — they would render as one bar with a summed count, and
    nothing on screen would look wrong.
*/

select
    event_key,
    pair_label,
    count(*) as rows_with_this_label
from {{ ref('fact_item_pairs') }}
group by event_key, pair_label
having count(*) > 1
