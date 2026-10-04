{{
    config(
        materialized='view',
        tags=['staging']
    )
}}

/*
    Cleans the raw landing table and derives the natural keys the marts join on.
    No aggregation and no joins — one row in, one row out — so any row count
    difference downstream is attributable to a specific join, not to this model.
*/

with source as (

    select * from {{ source('raw', 'sales_line_items') }}

),

cleaned as (

    select
        transaction_id,
        sale_date,
        sale_time,

        -- 7 rows carry no SKU, so SKU alone cannot identify an item.
        -- Falling back to the item name keeps those sales in the model.
        coalesce(nullif(trim(sku), ''), item)          as item_natural_key,
        nullif(trim(sku), '')                          as sku,
        item                                           as item_name,
        price_point_name,

        -- 4 rows were rung up without a category. An explicit member keeps
        -- their revenue visible in a category rollup instead of silently
        -- dropping it behind a null foreign key.
        --
        -- The sentinel check is not paranoia: the Square CSV export writes the
        -- literal string "None" for uncategorised items, and any pandas-based
        -- loader will happily write "nan". Either would otherwise become a
        -- category named "None" or "nan" sitting in the dashboard.
        -- Casing and separators are standardised here, not left to each
        -- consumer. Square categories are typed by hand across many sessions,
        -- so the source contains 'handmade', 'Blindbag', 'misc' and
        -- 'art_prints' side by side. Left alone, a dashboard shows all four
        -- spellings and 'handmade' and 'Handmade' count as separate categories.
        --
        -- This does merge case variants rather than merely relabelling them,
        -- which is the intent: they are the same category typed twice.
        -- initcap() and replace() exist on both Postgres and Redshift.
        case
            when category is null then 'Uncategorized'
            when lower(trim(category)) in ('', 'none', 'nan', 'null', 'n/a')
                then 'Uncategorized'
            else initcap(replace(trim(category), '_', ' '))
        end as category_name,

        location                                       as location_id,
        device_name_key,
        channel,
        itemization_type,

        coalesce(qty, 0)                               as quantity,
        coalesce(gross_sales, 0)                       as gross_sales,
        coalesce(discounts, 0)                         as discounts,
        coalesce(net_sales, 0)                         as net_sales,
        coalesce(tax, 0)                               as tax,

        source_file

    from source
    where transaction_id is not null
      and item is not null

)

select * from cleaned
