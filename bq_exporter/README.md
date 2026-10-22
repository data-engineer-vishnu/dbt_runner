# bq-exporter

Exports one BigQuery table to a file in GCS. Runs as the `bq-exporter` Cloud
Run Job (`terraform/bq_exporter.tf`), with its own image built from this
folder. In Airflow it runs right after the `dbt run -s <model>` task, so the
file is only written once the model is built.

## Config

One JSON object, passed as the single container arg or in the
`EXPORT_CONFIG` env var (the arg wins):

```json
{
  "table_name": "project-fd305953-166e-42aa-8d5.dev_vishnu.customers",
  "file_location": "gs://project-fd305953-166e-42aa-8d5-data/exports/customers.csv",
  "file_format": "CSV",
  "delimiter": "|",
  "print_header": true
}
```

| key | default | notes |
|---|---|---|
| `table_name` | required | `project.dataset.table` |
| `file_location` | required | `gs://` URI incl. file name; put `*` in the name for tables > 1 GB |
| `file_format` | `CSV` | `CSV`, `JSON`, `AVRO`, `PARQUET` |
| `delimiter` | `,` | CSV only; `\t` or `tab` for tab |
| `print_header` | `true` | CSV only |
| `compression` | `NONE` | `GZIP`, `DEFLATE`, `SNAPPY` |
| `impersonate_service_account` | none | needs an entry in `bq_exporter_impersonate_service_accounts` |
| `project` / `location` | job env vars | rarely needed |

Unknown keys fail the run, so typos don't get silently ignored.

**Adding an option:** add the key and its default to `DEFAULTS` in
`main.py`, use `config["<key>"]` where needed, redeploy.

## Dev loop

1. Edit `main.py`. Optionally try it locally first (your own credentials):

   ```powershell
   gcloud auth application-default login
   $env:EXPORT_CONFIG = '{"table_name": "PROJECT.dev_vishnu.customers", "file_location": "gs://BUCKET/exports/customers.csv"}'
   .\venv\Scripts\python.exe bq_exporter\main.py
   ```

2. Deploy to the Cloud Run Job:

   ```powershell
   .\bq_exporter\deploy.ps1
   ```

3. Trigger from the console: **Cloud Run > Jobs > bq-exporter > Execute >
   Execute with overrides**, add env var `EXPORT_CONFIG` with the JSON as its
   value (one line), click **Execute**, and watch the execution's **Logs**
   tab. The first log line prints the resolved config.

`terraform apply` ignores the job's image, so it won't roll back a deploy.

## Airflow task (after the dbt model)

```python
import json

export_customers = CloudRunExecuteJobOperator(
    task_id="export_customers",
    project_id=PROJECT_ID,
    region=REGION,
    job_name="bq-exporter",
    overrides={
        "container_overrides": [
            {
                "args": [
                    json.dumps({
                        "table_name": f"{PROJECT_ID}.dev_vishnu.customers",
                        "file_location": "gs://BUCKET/exports/customers_{{ ds_nodash }}.csv",
                        "file_format": "CSV",
                        "delimiter": "|",
                        "print_header": True,
                    })
                ],
            }
        ],
        "task_count": 1,
    },
)

dbt_run_customers >> export_customers
```
