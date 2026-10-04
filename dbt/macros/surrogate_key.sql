{#
    Deterministic surrogate key.

    Equivalent to dbt_utils.generate_surrogate_key, vendored deliberately: the
    pipeline runs as a scheduled Fargate task, and `dbt deps` reaching out to
    hub.getdbt.com at build time would make a nightly run depend on a third
    party being reachable. One macro is cheaper than that failure mode.

    Nulls are replaced with a sentinel before hashing so that (NULL, 'a') and
    ('a', NULL) produce different keys — concatenating raw nulls would collapse
    both to the same value. Fields are separated by a character that cannot
    appear in the data for the same reason.

    md5() exists on both Postgres and Redshift, so the same macro works against
    a local dev database and the production warehouse.
#}

{% macro surrogate_key(field_list) -%}

    {%- set null_sentinel = '_sk_null_' -%}
    {%- set fields = [] -%}

    {%- for field in field_list -%}
        {%- do fields.append(
            "coalesce(cast(" ~ field ~ " as varchar), '" ~ null_sentinel ~ "')"
        ) -%}
        {%- if not loop.last -%}
            {%- do fields.append("'-'") -%}
        {%- endif -%}
    {%- endfor -%}

    md5({{ fields | join(' || ') }})

{%- endmacro %}
