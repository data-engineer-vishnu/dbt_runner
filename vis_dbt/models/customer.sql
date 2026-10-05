{{ config(materialized='table') }}

-- Fictional demonstration data only. Do not place production PII in model SQL.
select *
from unnest([
  struct(
    1 as customer_id,
    'Aisha Rahman' as full_name,
    'aisha.rahman@example.com' as email,
    '+65 8123 4567' as phone_number,
    'S1234567A' as national_id,
    'Singapore' as city
  ),
  struct(
    2 as customer_id,
    'Ben Carter' as full_name,
    'ben.carter@example.com' as email,
    '+65 8234 5678' as phone_number,
    'T7654321B' as national_id,
    'Singapore' as city
  ),
  struct(
    3 as customer_id,
    'Chloe Tan' as full_name,
    'chloe.tan@example.com' as email,
    '+65 8345 6789' as phone_number,
    'G2468101C' as national_id,
    'Singapore' as city
  )
])
