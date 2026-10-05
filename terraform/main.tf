locals {
  required_services = [
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "bigquery.googleapis.com",
    "iam.googleapis.com",
    "datacatalog.googleapis.com",
    "bigquerydatapolicy.googleapis.com",
  ]
}

resource "google_project_service" "required" {
  for_each = toset(local.required_services)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# Runtime identity for the Cloud Run Job. Cloud Run injects Application
# Default Credentials for this service account; the BigQuery profile
# (profiles/profiles.yml, method: oauth) relies on that.
resource "google_service_account" "dbt_runner" {
  project      = var.project_id
  account_id   = var.service_account_id
  display_name = "dbt Cloud Run Job runtime service account"

  depends_on = [google_project_service.required]
}

resource "google_project_iam_member" "dbt_runner_bq_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.dbt_runner.email}"
}

resource "google_bigquery_dataset_iam_member" "dbt_runner_target_dataset_editor" {
  project    = var.project_id
  dataset_id = var.bigquery_dataset
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.dbt_runner.email}"
}

# Optional: read-only access to additional source datasets referenced by models.
resource "google_bigquery_dataset_iam_member" "dbt_runner_source_dataset_viewer" {
  for_each = toset(var.source_dataset_ids)

  project    = var.project_id
  dataset_id = each.value
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.dbt_runner.email}"
}

# Holds the dbt-runner image built from this repo's Dockerfile.
resource "google_artifact_registry_repository" "dbt_images" {
  count = var.create_artifact_registry ? 1 : 0

  project       = var.project_id
  location      = var.region
  repository_id = var.repository_id
  format        = "DOCKER"
  description   = "dbt-runner images for Cloud Run Jobs"

  depends_on = [google_project_service.required]
}

# ---------------------------------------------------------------------------
# Cloud Run Job + Composer invoker bindings: commented out.
# Re-enable together with the job_name/job_id outputs in outputs.tf, and set
# composer_service_account in terraform.tfvars for the two IAM bindings.
# ---------------------------------------------------------------------------
# resource "google_cloud_run_v2_job" "dbt_runner" {
#   project             = var.project_id
#   name                = var.job_name
#   location            = var.region
#   labels              = var.labels
#   deletion_protection = var.deletion_protection

#   template {
#     template {
#       service_account = google_service_account.dbt_runner.email
#       timeout         = var.task_timeout
#       max_retries     = var.max_retries

#       containers {
#         image = var.image
#         args  = var.default_args

#         resources {
#           limits = {
#             cpu    = var.cpu
#             memory = var.memory
#           }
#         }

#         env {
#           name  = "GCP_PROJECT_ID"
#           value = var.project_id
#         }
#         env {
#           name  = "DBT_BIGQUERY_DATASET"
#           value = var.bigquery_dataset
#         }
#         env {
#           name  = "DBT_BIGQUERY_LOCATION"
#           value = var.bigquery_location
#         }
#         env {
#           name  = "DBT_THREADS"
#           value = tostring(var.dbt_threads)
#         }
#         env {
#           name  = "DBT_TARGET"
#           value = var.dbt_target
#         }
#       }
#     }
#   }

#   depends_on = [
#     google_project_service.required,
#     google_project_iam_member.dbt_runner_bq_job_user,
#     google_bigquery_dataset_iam_member.dbt_runner_target_dataset_editor,
#   ]

#   lifecycle {
#     ignore_changes = [
#       # Airflow/CI push new tags and trigger executions with args/env
#       # overrides; don't fight those out-of-band updates on every apply.
#       template[0].template[0].containers[0].image,
#       template[0].template[0].containers[0].args,
#     ]
#   }
# }

# # Lets the Composer/Airflow environment's service account execute this job
# # (required by e.g. CloudRunExecuteJobOperator).
# resource "google_cloud_run_v2_job_iam_member" "composer_invoker" {
#   count = var.composer_service_account != "" ? 1 : 0

#   project  = var.project_id
#   location = var.region
#   name     = google_cloud_run_v2_job.dbt_runner.name
#   role     = "roles/run.invoker"
#   member   = "serviceAccount:${var.composer_service_account}"
# }

# # run.invoker only grants run.jobs.run (start the execution). The Airflow
# # operator then polls the long-running operation/execution status, which
# # needs run.operations.get + run.executions.get — granted by run.viewer.
# # Without this, CloudRunExecuteJobOperator successfully starts the job but
# # fails with PERMISSION_DENIED on run.operations.get while waiting for it.
# resource "google_cloud_run_v2_job_iam_member" "composer_viewer" {
#   count = var.composer_service_account != "" ? 1 : 0

#   project  = var.project_id
#   location = var.region
#   name     = google_cloud_run_v2_job.dbt_runner.name
#   role     = "roles/run.viewer"
#   member   = "serviceAccount:${var.composer_service_account}"
# }
