/*
    Every fact row must resolve to a real item and a real date.

    The relationships tests in _marts.yml check this per column; this checks
    that the joined result set is still the full fact table, which catches a
    dimension that built with fewer members than the fact references.
*/

select f.sale_line_key
from {{ ref('fact_sales_line') }} f
left join {{ ref('dim_item') }} i on f.item_key = i.item_key
left join {{ ref('dim_date') }} d on f.date_key = d.date_key
where i.item_key is null
   or d.date_key is null
