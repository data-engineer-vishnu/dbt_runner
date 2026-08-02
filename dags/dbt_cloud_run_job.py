"""
Runs the dbt-runner Cloud Run Job (built from this repo's Dockerfile,
provisioned by terraform/) with a caller-supplied dbt command.

Deploy: copy this file into your Composer/Airflow environment's dags/ folder,
e.g. `gsutil cp dags/dbt_cloud_run_job.py gs://<composer-bucket>/dags/`.

Requires apache-airflow-providers-google (CloudRunExecuteJobOperator) and the
environment's service account to have roles/run.invoker on the Cloud Run Job
(already granted via terraform's `composer_service_account` var).

Trigger with config, e.g.:
    {
        "dbt_command": "run",
        "select": "tag:daily",
        "exclude": "",
        "full_refresh": false,
        "execution_date": "",
        "extra_args": ""
    }
Or trigger with no config at all to run the default `build` for today's date.

Supports any dbt subcommand the entrypoint understands: run, build, test,
compile, deps, seed, snapshot, list, debug, docs generate, docs serve,
source freshness, etc. ("docs generate" / "source freshness" are two words —
pass them as-is in dbt_command, e.g. "docs generate".)
"""

from __future__ import annotations

import shlex
from datetime import datetime

from airflow.decorators import task
from airflow.models import Variable
from airflow.models.dag import DAG
from airflow.models.param import Param
from airflow.providers.google.cloud.operators.cloud_run import CloudRunExecuteJobOperator

# Matches the values in terraform/terraform.tfvars / terraform outputs.
# Override via Airflow Variables if you deploy the job under different
# names/regions/projects without touching this file.
PROJECT_ID = Variable.get("dbt_runner_gcp_project_id", default_var="project-f1a437dd-d0f2-4e89-be8")
REGION = Variable.get("dbt_runner_region", default_var="asia-southeast1")
JOB_NAME = Variable.get("dbt_runner_job_name", default_var="dbt-runner")
JOB_TIMEOUT_SECONDS = int(Variable.get("dbt_runner_job_timeout_seconds", default_var="3600"))

# Commands that don't take model/tag selection or --vars (dbt would reject
# --select/--vars on these). Anything not in this set is treated as a
# selectable, var-aware run.
NON_SELECTABLE_COMMANDS = {"deps", "debug", "docs serve", "clean"}


@task(task_id="build_overrides")
def build_overrides(params: dict, ds: str) -> dict:
    """Assemble the Cloud Run Job container/args override from DAG params."""
    dbt_command: str = params["dbt_command"].strip()
    args = shlex.split(dbt_command)  # handles "docs generate" -> ["docs", "generate"]

    if dbt_command not in NON_SELECTABLE_COMMANDS:
        if params.get("select"):
            args += ["--select", params["select"]]
        if params.get("exclude"):
            args += ["--exclude", params["exclude"]]
        if params.get("full_refresh"):
            args.append("--full-refresh")

        execution_date = params.get("execution_date") or ds
        args += ["--vars", f"{{execution_date: {execution_date}}}"]

    if params.get("extra_args"):
        args += shlex.split(params["extra_args"])

    return {
        "container_overrides": [{"args": args}],
        "task_count": 1,
        "timeout": f"{JOB_TIMEOUT_SECONDS}s",
    }


with DAG(
    dag_id="dbt_cloud_run_job",
    description="Run dbt commands against BigQuery via the dbt-runner Cloud Run Job.",
    schedule=None,  # trigger manually, from another DAG, or set a cron string
    start_date=datetime(2026, 1, 1),
    catchup=False,
    tags=["dbt", "cloud-run", "bigquery"],
    params={
        "dbt_command": Param(
            "build",
            type="string",
            title="dbt command",
            description="e.g. run, build, test, compile, deps, seed, snapshot, "
            "list, debug, 'docs generate', 'source freshness'.",
        ),
        "select": Param("", type="string", description="--select value, e.g. tag:daily or my_model"),
        "exclude": Param("", type="string", description="--exclude value"),
        "full_refresh": Param(False, type="boolean", description="Add --full-refresh"),
        "execution_date": Param(
            "", type="string", description="Overrides the execution_date var; defaults to the DAG run's ds."
        ),
        "extra_args": Param("", type="string", description="Any additional raw CLI args, space-separated"),
    },
) as dag:
    overrides = build_overrides()

    run_dbt = CloudRunExecuteJobOperator(
        task_id="run_dbt_cloud_run_job",
        project_id=PROJECT_ID,
        region=REGION,
        job_name=JOB_NAME,
        overrides=overrides,
        gcp_conn_id="google_cloud_default",
        deferrable=False,
        # verbose=True pulls the container's dbt log output into the Airflow task
        # log, but requires roles/logging.viewer on the project for the Composer
        # environment's own service account (not the job's dbt-runner SA).
        # Grant that, then flip this on if you want dbt output inline in Airflow.
        verbose=False,
    )

    overrides >> run_dbt
