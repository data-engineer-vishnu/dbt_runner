# Commented out with the Cloud Run Job resource in main.tf.
# output "job_name" {
#   description = "Cloud Run Job name, for use in Airflow's CloudRunExecuteJobOperator."
#   value       = google_cloud_run_v2_job.dbt_runner.name
# }

# output "job_id" {
#   description = "Fully-qualified Cloud Run Job resource ID."
#   value       = google_cloud_run_v2_job.dbt_runner.id
# }

output "region" {
  value = var.region
}

output "service_account_email" {
  description = "Runtime service account used by the Cloud Run Job."
  value       = google_service_account.dbt_runner.email
}

output "artifact_registry_repository" {
  description = "Docker push target, e.g. <region>-docker.pkg.dev/<project>/<repository_id>."
  value       = var.create_artifact_registry ? "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.dbt_images[0].repository_id}" : null
}

output "mask_data_policies" {
  description = "mask_policy name -> fully-qualified direct v2 data-policy reference (<project>.region-<location>.<policy_id>)."
  value = {
    for k, p in google_bigquery_datapolicyv2_data_policy.masking :
    k => "${local.data_policy_reference_prefix}.${p.data_policy_id}"
  }
}

output "raw_data_policy" {
  description = "Direct v2 data-policy reference for principals allowed to read original values."
  value       = var.create_masking_policies ? "${local.data_policy_reference_prefix}.${google_bigquery_datapolicyv2_data_policy.raw_pii[0].data_policy_id}" : null
}

output "dbt_masking_vars" {
  description = "Paste under `vars:` in vis_dbt/dbt_project.yml. The dbt macro prefixes these IDs with target.project and target.location, so the same values work in every environment."
  value = {
    mask_data_policies = { for k, p in google_bigquery_datapolicyv2_data_policy.masking : k => p.data_policy_id }
    raw_data_policy    = var.create_masking_policies ? google_bigquery_datapolicyv2_data_policy.raw_pii[0].data_policy_id : null
  }
}

output "composer_service_account_email" {
  description = "Airflow runtime service account."
  value       = var.create_composer ? google_service_account.composer[0].email : null
}

# Uncomment together with google_composer_environment.airflow in composer.tf.
# output "composer_airflow_uri" {
#   description = "Airflow web UI."
#   value       = var.create_composer ? google_composer_environment.airflow[0].config[0].airflow_uri : null
# }
#
# output "composer_dag_gcs_prefix" {
#   description = "Upload DAGs here, e.g. gcloud storage cp dags/*.py <prefix>/"
#   value       = var.create_composer ? google_composer_environment.airflow[0].config[0].dag_gcs_prefix : null
# }

output "data_bucket" {
  description = "Data bucket URI."
  value       = var.create_data_bucket ? "gs://${google_storage_bucket.data[0].name}" : null
}

output "bq_exporter_job_name" {
  description = "bq-exporter Cloud Run Job name, for CloudRunExecuteJobOperator and deploy.ps1."
  value       = google_cloud_run_v2_job.bq_exporter.name
}

output "bq_exporter_image" {
  description = "Image path deploy.ps1 pushes to (tagged per deploy)."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${var.repository_id}/bq-exporter"
}

output "bq_exporter_service_account_email" {
  description = "Runtime service account of the bq-exporter job."
  value       = google_service_account.bq_exporter.email
}
