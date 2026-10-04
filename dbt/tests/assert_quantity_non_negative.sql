/*
    A negative quantity would mean a refund leaked through as a sale line.
    Refunds belong in their own flow, not as negative rows in the sales fact.
*/
select sale_line_key, quantity
from {{ ref('fact_sales_line') }}
where quantity < 0
