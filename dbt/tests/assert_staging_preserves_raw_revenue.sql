/*
    Nothing may be silently dropped between the raw layer and staging.

    stg_sales filters out rows with a null item or transaction_id. That filter
    is a safety net, but a safety net that quietly discards real sales is worse
    than no filter at all — production data contained two unnamed CUSTOM_AMOUNT
    line items carrying $4 of genuine revenue, and without this test they would
    have vanished with every downstream reconciliation still reporting green,
    because those compare staging to fact, not raw to staging.

    This is the only test watching that boundary. If it fails, rows are being
    dropped at the staging filter and the extractor needs to handle them
    properly rather than staging discarding them.
*/

with raw_layer as (
    select
        count(*)        as row_count,
        sum(net_sales)  as revenue
    from {{ source('raw', 'sales_line_items') }}
),

staged as (
    select
        count(*)        as row_count,
        sum(net_sales)  as revenue
    from {{ ref('stg_sales') }}
)

select
    raw_layer.row_count  as raw_rows,
    staged.row_count     as staging_rows,
    raw_layer.revenue    as raw_revenue,
    staged.revenue       as staging_revenue
from raw_layer
cross join staged
where raw_layer.row_count != staged.row_count
   or abs(coalesce(raw_layer.revenue, 0) - coalesce(staged.revenue, 0)) > 0.01
