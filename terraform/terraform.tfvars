project_id = "project-fd305953-166e-42aa-8d5"
region     = "asia-southeast1"

job_name           = "dbt-runner"
service_account_id = "dbt-runner"

# Build and push the image from this repo's Dockerfile first, e.g.:
#   gcloud builds submit --tag asia-southeast1-docker.pkg.dev/project-fd305953-166e-42aa-8d5/dbt-images/dbt-runner:latest .
image = "asia-southeast1-docker.pkg.dev/project-fd305953-166e-42aa-8d5/dbt-images/dbt-runner:latest"

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
# Blank until a Composer environment exists in this project: the SA must
# already exist or the run.invoker/run.viewer bindings fail on apply.
# Default compute SA for this project: 367607098524-compute@developer.gserviceaccount.com
composer_service_account = ""

# --- BigQuery dynamic column masking (terraform/masking.tf) -----------------
# Grantees use IAM v2 principal identifiers:
#   user:            "principal://goog/subject/alice@example.com"
#   group:           "principalSet://goog/group/analysts@example.com"
#   service account: "principal://iam.googleapis.com/projects/-/serviceAccounts/sa@PROJECT.iam.gserviceaccount.com"
# Principals in neither list get "Access Denied" on masked columns, even with
# BigQuery dataViewer/dataOwner. The dbt runner SA is added to the raw list
# automatically (grant_dbt_runner_raw_access = true).
#
# If you run dbt locally with your own Google account, add it to
# masking_raw_grantees, otherwise downstream models (e.g. customer_copy) fail
# with "does not have masked access or raw data access".
masking_masked_grantees = [
  "principal://goog/subject/vishnu.as.automate1@gmail.com",
]
masking_raw_grantees = [
  # Moved to masking_masked_grantees to test masked reads. An account in both
  # lists sees raw values, so keep it in only one.
  # "principal://goog/subject/vishnu.as.automate1@gmail.com",
  # "principal://goog/subject/<account that runs dbt locally>",
]
