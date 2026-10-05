{{ config(materialized='table') }}
-- Demonstrates consuming the `execution_date` var passed on the CLI
-- (e.g. `dbt run --vars "{execution_date: 2026-08-02}"`).
-- Falls back to the run's start date if execution_date isn't supplied.

{% set execution_date = var('execution_date', run_started_at.strftime('%Y-%m-%d')) %}

select
    *,
    cast('{{ execution_date }}' as date) as execution_date

from {{ ref('my_second_dbt_model') }}
