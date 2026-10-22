"""
Exports one BigQuery table to a file in GCS. One Cloud Run Job serves several
export types, chosen by the required `export_vendor` config key:

    modeA   Python-written CSV, one file per execution date (see export_mode_a)

Runs as the bq-exporter Cloud Run Job (terraform/bq_exporter.tf), typically as
the Airflow task right after `dbt run -s <model>` builds the table.

All parameters come in ONE JSON object, either as the single container arg or
in the EXPORT_CONFIG env var (the arg wins). Keys common to every mode:

    {
      "export_vendor": "modeA",                       required; picks the exporter
      "table_name": "project.dataset.table",          required
      "file_location": "gs://bucket/path/name.csv",   required; folder + base file name
      "execution_date": "2026-10-22",                 optional; YYYY-MM-DD or YYYYMMDD, default today (UTC)
      "impersonate_service_account": null,
      "project": <GCP_PROJECT_ID env>,                project that runs (and pays for) the query
      "location": <BQ_LOCATION env>                   BigQuery location of the table
    }

plus the keys of the chosen mode (MODE_A_DEFAULTS for modeA). Unknown keys
are rejected, so typos fail loudly instead of being ignored.

Adding a mode (e.g. modeB):
  1. write `def export_mode_b(config, bq, gcs) -> None`
  2. add its own keys + defaults in a MODE_B_DEFAULTS dict
  3. register it in EXPORTERS: "modeB": (MODE_B_DEFAULTS, export_mode_b)

Local run (uses `gcloud auth application-default login` credentials):

    python bq_exporter/main.py '{"export_vendor": "modeA", "table_name": "p.d.churners_quoted", "file_location": "gs://b/exports/churners.csv"}'
"""

from __future__ import annotations

import datetime as dt
import json
import logging
import os
import posixpath
import sys
from typing import Any, Callable

import google.auth
from google.auth import impersonated_credentials
from google.cloud import bigquery, storage

SCOPES = ["https://www.googleapis.com/auth/cloud-platform"]
PAGE_SIZE = 10_000

COMMON_DEFAULTS: dict[str, Any] = {
    "export_vendor": None,
    "table_name": None,
    "file_location": None,
    "execution_date": None,
    "impersonate_service_account": None,
    "project": os.environ.get("GCP_PROJECT_ID"),
    "location": os.environ.get("BQ_LOCATION"),
}

log = logging.getLogger("bq_exporter")


class ConfigError(ValueError):
    pass


# ---------------------------------------------------------------------------
# modeA: rows read with a query and written by Python (not a BigQuery extract
# job), so values are written exactly as stored: a value of "Blue" (quotes
# included, e.g. from a dbt model built with quote_string_columns) lands in
# the file as "Blue". Header names are wrapped in double quotes.
#
# For file_location gs://bucket/exports/churners.csv and execution_date
# 2026-10-22 the file is:
#
#     gs://bucket/exports/dt=2026-10-22/churners_20261022.csv
#
# Any other file already in that date folder is deleted after the new file is
# written, so re-runs for a date always leave exactly one file.
# ---------------------------------------------------------------------------
MODE_A_DEFAULTS: dict[str, Any] = {
    "delimiter": ",",                            # "\t" or "tab" for tab
    "partition_folder_format": "dt=%Y-%m-%d",    # strftime format of the date folder (Hive style)
}


def output_path(file_location: str, execution_date: dt.date, folder_format: str) -> tuple[str, str, str]:
    """gs://b/dir/name.csv -> (bucket, "dir/<date folder>/", "dir/<date folder>/name_YYYYMMDD.csv")."""
    bucket, _, path = file_location[len("gs://"):].partition("/")
    folder, filename = posixpath.split(path)
    stem, ext = posixpath.splitext(filename)
    date_folder = posixpath.join(folder, execution_date.strftime(folder_format)) + "/"
    blob_name = f"{date_folder}{stem}_{execution_date:%Y%m%d}{ext or '.csv'}"
    return bucket, date_folder, blob_name


def to_cell(value: Any) -> str:
    # Written verbatim (no CSV escaping) so quotes in the data are preserved.
    return "" if value is None else str(value)


def export_mode_a(config: dict[str, Any], bq: bigquery.Client, gcs: storage.Client) -> None:
    delimiter = "\t" if config["delimiter"] in ("\\t", "tab") else config["delimiter"]
    bucket_name, date_folder, blob_name = output_path(
        config["file_location"], config["execution_date"], config["partition_folder_format"]
    )

    table_sql = ".".join(f"`{part}`" for part in config["table_name"].split("."))
    rows = bq.query(f"select * from {table_sql}").result(page_size=PAGE_SIZE)

    log.info("Writing %s -> gs://%s/%s", config["table_name"], bucket_name, blob_name)
    count = 0
    with gcs.bucket(bucket_name).blob(blob_name).open("w", encoding="utf-8", newline="\n", content_type="text/csv") as f:
        f.write(delimiter.join(f'"{field.name}"' for field in rows.schema) + "\n")
        for row in rows:
            f.write(delimiter.join(to_cell(v) for v in row.values()) + "\n")
            count += 1

    # Only files directly in the date folder; subfolders are left alone.
    stale = [b for b in gcs.list_blobs(bucket_name, prefix=date_folder, delimiter="/") if b.name != blob_name]
    for b in stale:
        log.info("Deleting previous file gs://%s/%s", bucket_name, b.name)
        b.delete()

    log.info("Done: wrote %d rows to gs://%s/%s (removed %d old file(s))", count, bucket_name, blob_name, len(stale))


# ---------------------------------------------------------------------------
# Registry: export_vendor -> (mode-specific keys with defaults, exporter)
# ---------------------------------------------------------------------------
Exporter = Callable[[dict[str, Any], bigquery.Client, storage.Client], None]

EXPORTERS: dict[str, tuple[dict[str, Any], Exporter]] = {
    "modeA": (MODE_A_DEFAULTS, export_mode_a),
}


def parse_date(value: Any) -> dt.date:
    if value is None or value == "":
        return dt.datetime.now(dt.timezone.utc).date()
    for fmt in ("%Y-%m-%d", "%Y%m%d"):
        try:
            return dt.datetime.strptime(str(value).strip(), fmt).date()
        except ValueError:
            pass
    raise ConfigError(f"execution_date must be YYYY-MM-DD or YYYYMMDD, got {value!r}")


def load_config(argv: list[str]) -> tuple[dict[str, Any], Exporter]:
    raw = argv[0] if argv else os.environ.get("EXPORT_CONFIG")
    if not raw:
        raise ConfigError("Pass the config JSON as the container arg or in the EXPORT_CONFIG env var.")
    try:
        overrides = json.loads(raw)
    except json.JSONDecodeError as e:
        raise ConfigError(f"Config is not valid JSON ({e}): {raw!r}") from e
    if not isinstance(overrides, dict):
        raise ConfigError("Config must be a JSON object.")

    vendor = overrides.get("export_vendor")
    if not vendor:
        raise ConfigError(f"export_vendor is required; one of {sorted(EXPORTERS)}")
    # Case-insensitive lookup; the config carries the registered spelling.
    vendor = next((name for name in EXPORTERS if name.lower() == str(vendor).lower()), None)
    if vendor is None:
        raise ConfigError(f"Unknown export_vendor {overrides['export_vendor']!r}; one of {sorted(EXPORTERS)}")
    mode_defaults, exporter = EXPORTERS[vendor]

    allowed = {**COMMON_DEFAULTS, **mode_defaults}
    unknown = sorted(set(overrides) - set(allowed))
    if unknown:
        raise ConfigError(f"Unknown config keys {unknown} for export_vendor {vendor}; allowed: {sorted(allowed)}")

    config = {**allowed, **{k: v for k, v in overrides.items() if v is not None}, "export_vendor": vendor}

    if not config["table_name"]:
        raise ConfigError("table_name is required.")
    location = str(config["file_location"] or "")
    if not location.startswith("gs://") or location.endswith("/") or "/" not in location[len("gs://"):]:
        raise ConfigError(f"file_location must be gs://bucket/[folder/]name.ext, got {config['file_location']!r}")
    config["execution_date"] = parse_date(config["execution_date"])
    return config, exporter


def credentials_for(config: dict[str, Any]):
    credentials, default_project = google.auth.default(scopes=SCOPES)
    if config["impersonate_service_account"]:
        log.info("Impersonating %s", config["impersonate_service_account"])
        credentials = impersonated_credentials.Credentials(
            source_credentials=credentials,
            target_principal=config["impersonate_service_account"],
            target_scopes=SCOPES,
        )
    return credentials, config["project"] or default_project


def main(argv: list[str]) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    try:
        config, exporter = load_config(argv)
    except ConfigError as e:
        log.error("%s", e)
        return 2
    log.info("Config: %s", json.dumps(config, default=str))

    credentials, project = credentials_for(config)
    bq = bigquery.Client(project=project, credentials=credentials, location=config["location"])
    gcs = storage.Client(project=project, credentials=credentials)
    exporter(config, bq, gcs)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
