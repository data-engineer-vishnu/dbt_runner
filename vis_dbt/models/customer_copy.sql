{{ config(materialized='table') }}

-- Fictional demonstration data only. Do not place production PII in model SQL.
select *
from {{ ref('customer')}}