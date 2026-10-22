{#-
  Column formatting helpers driven by YAML column meta (used by
  quote_string_columns):

      - name: opened_on
        data_type: DATE
        config:
          meta:
            date_format: YYYY-MM-DD     # -> STRING
      - name: Credit_Limit
        data_type: FLOAT64
        config:
          meta:
            decimal_places: 6           # 1.02 -> "1.020000" (STRING)

  date_format tokens (case-sensitive, longest match wins; anything else is
  copied literally, e.g. "-", "/", " ", "T", ":"):

    year      YYYY yyyy -> 2026          YY yy -> 26
    month     MM -> 01-12   MON Mon MMM -> Oct   MONTH Month MMMM -> October
    day       DD dd -> 01-31   DDD -> day of year 001-366
    weekday   DY Dy EEE -> Thu   DAY Day EEEE -> Thursday
    hour      HH24 HH -> 00-23   HH12 hh -> 01-12   AM / PM -> AM or PM
    minute    MI mi mm -> 00-59
    second    SS ss -> 00-59
    fraction  SS.FF1 .. SS.FF6 -> seconds with 1-6 decimals (05.123)
              SS.SSS ss.SSS -> 05.123   SS.SSSSSS ss.SSSSSS -> 05.123456
    zone      TZH:TZM XXX -> +08:00   TZ -> zone name (TIMESTAMP only)
    quarter   Q -> 1-4

  Examples: YYYYMMDD, YYYY-MM-DD, DD/MM/YYYY, MM/DD/YYYY, DD-MON-YYYY,
  YYYY-MM-DD HH24:MI:SS, YYYY-MM-DDTHH24:MI:SS.FF6, yyyy-MM-dd HH:mm:ss,
  DD/MM/YYYY hh:mm:ss AM, YYYYMMDDHH24MISS.

  A format containing "%" is passed to BigQuery unchanged (raw format
  elements), for anything the tokens don't cover.
-#}

{% macro to_bq_date_format(fmt) %}
  {%- if '%' in fmt -%}
    {{ return(fmt) }}
  {%- endif -%}
  {%- set tokens = [
      ('SS.SSSSSS', '%E6S'), ('ss.SSSSSS', '%E6S'),
      ('SS.FF1', '%E1S'), ('SS.FF2', '%E2S'), ('SS.FF3', '%E3S'),
      ('SS.FF4', '%E4S'), ('SS.FF5', '%E5S'), ('SS.FF6', '%E6S'),
      ('SS.SSS', '%E3S'), ('ss.SSS', '%E3S'),
      ('TZH:TZM', '%Ez'),
      ('MONTH', '%B'), ('Month', '%B'),
      ('YYYY', '%Y'), ('yyyy', '%Y'), ('MMMM', '%B'), ('EEEE', '%A'),
      ('HH24', '%H'), ('HH12', '%I'),
      ('MON', '%b'), ('Mon', '%b'), ('MMM', '%b'),
      ('DAY', '%A'), ('Day', '%A'), ('DDD', '%j'), ('EEE', '%a'), ('XXX', '%Ez'),
      ('YY', '%y'), ('yy', '%y'), ('MM', '%m'), ('DD', '%d'), ('dd', '%d'),
      ('DY', '%a'), ('Dy', '%a'),
      ('HH', '%H'), ('hh', '%I'), ('MI', '%M'), ('mi', '%M'), ('mm', '%M'),
      ('SS', '%S'), ('ss', '%S'), ('AM', '%p'), ('PM', '%p'), ('TZ', '%Z'),
      ('Q', '%Q'),
  ] -%}
  {%- set ns = namespace(out='', skip=0, hit=false) -%}
  {%- for i in range(fmt | length) -%}
    {%- if ns.skip > 0 -%}
      {%- set ns.skip = ns.skip - 1 -%}
    {%- else -%}
      {%- set ns.hit = false -%}
      {%- for tok, bq in tokens -%}
        {%- if not ns.hit and fmt[i:i + (tok | length)] == tok -%}
          {%- set ns.out = ns.out ~ bq -%}
          {%- set ns.skip = (tok | length) - 1 -%}
          {%- set ns.hit = true -%}
        {%- endif -%}
      {%- endfor -%}
      {%- if not ns.hit -%}
        {%- set ns.out = ns.out ~ fmt[i] -%}
      {%- endif -%}
    {%- endif -%}
  {%- endfor -%}
  {{ return(ns.out) }}
{% endmacro %}


{#- FORMAT_<type>(...) of a DATE/DATETIME/TIMESTAMP/TIME column; NULL stays NULL. -#}
{% macro format_date_expr(column_sql, data_type, fmt, timezone='UTC') %}
  {%- set dtype = (data_type or '') | upper -%}
  {%- set f = "'" ~ (to_bq_date_format(fmt) | replace("\\", "\\\\") | replace("'", "\\'")) ~ "'" -%}
  {%- if dtype == 'DATE' -%}
    {{ return('format_date(' ~ f ~ ', ' ~ column_sql ~ ')') }}
  {%- elif dtype == 'DATETIME' -%}
    {{ return('format_datetime(' ~ f ~ ', ' ~ column_sql ~ ')') }}
  {%- elif dtype == 'TIMESTAMP' -%}
    {{ return('format_timestamp(' ~ f ~ ', ' ~ column_sql ~ ", '" ~ timezone ~ "')") }}
  {%- elif dtype == 'TIME' -%}
    {{ return('format_time(' ~ f ~ ', ' ~ column_sql ~ ')') }}
  {%- else -%}
    {{ exceptions.raise_compiler_error("date_format needs data_type DATE, DATETIME, TIMESTAMP or TIME, got " ~ (data_type or 'none') ~ " for " ~ column_sql) }}
  {%- endif -%}
{% endmacro %}


{#- Number as a STRING with exactly `places` decimals (1.02, 6 -> 1.020000). -#}
{#- Rounds half away from zero via BIGNUMERIC. Floats go through their shortest
    string form first, so 1.005 (stored as 1.00499...) rounds to 1.01. -#}
{% macro format_decimal_expr(column_sql, data_type, places) %}
  {%- set dtype = (data_type or '') | upper -%}
  {%- if dtype not in ['FLOAT64', 'FLOAT', 'NUMERIC', 'BIGNUMERIC', 'DECIMAL', 'BIGDECIMAL', 'INT64', 'INTEGER'] -%}
    {{ exceptions.raise_compiler_error("decimal_places needs a numeric data_type, got " ~ (data_type or 'none') ~ " for " ~ column_sql) }}
  {%- endif -%}
  {%- set n = places | int -%}
  {%- if n < 0 or n > 38 or (places | string) != (n | string) -%}
    {{ exceptions.raise_compiler_error("decimal_places must be a whole number 0-38, got " ~ places ~ " for " ~ column_sql) }}
  {%- endif -%}
  {%- set exact = ('cast(cast(' ~ column_sql ~ ' as string) as bignumeric)') if dtype in ['FLOAT64', 'FLOAT'] else ('cast(' ~ column_sql ~ ' as bignumeric)') -%}
  {{ return("case when " ~ column_sql ~ " is null then null else format('%." ~ n ~ "f', round(" ~ exact ~ ", " ~ n ~ ")) end") }}
{% endmacro %}
