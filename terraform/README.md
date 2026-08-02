# Terraform: dbt Cloud Run Job

Provisions the pieces the dbt-runner image needs to run as a **Cloud Run Job**:
an Artifact Registry repo, a dedicated runtime service account with BigQuery
IAM bindings, the job itself, and (optionally) an IAM binding letting your
Composer/Airflow environment's service account trigger executions.

## Usage

```sh
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in your values

# Build and push the image referenced by `image` before the first apply —
# google_cloud_run_v2_job needs an existing image to deploy.
gcloud builds submit --tag <region>-docker.pkg.dev/<project>/<repository_id>/dbt-runner:latest ..

terraform init
terraform apply
```

## Notes

- `image` is intentionally not managed by Terraform (`ignore_changes` covers
  it) — CI/CD pushes new tags and updates the job outside of `terraform apply`
  via `gcloud run jobs update --image ...` or a new execution override.
- `composer_service_account` only needs `roles/run.invoker` on the job; the
  job's own runtime identity (`google_service_account.dbt_runner`) is what
  actually talks to BigQuery.
- `bigquery_dataset` must already exist; this module grants IAM on it but
  doesn't create the dataset. Add `source_dataset_ids` for read-only access to
  upstream datasets referenced by `source(...)` calls in the models.
- Both `image` and the container `args` are in `lifecycle.ignore_changes`,
  since Airflow/CI update them out-of-band (new image tags, per-run command
  overrides). Env vars, cpu/memory, and timeout/retries are still diffed
  normally by Terraform. To change the *default* command baked into the job,
  edit `default_args` and re-apply — but note it won't take effect until you
  temporarily remove it from `ignore_changes` or update it via `gcloud run
  jobs update` directly, since Terraform will otherwise ignore the drift.
