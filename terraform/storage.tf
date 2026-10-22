# General-purpose data bucket (e.g. zip drops and unzipped output for the
# gcs_unzip_files DAG).
#
# roles/storage.admin on the bucket = full control of the bucket and its
# objects: read/write/delete objects, change bucket settings and bucket IAM.
# Granted to the principals in var.data_bucket_admins and to the Airflow SA.

locals {
  data_bucket_name = var.data_bucket_name != "" ? var.data_bucket_name : "${var.project_id}-data"

  data_bucket_admins = toset(concat(
    var.data_bucket_admins,
    # Built from inputs (not the resource attribute) so for_each keys are known at plan time.
    var.create_composer ? ["serviceAccount:${var.composer_service_account_id}@${var.project_id}.iam.gserviceaccount.com"] : [],
  ))
}

resource "google_storage_bucket" "data" {
  count = var.create_data_bucket ? 1 : 0

  project                     = var.project_id
  name                        = local.data_bucket_name
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = var.data_bucket_force_destroy
  labels                      = var.labels

  versioning {
    enabled = var.data_bucket_versioning
  }

  # Clean up noncurrent versions so versioning doesn't grow storage forever.
  dynamic "lifecycle_rule" {
    for_each = var.data_bucket_versioning ? [1] : []
    content {
      condition {
        days_since_noncurrent_time = 30
      }
      action {
        type = "Delete"
      }
    }
  }

  depends_on = [google_project_service.required, google_project_service.composer]
}

resource "google_storage_bucket_iam_member" "data_bucket_admins" {
  for_each = var.create_data_bucket ? local.data_bucket_admins : toset([])

  bucket = google_storage_bucket.data[0].name
  role   = "roles/storage.admin"
  member = each.value

  depends_on = [google_service_account.composer]
}
