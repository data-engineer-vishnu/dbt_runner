{{ config(materialized='view', tags=['example']) }}

select
  1 as example_id,
  current_timestamp() as loaded_at
