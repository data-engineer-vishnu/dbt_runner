# dbt on Cloud Run Jobs

This image runs a dbt project with `dbt-bigquery`. It is designed for **Cloud Run Jobs**: each container invocation executes one dbt command and exits with dbt's status code. Airflow/Cloud Composer can use that status to determine whether a run succeeded.

## Project layout

```text
.
├── Dockerfile
├── requirements.txt       # dbt adapter and Python dependencies
├── packages.yml           # dbt package dependencies, installed during image build
├── dbt_project.yml
├── profiles/profiles.yml  # environment-driven BigQuery profile; contains no secrets
├── models/
├── macros/
└── docker/entrypoint.sh
```

The included model is only a smoke-test example. Replace it with the actual project models.

## BigQuery authentication

The profile uses `method: oauth`, which uses Application Default Credentials. In Cloud Run, attach a dedicated service account to the job; do not mount a service-account key or set `GOOGLE_APPLICATION_CREDENTIALS`.

At a minimum, grant that service account:

- `roles/bigquery.jobUser` on the project that creates BigQuery jobs.
- Dataset-level permissions required by the models (typically `roles/bigquery.dataEditor` for the target dataset, plus read access to source datasets).

The job must receive these non-secret environment variables:

| Variable | Example | Purpose |
| --- | --- | --- |
| `GCP_PROJECT_ID` | `analytics-prod` | BigQuery billing/project ID |
| `DBT_BIGQUERY_DATASET` | `analytics` | Target dataset |
| `DBT_BIGQUERY_LOCATION` | `US` | BigQuery dataset location |
| `DBT_THREADS` | `4` | Optional dbt worker count |
| `DBT_TARGET` | `cloud_run` | Optional profile target |

## Build and deploy

Set your values locally, then build the image with Cloud Build:

```sh
gcloud builds submit --tag REGION-docker.pkg.dev/PROJECT_ID/REPOSITORY/dbt-runner:TAG
```

Create or update the Cloud Run Job:

```sh
gcloud run jobs deploy dbt-runner \
  --image REGION-docker.pkg.dev/PROJECT_ID/REPOSITORY/dbt-runner:TAG \
  --region REGION \
  --service-account dbt-runner@PROJECT_ID.iam.gserviceaccount.com \
  --set-env-vars GCP_PROJECT_ID=PROJECT_ID,DBT_BIGQUERY_DATASET=analytics,DBT_BIGQUERY_LOCATION=US,DBT_THREADS=4 \
  --task-timeout 1h \
  --max-retries 0
```

The default command is `dbt build`. Run it once manually:

```sh
gcloud run jobs execute dbt-runner --region REGION --wait
```

To run a different selector, pass command arguments when the job is executed (or as an Airflow override):

```sh
gcloud run jobs execute dbt-runner \
  --region REGION \
  --args build,--select,tag:daily \
  --wait
```

## Airflow / Cloud Composer handoff

Use a Cloud Run Job execution operator and provide per-run dbt arguments as a container override. Conceptually, the override is:

```python
overrides = {
    "containerOverrides": [
        {"args": ["build", "--select", "tag:daily"]},
    ],
}
```

Keep one Cloud Run task for a normal dbt run. If you later use multiple Cloud Run tasks, partition model selections yourself; otherwise every task would execute the same dbt command against BigQuery.
