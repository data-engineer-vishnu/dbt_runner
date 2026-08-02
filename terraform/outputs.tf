output "job_name" {
  description = "Cloud Run Job name, for use in Airflow's CloudRunExecuteJobOperator."
  value       = google_cloud_run_v2_job.dbt_runner.name
}

output "job_id" {
  description = "Fully-qualified Cloud Run Job resource ID."
  value       = google_cloud_run_v2_job.dbt_runner.id
}

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
