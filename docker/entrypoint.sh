#!/usr/bin/env sh
set -eu

cd "${DBT_PROJECT_DIR:-/app}"

# Cloud Run Job arguments are appended to this entrypoint. For example:
#   ["build", "--select", "tag:daily"]
exec dbt "$@" --project-dir "$PWD" --profiles-dir "${DBT_PROFILES_DIR:-/app/profiles}"
