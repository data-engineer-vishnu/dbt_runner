{#-
  Renders a select list from the columns documented in a model's or source's
  YAML: columns with `data_type: STRING` are wrapped in double quotes ("Blue"),
  dates/numbers are formatted per column meta (below), every other column is
  selected as-is. Takes the same arguments as ref()/source():

      -- model
      select {{ quote_string_columns('churners') }} from {{ ref('churners') }}

      -- source
      select {{ quote_string_columns('bank', 'bank_churners') }}
      from {{ source('bank', 'bank_churners') }}

  Column list and types come from the YAML, not the warehouse, so:
  * only columns listed in the YAML are selected, in YAML order;
  * a column without a data_type is selected as-is;
  * if the YAML type is wrong, the output follows the YAML.

  Column meta (columns[].config.meta) adds formatting; formatted columns
  become STRING (see macros/column_formatting.sql for the date tokens):
  * date_format: YYYY-MM-DD    DATE/DATETIME/TIMESTAMP/TIME -> '2026-10-22'
  * timezone: Asia/Singapore   TIMESTAMP only, for date_format (default UTC)
  * decimal_places: 6          numeric -> exactly 6 decimals, 1.02 -> '1.020000'
  * quote: true/false          override quoting; default is quote only
                               columns whose data_type is STRING

  Args
  * escape:      double any " already inside a value (ab"c -> "ab""c"), the
                 CSV convention. Default true.
  * keep_nulls:  true (default) leaves NULL as NULL; false turns it into "".
  * table_alias: prefix columns with this alias (for use in joins).
-#}
{% macro quote_string_columns(name, table_name=none, escape=true, keep_nulls=true, table_alias=none) %}
  {#- The graph is only fully populated at run time; during parsing return a stub. -#}
  {%- if not execute -%}
    {{ return('*') }}
  {%- endif -%}

  {%- if table_name -%}
    {%- set matches = graph.sources.values()
          | selectattr('source_name', 'equalto', name)
          | selectattr('name', 'equalto', table_name) | list -%}
    {%- set label = "source('" ~ name ~ "', '" ~ table_name ~ "')" -%}
  {%- else -%}
    {%- set matches = graph.nodes.values()
          | selectattr('resource_type', 'in', ['model', 'seed', 'snapshot'])
          | selectattr('name', 'equalto', name) | list -%}
    {%- set label = "ref('" ~ name ~ "')" -%}
  {%- endif -%}

  {%- if matches | length == 0 -%}
    {{ exceptions.raise_compiler_error("quote_string_columns: " ~ label ~ " not found in the project") }}
  {%- endif -%}
  {%- set columns = matches[0].columns.values() | list -%}
  {%- if columns | length == 0 -%}
    {{ exceptions.raise_compiler_error("quote_string_columns: " ~ label ~ " has no columns in its YAML") }}
  {%- endif -%}

  {%- set prefix = (table_alias ~ '.') if table_alias else '' -%}
  {%- set selects = [] -%}
  {%- for col in columns -%}
    {%- set col_sql = prefix ~ adapter.quote(col.name) -%}
    {%- set meta = {} -%}
    {%- do meta.update(col.get('meta') or {}) -%}
    {%- do meta.update((col.get('config') or {}).get('meta') or {}) -%}
    {%- set is_string = (col.data_type or '') | upper == 'STRING' -%}

    {%- if meta.get('date_format') -%}
      {%- set value = format_date_expr(col_sql, col.data_type, meta['date_format'], meta.get('timezone', 'UTC')) -%}
    {%- elif meta.get('decimal_places') is not none -%}
      {%- set value = format_decimal_expr(col_sql, col.data_type, meta['decimal_places']) -%}
    {%- else -%}
      {%- set value = col_sql -%}
    {%- endif -%}

    {%- if meta.get('quote', is_string) -%}
      {%- if value == col_sql and not is_string -%}
        {%- set value = string_expr(col_sql, col.data_type) -%}
      {%- endif -%}
      {%- if escape -%}
        {%- set value = "replace(" ~ value ~ ", '\"', '\"\"')" -%}
      {%- endif -%}
      {%- if not keep_nulls -%}
        {%- set value = "coalesce(" ~ value ~ ", '')" -%}
      {%- endif -%}
      {%- set expr = "'\"' || " ~ value ~ " || '\"'" -%}
    {%- else -%}
      {%- set expr = value -%}
    {%- endif -%}
    {%- do selects.append(expr ~ ' as ' ~ adapter.quote(col.name)) -%}
  {%- endfor -%}

  {{ return(selects | join(',\n    ')) }}
{% endmacro %}
