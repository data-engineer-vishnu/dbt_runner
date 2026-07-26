#!/usr/bin/env sh
set -eu

cd "${DBT_PROJECT_DIR:-/app}"

# Cloud Run Job arguments are appended to this entrypoint. For example:
#   ["build", "--select", "tag:daily"]
#   ["run", "--select", "tag:daily", "--vars", "{execution_date: 2026-07-25}"]
exec dbt "$@" --project-dir "$PWD" --profiles-dir "${DBT_PROFILES_DIR:-/app/profiles}"
