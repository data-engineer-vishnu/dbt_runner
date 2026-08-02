#!/usr/bin/env sh
set -eu

cd "${DBT_PROJECT_DIR:-/app}"

if [ "$#" -eq 0 ]; then
    exec dbt \
      build \
      --project-dir "$PWD" \
      --profiles-dir "${DBT_PROFILES_DIR:-/app/profiles}"
fi

case "$1" in
    --help|-h|--version|-V|-v)
        exec dbt "$@"
        ;;
    # `docs` and `source` are command groups (e.g. `docs generate`,
    # `source freshness`) — the global flags must come after the
    # subcommand, not after the group name.
    docs|source)
        group="$1"
        sub="${2:-}"
        [ -n "$sub" ] || { echo "Usage: $group <subcommand> [args]" >&2; exit 1; }
        shift 2

        exec dbt \
          "$group" "$sub" \
          --project-dir "$PWD" \
          --profiles-dir "${DBT_PROFILES_DIR:-/app/profiles}" \
          "$@"
        ;;
    *)
        cmd="$1"
        shift

        exec dbt \
          "$cmd" \
          --project-dir "$PWD" \
          --profiles-dir "${DBT_PROFILES_DIR:-/app/profiles}" \
          "$@"
        ;;
esac