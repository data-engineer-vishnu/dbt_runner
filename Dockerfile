FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    DBT_PROJECT_DIR=/app \
    DBT_PROFILES_DIR=/app/profiles

WORKDIR /app

RUN groupadd --system dbt && useradd --system --gid dbt --create-home dbt

COPY requirements.txt ./
RUN pip install --requirement requirements.txt

# Install dbt packages while building so job executions do not need network access
# to the dbt package registry.
COPY dbt_project.yml packages.yml ./
RUN dbt deps --project-dir /app

COPY models ./models
COPY macros ./macros
COPY profiles ./profiles
COPY docker/entrypoint.sh /usr/local/bin/dbt-entrypoint

RUN chmod 0555 /usr/local/bin/dbt-entrypoint \
    && chown --recursive dbt:dbt /app

USER dbt

ENTRYPOINT ["/usr/local/bin/dbt-entrypoint"]
CMD ["build"]
