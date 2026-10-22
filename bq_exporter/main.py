"""
Exports one BigQuery table to a file in GCS (BigQuery extract job).

Runs as the bq-exporter Cloud Run Job (terraform/bq_exporter.tf), typically as
the Airflow task right after `dbt run -s <model>` builds the table.

All parameters come in ONE JSON object, either as the single container arg or
in the EXPORT_CONFIG env var (the arg wins):

    {
      "table_name": "project.dataset.table",          required
      "file_location": "gs://bucket/path/file.csv",   required; * in the name for tables > 1 GB
      "file_format": "CSV",                           CSV, JSON, AVRO, PARQUET
      "delimiter": ",",                               CSV only; "\\t" or "tab" for tab
      "print_header": true,                           CSV only
      "compression": "NONE",                          NONE, GZIP, DEFLATE, SNAPPY
      "impersonate_service_account": null,
      "project": <GCP_PROJECT_ID env>,                project that runs the extract job
      "location": <BQ_LOCATION env>                   BigQuery location of the table
    }

To add an option: add it to DEFAULTS below, then use config["<key>"].
Unknown keys are rejected, so typos fail loudly instead of being ignored.

Local run (uses `gcloud auth application-default login` credentials):

    python bq_exporter/main.py '{"table_name": "p.d.customers", "file_location": "gs://b/customers.csv"}'
"""

from __future__ import annotations

import json
import logging
import os
import sys
from typing import Any

import google.auth
from google.auth import impersonated_credentials
from google.cloud import bigquery

SCOPES = ["https://www.googleapis.com/auth/cloud-platform"]

DEFAULTS: dict[str, Any] = {
    "table_name": None,
    "file_location": None,
    "file_format": "CSV",
    "delimiter": ",",
    "print_header": True,
    "compression": "NONE",
    "impersonate_service_account": None,
    "project": os.environ.get("GCP_PROJECT_ID"),
    "location": os.environ.get("BQ_LOCATION"),
}

FORMATS = {
    "CSV": bigquery.DestinationFormat.CSV,
    "JSON": bigquery.DestinationFormat.NEWLINE_DELIMITED_JSON,
    "NEWLINE_DELIMITED_JSON": bigquery.DestinationFormat.NEWLINE_DELIMITED_JSON,
    "AVRO": bigquery.DestinationFormat.AVRO,
    "PARQUET": bigquery.DestinationFormat.PARQUET,
}
COMPRESSIONS = ["NONE", "GZIP", "DEFLATE", "SNAPPY"]

log = logging.getLogger("bq_exporter")


class ConfigError(ValueError):
    pass


def to_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    v = str(value).strip().lower()
    if v in ("true", "t", "yes", "y", "1"):
        return True
    if v in ("false", "f", "no", "n", "0"):
        return False
    raise ConfigError(f"print_header: expected true/false, got {value!r}")


def load_config(argv: list[str]) -> dict[str, Any]:
    raw = argv[0] if argv else os.environ.get("EXPORT_CONFIG")
    if not raw:
        raise ConfigError("Pass the config JSON as the container arg or in the EXPORT_CONFIG env var.")
    try:
        overrides = json.loads(raw)
    except json.JSONDecodeError as e:
        raise ConfigError(f"Config is not valid JSON ({e}): {raw!r}") from e
    if not isinstance(overrides, dict):
        raise ConfigError("Config must be a JSON object.")

    unknown = sorted(set(overrides) - set(DEFAULTS))
    if unknown:
        raise ConfigError(f"Unknown config keys {unknown}; allowed: {sorted(DEFAULTS)}")

    config = {**DEFAULTS, **{k: v for k, v in overrides.items() if v is not None}}

    if not config["table_name"]:
        raise ConfigError("table_name is required.")
    if not str(config["file_location"] or "").startswith("gs://"):
        raise ConfigError(f"file_location must be a gs:// URI, got {config['file_location']!r}")

    config["file_format"] = str(config["file_format"]).upper()
    if config["file_format"] not in FORMATS:
        raise ConfigError(f"file_format must be one of {sorted(FORMATS)}")
    config["compression"] = str(config["compression"]).upper()
    if config["compression"] not in COMPRESSIONS:
        raise ConfigError(f"compression must be one of {COMPRESSIONS}")
    config["print_header"] = to_bool(config["print_header"])
    if config["delimiter"] in ("\\t", "tab"):
        config["delimiter"] = "\t"
    return config


def build_client(config: dict[str, Any]) -> bigquery.Client:
    credentials, default_project = google.auth.default(scopes=SCOPES)
    if config["impersonate_service_account"]:
        log.info("Impersonating %s", config["impersonate_service_account"])
        credentials = impersonated_credentials.Credentials(
            source_credentials=credentials,
            target_principal=config["impersonate_service_account"],
            target_scopes=SCOPES,
        )
    return bigquery.Client(
        project=config["project"] or default_project, credentials=credentials, location=config["location"]
    )


def main(argv: list[str]) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    try:
        config = load_config(argv)
    except ConfigError as e:
        log.error("%s", e)
        return 2
    log.info("Config: %s", json.dumps(config))

    job_config = bigquery.ExtractJobConfig(destination_format=FORMATS[config["file_format"]])
    if config["compression"] != "NONE":
        job_config.compression = config["compression"]
    if job_config.destination_format == bigquery.DestinationFormat.CSV:
        job_config.field_delimiter = config["delimiter"]
        job_config.print_header = config["print_header"]

    client = build_client(config)
    job = client.extract_table(config["table_name"], config["file_location"], job_config=job_config)
    job.result()  # Raises on failure, so the Cloud Run task (and the Airflow task) fails.

    files = job.destination_uri_file_counts
    log.info("Done: job %s wrote %s file(s)", job.job_id, files[0] if files else "?")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
