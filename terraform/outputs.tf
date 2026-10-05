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
