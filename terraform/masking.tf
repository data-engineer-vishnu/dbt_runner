# BigQuery dynamic column data masking (direct v2 data policies).
#
# Terraform owns the *policies* (what a masked value looks like and who may see
# masked vs. raw data). dbt owns the *assignment* of policies to columns: a
# column opts in through `config.meta.mask_policy` in a model's YAML, and the
# post-hook in vis_dbt/macros/masking.sql attaches the policy with
#   ALTER TABLE ... ALTER COLUMN ... SET OPTIONS(data_policies = [...])
#
# Policy-tag taxonomies are intentionally not used: BigQuery DDL cannot set
# policy_tags, while direct data policies can be set through DDL. Never attach a
# policy tag and a direct data policy to the same column.
#
# Access model per protected column:
#   * principals in the masking policy's grantees  -> see the masked value
#   * principals in raw_pii_v2's grantees           -> see the original value
#   * anyone else (even dataViewer/dataOwner)       -> "Access Denied" on that column

locals {
  masking_routine_dataset = var.masking_routine_dataset != "" ? var.masking_routine_dataset : var.bigquery_dataset

  # Data policies and their routines must be in the same location as the
  # tables they protect. `taxonomy_location` is retained as an input name for
  # backward compatibility with existing tfvars files.
  data_policy_location = var.taxonomy_location != "" ? var.taxonomy_location : var.bigquery_location

  # BigQuery DDL references a direct data policy as <project>.region-<location>.<policy_id>.
  data_policy_reference_prefix = "${var.project_id}.region-${lower(local.data_policy_location)}"

  # Custom masking UDFs. Each one is STRING -> STRING: BigQuery requires a
  # custom routine's input/output types to match the protected column's type.
  # Use a predefined expression (see var.masking_policies) for non-STRING columns.
  masking_routines = var.create_masking_policies ? {
    mask_with_asterisk = "CASE WHEN value IS NULL THEN NULL ELSE RPAD('', LENGTH(value), '*') END"
    mask_with_hash     = "CASE WHEN value IS NULL THEN NULL ELSE RPAD('', LENGTH(value), '#') END"
  } : {}

  masking_policies = var.create_masking_policies ? var.masking_policies : {}

  # The dbt runtime identity must read raw values to build downstream models
  # (otherwise `select * from {{ ref('customer') }}` fails with "does not have
  # masked access or raw data access"). The macro then re-protects the
  # downstream columns, so raw data never lands unprotected.
  dbt_runner_principal = "principal://iam.googleapis.com/projects/-/serviceAccounts/${google_service_account.dbt_runner.email}"

  raw_grantees = distinct(concat(
    var.masking_raw_grantees,
    var.grant_dbt_runner_raw_access ? [local.dbt_runner_principal] : [],
  ))
}

resource "google_bigquery_routine" "masking" {
  for_each = local.masking_routines

  project      = var.project_id
  dataset_id   = local.masking_routine_dataset
  routine_id   = each.key
  routine_type = "SCALAR_FUNCTION"
  language     = "SQL"

  arguments {
    name      = "value"
    data_type = jsonencode({ "typeKind" : "STRING" })
  }
  return_type          = jsonencode({ "typeKind" : "STRING" })
  definition_body      = each.value
  data_governance_type = "DATA_MASKING"
}

# One masking data policy per entry in var.masking_policies. The map key is the
# name dbt models use in `mask_policy:`; the BigQuery policy ID is
# mask_<key>_v2 (so existing mask_asterisk_v2 / mask_hash_v2 are kept).
resource "google_bigquery_datapolicyv2_data_policy" "masking" {
  provider = google-beta
  for_each = local.masking_policies

  project          = var.project_id
  location         = local.data_policy_location
  data_policy_id   = "mask_${each.key}_v2"
  data_policy_type = "DATA_MASKING_POLICY"
  grantees         = each.value.grantees != null ? each.value.grantees : var.masking_masked_grantees

  data_masking_policy {
    predefined_expression = each.value.predefined_expression
    routine               = each.value.routine != null ? google_bigquery_routine.masking[each.value.routine].id : null
  }
}

# Attached alongside the masking policy on every protected column so that the
# listed identities (plus the dbt runner, see above) see original values.
resource "google_bigquery_datapolicyv2_data_policy" "raw_pii" {
  provider = google-beta
  count    = var.create_masking_policies ? 1 : 0

  project          = var.project_id
  location         = local.data_policy_location
  data_policy_id   = "raw_pii_v2"
  data_policy_type = "RAW_DATA_ACCESS_POLICY"
  grantees         = local.raw_grantees
}

# The dbt runtime service account attaches direct data policies from the
# post-hook. It also retains dataset-level dataEditor from main.tf.
resource "google_project_iam_member" "dbt_runner_data_policy_admin" {
  count = var.create_masking_policies ? 1 : 0

  project = var.project_id
  role    = "roles/bigquerydatapolicy.admin"
  member  = "serviceAccount:${google_service_account.dbt_runner.email}"
}

# ---------------------------------------------------------------------------
# State moves from the previous one-resource-per-policy layout. These keep the
# already-applied routines/policies in place (no destroy/recreate). They can be
# deleted once every environment has applied this version.
# ---------------------------------------------------------------------------
moved {
  from = google_bigquery_routine.mask_with_asterisk[0]
  to   = google_bigquery_routine.masking["mask_with_asterisk"]
}

moved {
  from = google_bigquery_routine.mask_with_hash[0]
  to   = google_bigquery_routine.masking["mask_with_hash"]
}

moved {
  from = google_bigquery_datapolicyv2_data_policy.asterisk[0]
  to   = google_bigquery_datapolicyv2_data_policy.masking["asterisk"]
}

moved {
  from = google_bigquery_datapolicyv2_data_policy.hash[0]
  to   = google_bigquery_datapolicyv2_data_policy.masking["hash"]
}
