{{ config(materialized='table') }}

-- Every value of churners wrapped in double quotes (macros/quote_column_values.sql).
select
    {{ quote_column_values(ref('churners')) }}
from {{ ref('churners') }}
