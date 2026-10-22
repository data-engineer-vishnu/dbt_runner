# BigQuery -> GCS file export job, built from bq_exporter/ (its own image,
# separate from the dbt-runner image). One execution exports one table; the
# YAML-driven Airflow DAG passes the table/destination as arg overrides.
#
# The job is created with Google's public placeholder image so the first apply
# doesn't need a build. bq_exporter/deploy.ps1 builds the real image and points
# the job at it; Terraform ignores the image afterwards so apply won't revert it.
#
# Airflow can already run it: composer.tf grants the Airflow SA
# run.jobsExecutorWithOverrides + run.viewer at project level.

locals {
  bq_exporter_placeholder_image = "us-docker.pkg.dev/cloudrun/container/job:latest"

  bq_exporter_output_buckets = toset(concat(
    var.bq_exporter_output_buckets,
    var.create_data_bucket ? [local.data_bucket_name] : [],
  ))
}

resource "google_project_service" "cloudbuild" {
  project            = var.project_id
  service            = "cloudbuild.googleapis.com"
  disable_on_destroy = false
}

# `gcloud builds submit` runs builds as the default compute SA, which has no
# roles in newer projects (fails with storage.objects.get denied on the
# <project>_cloudbuild bucket). builds.builder lets it read the uploaded
# source, push to Artifact Registry and write build logs.
resource "google_project_iam_member" "cloudbuild_compute_sa_builder" {
  project = var.project_id
  role    = "roles/cloudbuild.builds.builder"
  member  = "serviceAccount:${data.google_project.this.number}-compute@developer.gserviceaccount.com"

  depends_on = [google_project_service.cloudbuild]
}

resource "google_service_account" "bq_exporter" {
  project      = var.project_id
  account_id   = var.bq_exporter_service_account_id
  display_name = "bq-exporter Cloud Run Job runtime service account"

  depends_on = [google_project_service.required]
}

resource "google_project_iam_member" "bq_exporter_bq_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.bq_exporter.email}"
}

resource "google_bigquery_dataset_iam_member" "bq_exporter_source_viewer" {
  for_each = toset(var.bq_exporter_source_datasets)

  project    = var.project_id
  dataset_id = each.value
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.bq_exporter.email}"
}

# objectUser (not objectCreator) so re-runs can overwrite an existing file.
resource "google_storage_bucket_iam_member" "bq_exporter_output" {
  for_each = local.bq_exporter_output_buckets

  bucket = each.value
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.bq_exporter.email}"

  depends_on = [google_storage_bucket.data]
}

# Lets the job impersonate the service accounts named in the DAG YAML
# (--impersonate-service-account).
resource "google_service_account_iam_member" "bq_exporter_impersonate" {
  for_each = toset(var.bq_exporter_impersonate_service_accounts)

  service_account_id = "projects/-/serviceAccounts/${each.value}"
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.bq_exporter.email}"
}

resource "google_cloud_run_v2_job" "bq_exporter" {
  project             = var.project_id
  name                = var.bq_exporter_job_name
  location            = var.region
  labels              = var.labels
  deletion_protection = var.deletion_protection

  template {
    template {
      service_account = google_service_account.bq_exporter.email
      timeout         = var.bq_exporter_task_timeout
      max_retries     = var.bq_exporter_max_retries

      containers {
        image = local.bq_exporter_placeholder_image

        resources {
          limits = {
            cpu    = var.bq_exporter_cpu
            memory = var.bq_exporter_memory
          }
        }

        env {
          name  = "GCP_PROJECT_ID"
          value = var.project_id
        }
        env {
          name  = "BQ_LOCATION"
          value = var.bigquery_location
        }
      }
    }
  }

  depends_on = [
    google_project_service.required,
    google_project_iam_member.bq_exporter_bq_job_user,
  ]

  lifecycle {
    ignore_changes = [
      # deploy.ps1 owns the image; Airflow supplies args per execution.
      template[0].template[0].containers[0].image,
      template[0].template[0].containers[0].args,
      client,
      client_version,
    ]
  }
}
