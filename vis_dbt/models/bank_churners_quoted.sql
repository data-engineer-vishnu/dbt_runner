{{ config(materialized='table') }}

-- bank_churners with STRING columns wrapped in double quotes and all other
-- columns unchanged. Column types come from models/bank_churners.yml
-- (macros/quote_string_columns.sql).
select
    {{ quote_string_columns('bank', 'bank_churners') }}
from {{ source('bank', 'bank_churners') }}
