{#
    By default dbt prefixes custom schemas with the target schema, producing
    names like `public_warehouse`. Overriding this gives the warehouse the
    clean layer names the architecture actually describes:

        raw       written by the Python extract-load job (dbt only reads it)
        staging   dbt views: cleaned, typed, one row in one row out
        warehouse dbt tables: the star schema Tableau connects to
#}

{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
