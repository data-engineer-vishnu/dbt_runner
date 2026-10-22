{#-
  Renders a select list that casts every column of a relation to STRING,
  keeping the column names. Handy for file exports where every value should
  be text.

      select {{ cast_columns_to_string(ref('customer')) }}
      from {{ ref('customer') }}

  Args
  * relation: a ref(), source() or other relation.
  * exclude:  column names to leave out of the select list entirely.
  * keep_type: column names to select as-is (not cast).
  * table_alias: prefix columns with this alias (for use in joins).

  BigQuery can't CAST STRUCT/ARRAY/JSON to STRING, so those become
  TO_JSON_STRING(...); BYTES become base64. Everything else uses CAST.
-#}
{% macro cast_columns_to_string(relation, exclude=[], keep_type=[], table_alias=none) %}
  {#- Columns are only known at run time; during parsing return a stub. -#}
  {%- if not execute -%}
    {{ return('*') }}
  {%- endif -%}

  {%- set exclude_lower = exclude | map('lower') | list -%}
  {%- set keep_lower = keep_type | map('lower') | list -%}
  {%- set prefix = (table_alias ~ '.') if table_alias else '' -%}
  {%- set selects = [] -%}

  {%- for col in adapter.get_columns_in_relation(relation) -%}
    {%- if col.name | lower not in exclude_lower -%}
      {%- set name = adapter.quote(col.name) -%}
      {%- if col.name | lower in keep_lower -%}
        {%- set expr = prefix ~ name -%}
      {%- else -%}
        {%- set expr = string_expr(prefix ~ name, col.data_type) -%}
      {%- endif -%}
      {%- do selects.append(expr ~ ' as ' ~ name) -%}
    {%- endif -%}
  {%- endfor -%}

  {%- if selects | length == 0 -%}
    {{ exceptions.raise_compiler_error("cast_columns_to_string: no columns found in " ~ relation ~ " (does it exist yet?)") }}
  {%- endif -%}

  {{ return(selects | join(',\n    ')) }}
{% endmacro %}


{#- SQL expression turning `column_sql` of BigQuery type `data_type` into a STRING. -#}
{% macro string_expr(column_sql, data_type) %}
  {%- set dtype = data_type | upper -%}
  {%- if dtype == 'STRING' -%}
    {{ return(column_sql) }}
  {%- elif dtype.startswith('STRUCT') or dtype.startswith('ARRAY') or dtype.startswith('RECORD') or dtype == 'JSON' -%}
    {{ return('to_json_string(' ~ column_sql ~ ')') }}
  {%- elif dtype == 'BYTES' -%}
    {{ return('to_base64(' ~ column_sql ~ ')') }}
  {%- else -%}
    {{ return('cast(' ~ column_sql ~ ' as string)') }}
  {%- endif -%}
{% endmacro %}
