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
