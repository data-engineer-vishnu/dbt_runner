"""
Example dbt pipeline DAG that triggers the dbt-runner Cloud Run Job (built
from this repo's Dockerfile, provisioned by terraform/) once per dbt command,
with the commands hardcoded per-task and dynamic values (execution date,
run id, etc.) injected via Jinja templating and container overrides.

Deploy: copy this file into your Composer/Airflow environment's dags/ folder,
e.g. `gsutil cp dags/dbt_cloud_run_pipeline.py gs://<composer-bucket>/dags/`.

Requires apache-airflow-providers-google (CloudRunExecuteJobOperator) and the
environment's service account to have roles/run.invoker on the Cloud Run Job
(already granted via terraform's `composer_service_account` var).

This is meant as a template: duplicate/edit the CloudRunExecuteJobOperator
tasks below to match your own dbt commands, selectors and dependency order.
"""

from __future__ import annotations

from datetime import datetime

from airflow.models import Variable
from airflow.models.dag import DAG
from airflow.providers.google.cloud.operators.cloud_run import CloudRunExecuteJobOperator

# Matches the values in terraform/terraform.tfvars / terraform outputs.
# Override via Airflow Variables if you deploy the job under different
# names/regions/projects without touching this file.
PROJECT_ID = Variable.get("dbt_runner_gcp_project_id", default_var="project-f1a437dd-d0f2-4e89-be8")
REGION = Variable.get("dbt_runner_region", default_var="asia-southeast1")
JOB_NAME = Variable.get("dbt_runner_job_name", default_var="dbt-runner")

# dbt threads to use for this pipeline's run/test/build steps. Overriding it
# here (rather than relying on the job's baked-in DBT_THREADS env var) is an
# example of passing a dynamic container env var per-execution.
DBT_THREADS = Variable.get("dbt_runner_pipeline_threads", default_var="4")

default_args = {
    "owner": "data-eng",
    "retries": 1,
}

with DAG(
    dag_id="dbt_cloud_run_pipeline",
    description="Hardcoded deps -> run -> test -> docs generate pipeline against the dbt-runner Cloud Run Job.",
    schedule="@daily",
    start_date=datetime(2026, 1, 1),
    catchup=False,
    default_args=default_args,
    tags=["dbt", "cloud-run", "bigquery"],
) as dag:

    dbt_deps = CloudRunExecuteJobOperator(
        task_id="dbt_deps",
        project_id=PROJECT_ID,
        region=REGION,
        job_name=JOB_NAME,
        overrides={
            "container_overrides": [
                {
                    "args": ["deps"],
                }
            ],
            "task_count": 1,
            "timeout": "600s",
        },
        gcp_conn_id="google_cloud_default",
    )

    dbt_run_daily = CloudRunExecuteJobOperator(
        task_id="dbt_run_daily",
        project_id=PROJECT_ID,
        region=REGION,
        job_name=JOB_NAME,
        overrides={
            "container_overrides": [
                {
                    # dbt command + selector are hardcoded; only the values
                    # inside the strings (execution_date, run id) are dynamic.
                    "args": [
                        "run",
                        "--select",
                        "tag:docker_test",
                        "--vars",
                        "{execution_date: {{ ds }}}",
                    ],
                    "env": [
                        # Example of overriding a container env var per-run
                        # instead of relying on the job's default DBT_THREADS.
                        {"name": "DBT_THREADS", "value": DBT_THREADS},
                        # Not read by dbt/profiles.yml — included purely so the
                        # Airflow run id shows up in Cloud Run's execution
                        # metadata/logs for traceability.
                        {"name": "AIRFLOW_RUN_ID", "value": "{{ run_id }}"},
                    ],
                }
            ],
            "task_count": 1,
            "timeout": "3600s",
        },
        gcp_conn_id="google_cloud_default",
    )

    dbt_test_daily = CloudRunExecuteJobOperator(
        task_id="dbt_test_daily",
        project_id=PROJECT_ID,
        region=REGION,
        job_name=JOB_NAME,
        overrides={
            "container_overrides": [
                {
                    "args": ["test", "--select", "tag:docker_test"],
                }
            ],
            "task_count": 1,
            "timeout": "1800s",
        },
        gcp_conn_id="google_cloud_default",
    )

    dbt_docs_generate = CloudRunExecuteJobOperator(
        task_id="dbt_docs_generate",
        project_id=PROJECT_ID,
        region=REGION,
        job_name=JOB_NAME,
        overrides={
            "container_overrides": [
                {
                    "args": ["docs", "generate"],
                }
            ],
            "task_count": 1,
            "timeout": "600s",
        },
        gcp_conn_id="google_cloud_default",
    )

    dbt_deps >> dbt_run_daily >> dbt_test_daily >> dbt_docs_generate
