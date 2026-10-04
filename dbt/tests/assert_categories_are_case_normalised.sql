/*
    No two categories may differ only by casing or separator.

    stg_sales standardises category names, so this should never fail as written.
    That is the point: it is a regression guard on the standardisation, not a
    check on the source. If someone simplifies that CASE expression later,
    'Stickers' and 'stickers' become two categories again — splitting revenue
    across a duplicate that looks entirely plausible on a dashboard.

    Comparing on lower(replace(...)) rather than lower() alone also catches a
    separator regression: 'Art Prints' and 'art_prints' collapse to the same
    key here, so dropping the replace() would fail this test too.
*/

select
    lower(replace(category_name, ' ', '')) as normalised,
    count(*)                               as distinct_spellings,
    min(category_name)                     as example_a,
    max(category_name)                     as example_b
from {{ ref('dim_category') }}
group by 1
having count(*) > 1
