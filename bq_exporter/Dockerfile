# bq-exporter image. Built from this folder only (build context = bq_exporter/),
# independent of the dbt-runner Dockerfile at the repo root.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

RUN groupadd --system app && useradd --system --gid app app

COPY requirements.txt ./
RUN pip install --requirement requirements.txt

COPY main.py ./

USER app

# Cloud Run Job / Airflow overrides supply one JSON config, as the single arg
#   ['{"table_name": "p.d.t", "file_location": "gs://b/x.csv", "delimiter": "|"}']
# or in the EXPORT_CONFIG env var. See main.py for the keys.
ENTRYPOINT ["python", "/app/main.py"]
