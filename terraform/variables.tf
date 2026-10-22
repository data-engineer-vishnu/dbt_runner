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
  description = "Only for an EXTERNAL Composer/Airflow environment (create_composer = false): its service account email, used by the commented-out job-level bindings in main.tf. composer.tf grants its own SA what it needs."
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

variable "create_masking_policies" {
  description = "Whether to create the BigQuery direct v2 column data policies and masking routines (terraform/masking.tf)."
  type        = bool
  default     = true
}

variable "taxonomy_location" {
  description = "Deprecated name retained for compatibility. Location for direct data policies and masking routines. Leave blank to follow bigquery_location; it must match the protected tables' location."
  type        = string
  default     = ""
}

variable "masking_routine_dataset" {
  description = "Dataset that holds the masking UDF routines (mask_with_asterisk, mask_with_hash). Defaults to bigquery_dataset if left blank. Must already exist."
  type        = string
  default     = ""
}

variable "masking_masked_grantees" {
  description = "Default grantees for every masking policy (they see masked values). Use IAM v2 principal identifiers: \"principalSet://goog/group/analysts@example.com\", \"principal://goog/subject/alice@example.com\", or \"principal://iam.googleapis.com/projects/-/serviceAccounts/sa@proj.iam.gserviceaccount.com\". Override per policy with masking_policies[*].grantees."
  type        = list(string)
  default     = []
}

variable "masking_raw_grantees" {
  description = "Principals allowed to read original (unmasked) values, in IAM v2 principal format (see masking_masked_grantees). The dbt runner service account is added automatically when grant_dbt_runner_raw_access is true."
  type        = list(string)
  default     = []
}

variable "grant_dbt_runner_raw_access" {
  description = "Add the dbt runner service account to raw_pii_v2 so downstream models can read masked upstream columns. The dbt post-hook re-applies masking to those columns in the downstream tables."
  type        = bool
  default     = true
}

variable "masking_policies" {
  description = <<-EOT
    Masking data policies to create. The map key is the name dbt models use in
    `config.meta.mask_policy`; the BigQuery policy ID is `mask_<key>_v2`.
    Set exactly one of:
      routine               - a custom STRING-only UDF from masking.tf (mask_with_asterisk, mask_with_hash)
      predefined_expression - SHA256, ALWAYS_NULL, DEFAULT_MASKING_VALUE, LAST_FOUR_CHARACTERS,
                              EMAIL_MASK, DATE_YEAR_MASK, RANDOM_HASH
    grantees (optional) overrides masking_masked_grantees for that policy.
  EOT
  type = map(object({
    routine               = optional(string)
    predefined_expression = optional(string)
    grantees              = optional(list(string))
  }))
  default = {
    asterisk  = { routine = "mask_with_asterisk" }
    hash      = { routine = "mask_with_hash" }
    sha256    = { predefined_expression = "SHA256" }
    email     = { predefined_expression = "EMAIL_MASK" }
    last_four = { predefined_expression = "LAST_FOUR_CHARACTERS" }
    nullify   = { predefined_expression = "ALWAYS_NULL" }
    default   = { predefined_expression = "DEFAULT_MASKING_VALUE" }
    year_only = { predefined_expression = "DATE_YEAR_MASK" }
  }

  validation {
    condition = alltrue([
      for k, p in var.masking_policies :
      (p.routine == null) != (p.predefined_expression == null) && can(regex("^[a-z][a-z0-9_]*$", k))
    ])
    error_message = "Each masking_policies entry needs exactly one of routine or predefined_expression, and keys must be lowercase snake_case."
  }

  validation {
    condition = alltrue([
      for p in values(var.masking_policies) :
      p.routine == null || contains(["mask_with_asterisk", "mask_with_hash"], coalesce(p.routine, "x"))
    ])
    error_message = "routine must be one of the UDFs defined in masking.tf: mask_with_asterisk, mask_with_hash."
  }
}

# ---------------------------------------------------------------------------
# Cloud Composer (composer.tf)
# ---------------------------------------------------------------------------
variable "create_composer" {
  description = "Create the Cloud Composer 3 (Airflow) environment, its service account, bucket and IAM. Composer bills continuously; set false to remove it."
  type        = bool
  default     = true
}

variable "composer_environment_name" {
  description = "Cloud Composer environment name."
  type        = string
  default     = "dbt-airflow"
}

variable "composer_image_version" {
  description = "Composer image. The alias picks the latest Composer 3 / Airflow 2 build at create time; pin e.g. \"composer-3-airflow-2.10.5\" if you need repeatability."
  type        = string
  default     = "composer-3-airflow-2"
}

variable "composer_service_account_id" {
  description = "Account ID (not email) of the Airflow runtime service account."
  type        = string
  default     = "composer-airflow"
}

variable "composer_bucket_name" {
  description = "Environment bucket (dags/, plugins/, data/, logs/). Defaults to <project_id>-<composer_environment_name>."
  type        = string
  default     = ""
}

variable "composer_bucket_force_destroy" {
  description = "Allow terraform destroy to delete the bucket even if it still holds DAGs/logs."
  type        = bool
  default     = false
}

variable "composer_upload_dags" {
  description = "Upload ../dags/*.py to the environment bucket's dags/ folder."
  type        = bool
  default     = true
}

variable "composer_users" {
  description = "Principals (e.g. \"user:alice@example.com\", \"group:data@example.com\") granted roles/composer.user (Airflow UI) and objectAdmin on the environment bucket (DAG uploads)."
  type        = list(string)
  default     = []
}

# Workload sizes default to the Composer 3 minimums.
variable "composer_scheduler" {
  description = "Scheduler size (Composer 3 min: 0.5 vCPU, 1 GB)."
  type        = object({ cpu = number, memory_gb = number, storage_gb = number })
  default     = { cpu = 0.5, memory_gb = 1, storage_gb = 1 }
}

variable "composer_dag_processor" {
  description = "DAG processor size (Composer 3 min: 0.5 vCPU, 1 GB)."
  type        = object({ cpu = number, memory_gb = number, storage_gb = number })
  default     = { cpu = 0.5, memory_gb = 1, storage_gb = 1 }
}

variable "composer_web_server" {
  description = "Web server size (Composer 3 min: 1 vCPU, 2 GB)."
  type        = object({ cpu = number, memory_gb = number, storage_gb = number })
  default     = { cpu = 1, memory_gb = 2, storage_gb = 1 }
}

variable "composer_worker" {
  description = "Worker size and autoscaling range (Composer 3 min: 0.5 vCPU, 1 GB, 1 worker)."
  type        = object({ cpu = number, memory_gb = number, storage_gb = number, min_count = number, max_count = number })
  default     = { cpu = 0.5, memory_gb = 1, storage_gb = 1, min_count = 1, max_count = 1 }
}

variable "composer_data_buckets" {
  description = "Existing bucket names (no gs://) the Airflow SA may read and write, e.g. the input/output buckets of the gcs_unzip_files DAG."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Data bucket (storage.tf)
# ---------------------------------------------------------------------------
variable "create_data_bucket" {
  description = "Create the general-purpose data bucket in storage.tf."
  type        = bool
  default     = true
}

variable "data_bucket_name" {
  description = "Data bucket name (globally unique). Defaults to <project_id>-data."
  type        = string
  default     = ""
}

variable "data_bucket_admins" {
  description = "Principals granted roles/storage.admin on the data bucket, e.g. \"user:alice@example.com\". The Airflow SA is added automatically when create_composer is true."
  type        = list(string)
  default     = []
}

variable "data_bucket_versioning" {
  description = "Keep previous object versions (deleted after 30 days) so overwrites/deletes can be recovered."
  type        = bool
  default     = true
}

variable "data_bucket_force_destroy" {
  description = "Allow terraform destroy to delete the bucket even when it still contains objects."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# bq-exporter Cloud Run Job (bq_exporter.tf)
# ---------------------------------------------------------------------------
variable "bq_exporter_job_name" {
  description = "Name of the BigQuery -> GCS export Cloud Run Job."
  type        = string
  default     = "bq-exporter"
}

variable "bq_exporter_service_account_id" {
  description = "Account ID (not email) of the bq-exporter runtime service account."
  type        = string
  default     = "bq-exporter"
}

variable "bq_exporter_source_datasets" {
  description = "Dataset IDs in project_id whose tables the job may export (roles/bigquery.dataViewer)."
  type        = list(string)
  default     = []
}

variable "bq_exporter_output_buckets" {
  description = "Extra bucket names (no gs://) the job may write files to. The data bucket from storage.tf is added automatically."
  type        = list(string)
  default     = []
}

variable "bq_exporter_impersonate_service_accounts" {
  description = "Service account emails the job may impersonate (roles/iam.serviceAccountTokenCreator), i.e. the impersonation_service_account values used in the DAG YAML files."
  type        = list(string)
  default     = []
}

variable "bq_exporter_cpu" {
  description = "CPU limit for the bq-exporter container."
  type        = string
  default     = "1"
}

variable "bq_exporter_memory" {
  description = "Memory limit for the bq-exporter container. The export runs inside BigQuery, so this stays small."
  type        = string
  default     = "512Mi"
}

variable "bq_exporter_task_timeout" {
  description = "Per-task timeout, e.g. \"1800s\"."
  type        = string
  default     = "1800s"
}

variable "bq_exporter_max_retries" {
  description = "Max retries per task execution."
  type        = number
  default     = 0
}
