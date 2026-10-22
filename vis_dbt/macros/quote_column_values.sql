{#-
  Renders a select list that wraps every value of a relation in double quotes
  ("Blue"), keeping the column names. Non-string columns are converted to
  STRING first (same rules as cast_columns_to_string).

      select {{ quote_column_values(ref('churners')) }}
      from {{ ref('churners') }}

  Args
  * relation:    a ref(), source() or other relation.
  * exclude:     column names to leave out of the select list entirely.
  * keep_as_is:  column names to select unchanged (not quoted).
  * quote_char:  character to wrap values in (default ").
  * escape:      double any quote_char already inside a value
                 (ab"c -> "ab""c"), the CSV convention. Default true.
  * keep_nulls:  true (default) leaves NULL as NULL; false turns it into "".
  * table_alias: prefix columns with this alias (for use in joins).
-#}
{% macro quote_column_values(relation, exclude=[], keep_as_is=[], quote_char='"', escape=true, keep_nulls=true, table_alias=none) %}
  {#- Columns are only known at run time; during parsing return a stub. -#}
  {%- if not execute -%}
    {{ return('*') }}
  {%- endif -%}

  {%- set exclude_lower = exclude | map('lower') | list -%}
  {%- set keep_lower = keep_as_is | map('lower') | list -%}
  {%- set prefix = (table_alias ~ '.') if table_alias else '' -%}
  {%- set q = "'" ~ (quote_char | replace("\\", "\\\\") | replace("'", "\\'")) ~ "'" -%}
  {%- set selects = [] -%}

  {%- for col in adapter.get_columns_in_relation(relation) -%}
    {%- if col.name | lower not in exclude_lower -%}
      {%- set name = adapter.quote(col.name) -%}
      {%- if col.name | lower in keep_lower -%}
        {%- set expr = prefix ~ name -%}
      {%- else -%}
        {%- set value = string_expr(prefix ~ name, col.data_type) -%}
        {%- if escape -%}
          {%- set value = 'replace(' ~ value ~ ', ' ~ q ~ ', ' ~ q ~ ' || ' ~ q ~ ')' -%}
        {%- endif -%}
        {%- if not keep_nulls -%}
          {%- set value = "coalesce(" ~ value ~ ", '')" -%}
        {%- endif -%}
        {%- set expr = q ~ ' || ' ~ value ~ ' || ' ~ q -%}
      {%- endif -%}
      {%- do selects.append(expr ~ ' as ' ~ name) -%}
    {%- endif -%}
  {%- endfor -%}

  {%- if selects | length == 0 -%}
    {{ exceptions.raise_compiler_error("quote_column_values: no columns found in " ~ relation ~ " (does it exist yet?)") }}
  {%- endif -%}

  {{ return(selects | join(',\n    ')) }}
{% endmacro %}
