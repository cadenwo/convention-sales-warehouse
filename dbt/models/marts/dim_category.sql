{{ config(materialized='table', tags=['marts']) }}

/*
    One row per product category. Surrogate keys are a deterministic hash of
    the natural key rather than an auto-incrementing sequence: Redshift has no
    usable IDENTITY, and a hash means a full rebuild produces the same keys as
    the previous run, so the fact table never has to be reloaded just because
    the dimension was refreshed.
*/

with categories as (

    select distinct category_name
    from {{ ref('stg_sales') }}

)

select
    {{ surrogate_key(['category_name']) }} as category_key,
    category_name
from categories
