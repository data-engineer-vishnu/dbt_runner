# Terraform: dbt Cloud Run Job

Provisions the pieces the dbt-runner image needs to run as a Cloud Run Job:
an Artifact Registry repository, a dedicated runtime service account with
BigQuery IAM bindings, the job itself, and optionally an IAM binding for a
Composer or Airflow service account to start executions.

## Usage

```sh
cd terraform
cp terraform.tfvars.example terraform.tfvars

# Build and push the image before the first apply.
gcloud builds submit --tag <region>-docker.pkg.dev/<project>/<repository_id>/dbt-runner:latest ..

terraform init
terraform plan
terraform apply
```

## Notes

- `bigquery_dataset` must already exist. This module grants the runtime
  identity access to it but does not create it.
- `source_dataset_ids` grants read-only access to upstream datasets referenced
  by dbt sources.
- The Cloud Run Job resource remains commented out in `main.tf`. Re-enable it
  together with its outputs when it is ready to be managed by Terraform.

## Dynamic column masking (direct v2 data policies)

Terraform owns the policies; dbt YAML decides which columns get them.

`masking.tf` creates:

- One masking policy per entry in `var.masking_policies` (ID `mask_<key>_v2`).
  Defaults:

  | key (`mask_policy` in dbt) | masking | column types |
  |---|---|---|
  | `asterisk`  | custom UDF, every char -> `*` | STRING |
  | `hash`      | custom UDF, every char -> `#` | STRING |
  | `sha256`    | `SHA256` | STRING, BYTES |
  | `email`     | `EMAIL_MASK` (`XXXXX@domain.com`) | STRING |
  | `last_four` | `LAST_FOUR_CHARACTERS` | STRING |
  | `nullify`   | `ALWAYS_NULL` | any |
  | `default`   | `DEFAULT_MASKING_VALUE` (`''`, `0`, `false`, ...) | any |
  | `year_only` | `DATE_YEAR_MASK` | DATE, DATETIME, TIMESTAMP |

- `raw_pii_v2`, a raw-data-access policy attached next to every mask.
- `roles/bigquerydatapolicy.admin` for the dbt runner SA so its post-hook can
  attach policies.

Who sees what on a protected column:

| principal is in | result |
|---|---|
| `masking_raw_grantees` (+ dbt runner SA) | original value |
| `masking_masked_grantees` (or the policy's own `grantees`) | masked value |
| neither | `Access Denied` (even with dataViewer/dataOwner) |

Grantees use IAM v2 principal identifiers:

```hcl
masking_masked_grantees = ["principalSet://goog/group/analysts@example.com"]
masking_raw_grantees    = [
  "principalSet://goog/group/pii-readers@example.com",
  "principal://goog/subject/alice@example.com",
  # service account:
  # "principal://iam.googleapis.com/projects/-/serviceAccounts/sa@PROJECT.iam.gserviceaccount.com",
]
```

The dbt runner SA is added to `raw_pii_v2` automatically
(`grant_dbt_runner_raw_access = true`) so downstream models can read masked
upstream columns; the dbt macro re-masks those columns downstream. If you run
dbt locally with your own account, add that account to `masking_raw_grantees`.

To add a policy, add an entry to `masking_policies` in `terraform.tfvars`,
`terraform apply`, then add the same key to `vars.mask_data_policies` in
`vis_dbt/dbt_project.yml` (`terraform output dbt_masking_vars` prints the
exact values).

### Upgrading from the previous layout

`masking.tf` contains `moved` blocks, so the existing `mask_with_asterisk`,
`mask_with_hash`, `mask_asterisk_v2` and `mask_hash_v2` are re-addressed, not
recreated. `terraform plan` should show only new policies being created and
`raw_pii_v2` grantees being updated.

### Caveats

- Direct data policies can only be attached to tables, not views. A view over a
  masked table is still protected by the table's policies.
- dbt rebuilds `table` models with `CREATE OR REPLACE`, which drops column
  policies; the post-hook re-attaches them a few seconds later. For tables
  that must never be readable unmasked, keep raw readers' dataset access
  separate from the dataset dbt writes to, or use incremental models (policies
  persist across incremental runs).
- For incremental models and snapshots, removing `mask_policy` from YAML does
  not detach an existing policy; run a `--full-refresh` or detach it manually.
- Never attach a legacy policy tag and a direct data policy to the same column.

## Cloud Composer (Airflow)

`composer.tf` creates a Composer 3 / Airflow 2 environment (`dbt-airflow`) at
the smallest sizes Composer 3 allows, to run the DAGs in `../dags`:

| component | size |
|---|---|
| scheduler | 1 × 0.5 vCPU, 1 GB |
| DAG processor | 1 × 0.5 vCPU, 1 GB |
| web server | 1 vCPU, 2 GB |
| workers | 1 × 0.5 vCPU, 1 GB (min 1, max 1) |
| triggerer | none |

Override any of these with `composer_scheduler`, `composer_dag_processor`,
`composer_web_server` and `composer_worker`. Composer cannot scale to zero, so
it bills continuously; set `create_composer = false` and apply to remove it.

It also creates:

- **`composer-airflow` service account** (the Airflow identity and the
  `google_cloud_default` connection used by the DAGs), with:
  - `roles/composer.worker`: required for any Composer environment SA
  - `roles/run.jobsExecutorWithOverrides`: run the dbt-runner job with arg overrides
  - `roles/run.viewer`: poll the execution until it finishes
  - `roles/logging.viewer`: needed only for `verbose=True` log streaming
  - `roles/storage.objectAdmin` on the environment bucket
- **Environment bucket** `<project_id>-dbt-airflow`, with uniform access and
  public access blocked. The DAGs in `../dags/*.py` are uploaded to `dags/` on
  every apply.
- **`roles/composer.ServiceAgentV2Ext`** for the Cloud Composer service agent,
  required when an environment uses a user-managed SA.
- Airflow Variables `dbt_runner_gcp_project_id`, `dbt_runner_region` and
  `dbt_runner_job_name`, set via `AIRFLOW_VAR_*` environment variables.
- Optional `composer_users` (for example `"user:you@example.com"`) get
  `roles/composer.user` for the Airflow UI, plus write access to the bucket.

Creating the environment takes about 20–30 minutes:

```sh
terraform apply
terraform output composer_airflow_uri
```

The DAGs execute the Cloud Run Job named `job_name` (`dbt-runner`). Its
Terraform resource is still commented out in `main.tf`, so the job must exist
before a DAG run succeeds.
