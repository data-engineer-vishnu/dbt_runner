"""
Unzips .zip files that live in GCS and writes their contents to another GCS
location. One mapped task runs per input file, so files are processed (and
retried) independently.

The job list is read from unzip_jobs.example.json, stored next to this DAG
file (Terraform uploads it with the DAG). The DAG takes no trigger parameters:
edit the JSON, deploy it, and trigger the DAG.

unzip_jobs.example.json is a list of jobs:
    [
      {"input_location": "gs://raw-bucket/drops/a.zip", "output_location": "gs://curated-bucket/a/"},
      {"input_location": "gs://raw-bucket/drops/b.zip", "output_location": "gs://curated-bucket/b/"}
    ]

Each job:
    input_location   (required) gs://bucket/path/file.zip
    output_location  (required) gs://bucket/prefix/  - members are written under this prefix
                     (the gs:// prefix is optional for both locations)
    flatten          (optional, default false) drop the zip's internal folders
    overwrite        (optional, default true)  false = skip members that already exist

The archive is streamed with ranged GCS reads and each member is streamed
straight to GCS, so files larger than the worker's memory/disk are fine.

Permissions: the Composer environment SA (composer-airflow) needs read on the
input buckets and write on the output buckets; set `composer_data_buckets` in
terraform/terraform.tfvars.
"""

from __future__ import annotations

import json
import logging
import mimetypes
import os
import posixpath
import shutil
import zipfile
from datetime import datetime, timedelta

from airflow.decorators import dag, task
from airflow.exceptions import AirflowFailException
from airflow.providers.google.cloud.hooks.gcs import GCSHook

log = logging.getLogger(__name__)

GCP_CONN_ID = "google_cloud_default"
READ_CHUNK = 16 * 1024 * 1024  # ranged-read size for the zip
WRITE_CHUNK = 16 * 1024 * 1024  # resumable-upload chunk size (multiple of 256 KiB)
MAX_LISTED_OUTPUTS = 50  # keep XCom small
DAG_DIR = os.path.dirname(os.path.abspath(__file__))
JOBS_FILE = "unzip_jobs.example.json"


def _split_gcs(uri: str) -> tuple[str, str]:
    """Split gs://bucket/name (or bucket/name) into (bucket, name)."""
    if not isinstance(uri, str) or not uri.strip():
        raise AirflowFailException(f"Expected a GCS path, got: {uri!r}")
    uri = uri.strip()
    if uri.startswith("gs://"):
        uri = uri[len("gs://"):]
    elif "://" in uri:
        raise AirflowFailException(f"Expected a gs:// path, got: {uri!r}")
    bucket, _, name = uri.partition("/")
    if not bucket:
        raise AirflowFailException(f"Missing bucket in: {uri!r}")
    return bucket, name


def _normalise_jobs(raw) -> list[dict]:
    """Accept a list, {"files": [...]}, or a dict of jobs keyed by any name."""
    if isinstance(raw, dict):
        raw = raw.get("files", list(raw.values()))
    if not isinstance(raw, list) or not raw:
        raise AirflowFailException("No jobs found: expected a non-empty list of {input_location, output_location}.")

    jobs = []
    for i, item in enumerate(raw):
        if not isinstance(item, dict):
            raise AirflowFailException(f"Job #{i} is not an object: {item!r}")
        missing = [k for k in ("input_location", "output_location") if not item.get(k)]
        if missing:
            raise AirflowFailException(f"Job #{i} is missing {missing}: {item!r}")

        in_bucket, in_name = _split_gcs(item["input_location"].strip())
        out_bucket, out_prefix = _split_gcs(item["output_location"].strip())
        if not in_name or in_name.endswith("/"):
            raise AirflowFailException(f"Job #{i}: input_location must be a file, got {item['input_location']!r}")
        if out_prefix and not out_prefix.endswith("/"):
            out_prefix += "/"

        jobs.append(
            {
                "input_location": f"gs://{in_bucket}/{in_name}",
                "output_location": f"gs://{out_bucket}/{out_prefix}",
                "flatten": bool(item.get("flatten", False)),
                "overwrite": bool(item.get("overwrite", True)),
            }
        )
    return jobs


def _load_local_jobs_file(file_name: str):
    """Read a JSON job file that lives in this DAG's folder."""
    path = os.path.realpath(os.path.join(DAG_DIR, file_name))
    if os.path.dirname(path) != os.path.realpath(DAG_DIR):
        raise AirflowFailException(f"Job file must be in the DAG folder, got {file_name!r}")
    if not os.path.isfile(path):
        raise AirflowFailException(f"Job file not found next to the DAG: {path}")
    with open(path, encoding="utf-8") as fh:
        try:
            return json.load(fh)
        except json.JSONDecodeError as exc:
            raise AirflowFailException(f"{file_name} is not valid JSON: {exc}") from exc


def _safe_member_path(name: str, flatten: bool) -> str | None:
    """Return the relative output path for a zip member, or None to skip it."""
    if name.endswith("/") or name.startswith("__MACOSX/") or posixpath.basename(name) == ".DS_Store":
        return None
    path = posixpath.normpath(name.replace("\\", "/")).lstrip("/")
    if path in ("", ".") or path == ".." or path.startswith("../"):
        raise AirflowFailException(f"Refusing unsafe path inside archive: {name!r}")
    return posixpath.basename(path) if flatten else path


@dag(
    dag_id="gcs_unzip_files",
    description="Unzip .zip files in GCS into target GCS locations.",
    schedule=None,
    start_date=datetime(2026, 1, 1),
    catchup=False,
    max_active_runs=3,
    tags=["gcs", "unzip", "utility"],
    default_args={"retries": 2, "retry_delay": timedelta(minutes=2)},
)
def gcs_unzip_files():
    @task
    def resolve_jobs() -> list[dict]:
        log.info("Reading jobs from %s in %s", JOBS_FILE, DAG_DIR)
        jobs = _normalise_jobs(_load_local_jobs_file(JOBS_FILE))
        log.info("Resolved %d unzip job(s)", len(jobs))
        return jobs

    @task(max_active_tis_per_dagrun=4)
    def unzip_one(job: dict) -> dict:
        client = GCSHook(gcp_conn_id=GCP_CONN_ID).get_conn()
        in_bucket, in_name = _split_gcs(job["input_location"])
        out_bucket_name, out_prefix = _split_gcs(job["output_location"])

        src = client.bucket(in_bucket).blob(in_name)
        if not src.exists():
            raise AirflowFailException(f"Input not found: {job['input_location']}")
        out_bucket = client.bucket(out_bucket_name)

        written, skipped, total_bytes, seen = [], 0, 0, set()
        with src.open("rb", chunk_size=READ_CHUNK) as fh:
            try:
                archive = zipfile.ZipFile(fh)
            except zipfile.BadZipFile as exc:
                raise AirflowFailException(f"Not a valid zip file: {job['input_location']}") from exc

            with archive:
                for info in archive.infolist():
                    rel = _safe_member_path(info.filename, job["flatten"])
                    if rel is None:
                        continue
                    if rel in seen:
                        raise AirflowFailException(
                            f"Two archive members map to {rel!r} (flatten=true?) in {job['input_location']}"
                        )
                    seen.add(rel)

                    dest = out_bucket.blob(out_prefix + rel)
                    if not job["overwrite"] and dest.exists():
                        skipped += 1
                        continue

                    content_type = mimetypes.guess_type(rel)[0] or "application/octet-stream"
                    with archive.open(info) as member, dest.open(
                        "wb", chunk_size=WRITE_CHUNK, content_type=content_type, ignore_flush=True
                    ) as out:
                        shutil.copyfileobj(member, out, length=WRITE_CHUNK)

                    total_bytes += info.file_size
                    written.append(f"gs://{out_bucket_name}/{out_prefix}{rel}")
                    log.info("Wrote %s (%d bytes)", written[-1], info.file_size)

        log.info(
            "%s -> %s: %d file(s), %d bytes, %d skipped",
            job["input_location"], job["output_location"], len(written), total_bytes, skipped,
        )
        return {
            **job,
            "files_written": len(written),
            "bytes_written": total_bytes,
            "files_skipped": skipped,
            "outputs": written[:MAX_LISTED_OUTPUTS],
        }

    @task
    def summarize(results: list[dict]) -> dict:
        results = list(results)
        summary = {
            "jobs": len(results),
            "files_written": sum(r["files_written"] for r in results),
            "bytes_written": sum(r["bytes_written"] for r in results),
            "files_skipped": sum(r["files_skipped"] for r in results),
        }
        for r in results:
            log.info("%s -> %s: %d files", r["input_location"], r["output_location"], r["files_written"])
        log.info("Summary: %s", summary)
        return summary

    summarize(unzip_one.expand(job=resolve_jobs()))


gcs_unzip_files()
