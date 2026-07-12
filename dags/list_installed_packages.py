"""Log the Python packages available on the Airflow worker that runs this task."""

from __future__ import annotations

import logging
import subprocess
import sys
from datetime import datetime

from airflow import DAG
from airflow.operators.python import PythonOperator


def log_installed_packages() -> None:
    """Write `pip list` output to the Airflow task log.

    The command uses the task's interpreter, which means the list reflects the
    packages installed in the Composer worker executing this DAG.
    """
    result = subprocess.run(
        [sys.executable, "-m", "pip", "list", "--format=columns"],
        check=True,
        capture_output=True,
        text=True,
    )
    logging.info("Installed Python packages on this Airflow worker:\n%s", result.stdout)


with DAG(
    dag_id="list_installed_packages",
    description="Logs all Python packages installed on the executing Airflow worker.",
    start_date=datetime(2026, 1, 1),
    schedule=None,
    catchup=False,
    tags=["diagnostics", "composer"],
) as dag:
    PythonOperator(
        task_id="log_pip_packages",
        python_callable=log_installed_packages,
    )
