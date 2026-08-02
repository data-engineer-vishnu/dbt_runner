-- Singular test: fails if any row in my_first_dbt_model has a non-positive id.
-- dbt test passes when this query returns zero rows.

select *
from {{ ref('my_first_dbt_model') }}
where id <= 0
