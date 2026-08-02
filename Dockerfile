FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    DBT_PROJECT_DIR=/app \
    DBT_PROFILES_DIR=/app/profiles

WORKDIR /app

RUN apt-get update \
    && apt-get install --yes --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --system dbt && useradd --system --gid dbt --create-home dbt

COPY requirements.txt ./
RUN pip install --requirement requirements.txt

# Install dbt packages while building so job executions do not need network
# access to the dbt package registry. Copy just the project/package manifests
# first so this layer only rebuilds when dependencies actually change.
# packages.yml is optional (the glob is a no-op if it doesn't exist yet).
COPY vis_dbt/dbt_project.yml vis_dbt/packages.yml* ./
RUN if [ -f packages.yml ]; then dbt deps --project-dir /app; fi

# Copy the rest of the dbt project (models, macros, seeds, snapshots, tests,
# analyses, etc.) from the vis_dbt/ subfolder.
COPY vis_dbt/ ./

COPY profiles ./profiles
COPY docker/entrypoint.sh /usr/local/bin/dbt-entrypoint

RUN chmod 0555 /usr/local/bin/dbt-entrypoint \
    && chown --recursive dbt:dbt /app

USER dbt

# Cloud Run Job / Airflow overrides append arguments here, e.g.:
#   ["run", "--select", "tag:daily", "--vars", "{execution_date: 2026-07-25}"]
ENTRYPOINT ["/usr/local/bin/dbt-entrypoint"]
CMD ["build"]
