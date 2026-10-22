# Cloud Composer 3 (managed Airflow 2) environment for the DAGs in ../dags.
#
# Sized at the smallest values Composer 3 accepts (see var.composer_* below).
# Composer has no scale-to-zero: the environment bills continuously while it
# exists. Set create_composer = false and apply to tear it down.
#
# Identity: a dedicated service account (composer-airflow) runs Airflow. It is
# the identity behind the DAGs' `google_cloud_default` connection, so it is the
# principal that executes the dbt-runner Cloud Run Job.

locals {
  composer_enabled = var.create_composer

  composer_bucket_name = var.composer_bucket_name != "" ? var.composer_bucket_name : "${var.project_id}-${var.composer_environment_name}"

  composer_sa_email = local.composer_enabled ? google_service_account.composer[0].email : ""

  # Project-level roles for the Airflow service account.
  composer_sa_project_roles = local.composer_enabled ? toset([
    "roles/composer.worker",               # required for every Composer environment SA
    "roles/run.jobsExecutorWithOverrides", # run the dbt-runner job with args/env overrides
    "roles/run.viewer",                    # poll executions/operations while waiting for the job
    "roles/logging.viewer",                # CloudRunExecuteJobOperator(verbose=True) log streaming
  ]) : toset([])

  # Everything under ../dags (including subfolders such as dags/file_unzip_dag/)
  # is shipped to the environment's dags/ folder with the same relative path.
  composer_dag_files = local.composer_enabled && var.composer_upload_dags ? {
    for f in fileset("${path.module}/../dags", "**/*.{py,json}") : f => "${path.module}/../dags/${f}"
  } : {}
}

data "google_project" "this" {
  project_id = var.project_id
}

resource "google_project_service" "composer" {
  for_each = local.composer_enabled ? toset(["composer.googleapis.com", "storage.googleapis.com"]) : toset([])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# Makes sure the Cloud Composer service agent exists before it's granted roles.
resource "google_project_service_identity" "composer_agent" {
  provider = google-beta
  count    = local.composer_enabled ? 1 : 0

  project = var.project_id
  service = "composer.googleapis.com"

  depends_on = [google_project_service.composer]
}

# Required when an environment runs as a user-managed service account: lets
# the Composer service agent act as / manage that SA.
resource "google_project_iam_member" "composer_agent_v2ext" {
  count = local.composer_enabled ? 1 : 0

  project = var.project_id
  role    = "roles/composer.ServiceAgentV2Ext"
  member  = "serviceAccount:service-${data.google_project.this.number}@cloudcomposer-accounts.iam.gserviceaccount.com"

  depends_on = [google_project_service_identity.composer_agent]
}

# ---------------------------------------------------------------------------
# Airflow runtime service account + IAM
# ---------------------------------------------------------------------------
resource "google_service_account" "composer" {
  count = local.composer_enabled ? 1 : 0

  project      = var.project_id
  account_id   = var.composer_service_account_id
  display_name = "Cloud Composer (Airflow) runtime service account"

  depends_on = [google_project_service.composer]
}

resource "google_project_iam_member" "composer_sa" {
  for_each = local.composer_sa_project_roles

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${local.composer_sa_email}"
}

# No actAs on the dbt-runner SA is needed: execution overrides can change
# args/env/timeout but not the job's service account.

# ---------------------------------------------------------------------------
# Environment bucket (DAGs, plugins, data, logs). Using our own bucket keeps
# IAM explicit and lets Terraform upload the DAGs.
# ---------------------------------------------------------------------------
resource "google_storage_bucket" "composer" {
  count = local.composer_enabled ? 1 : 0

  project                     = var.project_id
  name                        = local.composer_bucket_name
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = var.composer_bucket_force_destroy
  labels                      = var.labels

  depends_on = [google_project_service.composer]
}

resource "google_storage_bucket_iam_member" "composer_bucket" {
  for_each = local.composer_enabled ? {
    environment_sa = "serviceAccount:${local.composer_sa_email}"
    service_agent  = "serviceAccount:service-${data.google_project.this.number}@cloudcomposer-accounts.iam.gserviceaccount.com"
  } : {}

  bucket = google_storage_bucket.composer[0].name
  role   = "roles/storage.objectAdmin"
  member = each.value

  depends_on = [google_project_service_identity.composer_agent]
}

# Humans who open the Airflow UI / manage DAGs.
resource "google_project_iam_member" "composer_users" {
  for_each = local.composer_enabled ? toset(var.composer_users) : toset([])

  project = var.project_id
  role    = "roles/composer.user"
  member  = each.value
}

resource "google_storage_bucket_iam_member" "composer_users_dags" {
  for_each = local.composer_enabled ? toset(var.composer_users) : toset([])

  bucket = google_storage_bucket.composer[0].name
  role   = "roles/storage.objectAdmin"
  member = each.value
}

# ---------------------------------------------------------------------------
# The environment
# ---------------------------------------------------------------------------
# COMMENTED OUT to tear down the environment (stops billing). Bucket, SA and
# IAM above are kept. Uncomment this block and apply to recreate it.
# resource "google_composer_environment" "airflow" {
#   count = local.composer_enabled ? 1 : 0
#
#   project = var.project_id
#   name    = var.composer_environment_name
#   region  = var.region
#   labels  = var.labels
#
#   storage_config {
#     bucket = google_storage_bucket.composer[0].name
#   }
#
#   config {
#     environment_size = "ENVIRONMENT_SIZE_SMALL"
#     resilience_mode  = "STANDARD_RESILIENCE"
#
#     software_config {
#       image_version = var.composer_image_version
#
#       # Airflow reads AIRFLOW_VAR_<NAME> as Variable "<name>"; these are the
#       # Variable.get() keys used by dags/*.py.
#       env_variables = {
#         AIRFLOW_VAR_DBT_RUNNER_GCP_PROJECT_ID = var.project_id
#         AIRFLOW_VAR_DBT_RUNNER_REGION         = var.region
#         AIRFLOW_VAR_DBT_RUNNER_JOB_NAME       = var.job_name
#       }
#     }
#
#     node_config {
#       service_account = local.composer_sa_email
#     }
#
#     workloads_config {
#       scheduler {
#         cpu        = var.composer_scheduler.cpu
#         memory_gb  = var.composer_scheduler.memory_gb
#         storage_gb = var.composer_scheduler.storage_gb
#         count      = 1
#       }
#       dag_processor {
#         cpu        = var.composer_dag_processor.cpu
#         memory_gb  = var.composer_dag_processor.memory_gb
#         storage_gb = var.composer_dag_processor.storage_gb
#         count      = 1
#       }
#       triggerer {
#         # DAGs use deferrable=False, so no triggerer is needed.
#         cpu       = 0.5
#         memory_gb = 1
#         count     = 0
#       }
#       web_server {
#         cpu        = var.composer_web_server.cpu
#         memory_gb  = var.composer_web_server.memory_gb
#         storage_gb = var.composer_web_server.storage_gb
#       }
#       worker {
#         cpu        = var.composer_worker.cpu
#         memory_gb  = var.composer_worker.memory_gb
#         storage_gb = var.composer_worker.storage_gb
#         min_count  = var.composer_worker.min_count
#         max_count  = var.composer_worker.max_count
#       }
#     }
#   }
#
#   depends_on = [
#     google_project_iam_member.composer_agent_v2ext,
#     google_project_iam_member.composer_sa,
#     google_storage_bucket_iam_member.composer_bucket,
#   ]
#
#   lifecycle {
#     # An alias like "composer-3-airflow-2" resolves to a concrete build after
#     # create; upgrade deliberately (gcloud / console) rather than on every plan.
#     ignore_changes = [config[0].software_config[0].image_version]
#   }
# }

# Ship ../dags (DAGs + JSON job files, subfolders included) to the environment's
# dags/ folder. Airflow scans dags/ recursively.
resource "google_storage_bucket_object" "dags" {
  for_each = local.composer_dag_files

  bucket = google_storage_bucket.composer[0].name
  name   = "dags/${each.key}"
  source = each.value
}

# Data buckets the DAGs read from / write to (e.g. gcs_unzip_files input and
# output buckets). objectAdmin = read, create and overwrite objects.
resource "google_storage_bucket_iam_member" "composer_data_buckets" {
  for_each = local.composer_enabled ? toset(var.composer_data_buckets) : toset([])

  bucket = each.value
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${local.composer_sa_email}"
}
