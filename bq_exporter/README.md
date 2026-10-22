# bq-exporter

Exports one BigQuery table to a file in GCS. One Cloud Run Job serves several
export types, picked by the required `export_vendor` key:

| `export_vendor` | what it does |
|---|---|
| `modeA` | Python-written CSV, values verbatim, quoted header, one file per execution date |

Adding a mode: write `export_mode_b(config, bq, gcs)`, give it a
`MODE_B_DEFAULTS` dict of its own keys, and register both in `EXPORTERS` in
`main.py`.

Runs as the `bq-exporter` Cloud Run Job (`terraform/bq_exporter.tf`), with its
own image built from this folder. In Airflow it runs right after the
`dbt run -s <model>` task, so the file is only written once the model is built.

## modeA: what it writes

Rows are read with a query and written by Python, not a BigQuery extract job,
so **values are written exactly as stored**. A value of `"Blue"` (quotes
included, e.g. from the `churners_quoted` model) lands in the file as `"Blue"`.
The header row is always written, with each name wrapped in double quotes.

```
"CLIENTNUM"|"Attrition_Flag"|"Customer_Age"|...
"718619883"|"Existing Customer"|"54"|...
```

Values are not escaped. NULL is written as an empty field. If a table isn't
pre-quoted, a delimiter or newline inside a value will break the CSV, so
export a quoted model (`quote_column_values` macro) instead.

For `file_location` `gs://bucket/exports/churners.csv` and `execution_date`
`2026-10-22` the file is:

```
gs://bucket/exports/dt=2026-10-22/churners_20261022.csv
```

After writing, any other file directly in that date folder is deleted, so
re-runs for a date always leave exactly one file. (The data bucket keeps
deleted versions for 30 days.)

## Config

One JSON object, passed as the single container arg or in the
`EXPORT_CONFIG` env var (the arg wins):

```json
{
  "export_vendor": "modeA",
  "table_name": "project-fd305953-166e-42aa-8d5.dev_vishnu.churners_quoted",
  "file_location": "gs://project-fd305953-166e-42aa-8d5-data/exports/churners.csv",
  "execution_date": "2026-10-22",
  "delimiter": "|"
}
```

| key | default | notes |
|---|---|---|
| `export_vendor` | required | `modeA` (case-insensitive) |
| `table_name` | required | `project.dataset.table` |
| `file_location` | required | folder + base file name; date folder and `_YYYYMMDD` are added |
| `execution_date` | today (UTC) | `YYYY-MM-DD` or `YYYYMMDD` |
| `delimiter` (modeA) | `,` | `\t` or `tab` for tab |
| `partition_folder_format` (modeA) | `dt=%Y-%m-%d` | strftime format of the date folder (Hive style), e.g. `dt=%Y%m%d` |
| `impersonate_service_account` | none | needs an entry in `bq_exporter_impersonate_service_accounts` |
| `project` / `location` | job env vars | rarely needed |

Unknown keys fail the run (checked against the common keys plus the chosen
mode's keys), so typos don't get silently ignored.

**Adding an option:** add the key and its default to `COMMON_DEFAULTS` (all
modes) or the mode's `MODE_*_DEFAULTS` in `main.py`, use `config["<key>"]`
where needed, redeploy.

## Dev loop

1. Edit `main.py`. Optionally try it locally first (your own credentials):

   ```powershell
   gcloud auth application-default login
   $env:EXPORT_CONFIG = '{"export_vendor": "modeA", "table_name": "PROJECT.dev_vishnu.churners_quoted", "file_location": "gs://BUCKET/exports/churners.csv"}'
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

export_churners = CloudRunExecuteJobOperator(
    task_id="export_churners",
    project_id=PROJECT_ID,
    region=REGION,
    job_name="bq-exporter",
    overrides={
        "container_overrides": [
            {
                "args": [
                    json.dumps({
                        "export_vendor": "modeA",
                        "table_name": f"{PROJECT_ID}.dev_vishnu.churners_quoted",
                        "file_location": "gs://BUCKET/exports/churners.csv",
                        "execution_date": "{{ ds }}",
                        "delimiter": "|",
                    })
                ],
            }
        ],
        "task_count": 1,
    },
)

dbt_run_churners_quoted >> export_churners
```
