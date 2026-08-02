variable "project_id" {
  description = "GCP project that hosts the Cloud Run Job, Artifact Registry repo and service account."
  type        = string
}

variable "region" {
  description = "Region for the Cloud Run Job and Artifact Registry repo."
  type        = string
  default     = "us-central1"
}

variable "job_name" {
  description = "Name of the Cloud Run Job."
  type        = string
  default     = "dbt-runner"
}

variable "image" {
  description = "Full image reference to deploy, e.g. REGION-docker.pkg.dev/PROJECT_ID/REPOSITORY/dbt-runner:TAG. Build and push this with the repo's Dockerfile before applying."
  type        = string
}

variable "default_args" {
  description = "Default dbt CLI args used when the job is executed with no override. Airflow/Cloud Run overrides replace this per run (e.g. [\"run\", \"--select\", \"tag:daily\"])."
  type        = list(string)
  default     = ["build"]
}

variable "service_account_id" {
  description = "Account ID (not email) for the Cloud Run Job's runtime service account."
  type        = string
  default     = "dbt-runner"
}

variable "create_artifact_registry" {
  description = "Whether to create the Artifact Registry Docker repository for the image."
  type        = bool
  default     = true
}

variable "repository_id" {
  description = "Artifact Registry repository ID that holds the dbt-runner image."
  type        = string
  default     = "dbt-images"
}

variable "bigquery_dataset" {
  description = "Target BigQuery dataset dbt writes to (DBT_BIGQUERY_DATASET)."
  type        = string
}

variable "bigquery_location" {
  description = "BigQuery dataset location (DBT_BIGQUERY_LOCATION)."
  type        = string
  default     = "US"
}

variable "source_dataset_ids" {
  description = "Optional additional BigQuery dataset IDs the job's service account needs read access to (roles/bigquery.dataViewer), e.g. upstream source datasets."
  type        = list(string)
  default     = []
}

variable "dbt_threads" {
  description = "dbt threads (DBT_THREADS)."
  type        = number
  default     = 4
}

variable "dbt_target" {
  description = "dbt target name (DBT_TARGET)."
  type        = string
  default     = "cloud_run"
}

variable "cpu" {
  description = "CPU limit for the job container."
  type        = string
  default     = "1"
}

variable "memory" {
  description = "Memory limit for the job container."
  type        = string
  default     = "2Gi"
}

variable "task_timeout" {
  description = "Per-task timeout, e.g. \"3600s\"."
  type        = string
  default     = "3600s"
}

variable "max_retries" {
  description = "Max retries per task execution."
  type        = number
  default     = 0
}

variable "composer_service_account" {
  description = "Email of the Cloud Composer/Airflow environment service account that should be allowed to trigger executions of this job (granted roles/run.invoker). Leave blank to skip the binding and manage it elsewhere."
  type        = string
  default     = ""
}

variable "deletion_protection" {
  description = "Set true to block `terraform destroy` from deleting the job."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Labels applied to the Cloud Run Job."
  type        = map(string)
  default     = {}
}
