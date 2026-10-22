{{ config(materialized='table') }}

-- Every column of customer as STRING (e.g. for CSV export via bq-exporter).
-- Masks on customer's columns are inherited by macros/masking.sql.
select
    {{ cast_columns_to_string(ref('customer')) }}
from {{ ref('customer') }}
