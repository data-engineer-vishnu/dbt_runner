project_id = "project-f1a437dd-d0f2-4e89-be8"
region     = "asia-southeast1"

job_name           = "dbt-runner"
service_account_id = "dbt-runner"

# Build and push the image from this repo's Dockerfile first, e.g.:
#   gcloud builds submit --tag us-central1-docker.pkg.dev/analytics-prod/dbt-images/dbt-runner:latest
image = "asia-southeast1-docker.pkg.dev/project-f1a437dd-d0f2-4e89-be8/dbt-images/dbt-runner:latest"

bigquery_dataset  = "dev_vishnu"
bigquery_location = "asia-southeast1"
# source_dataset_ids = ["raw_events", "raw_crm"]

dbt_threads = 4
dbt_target  = "cloud_run"

cpu          = "1"
memory       = "2Gi"
task_timeout = "3600s"
max_retries  = 0

# Grant the Composer/Airflow environment SA permission to trigger executions.
composer_service_account = "1087604494659-compute@developer.gserviceaccount.com"
