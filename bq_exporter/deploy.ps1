<#
Builds the bq-exporter image with Cloud Build (no local Docker needed) and
points the Cloud Run Job at it. Then trigger it from the Cloud Run console
(Jobs > bq-exporter > Execute > Execute with overrides).

    .\bq_exporter\deploy.ps1

Each deploy gets a timestamp tag, so the job always picks up the new build.
Defaults match terraform/terraform.tfvars.
#>
param(
    [string]$Project = "project-fd305953-166e-42aa-8d5",
    [string]$Region = "asia-southeast1",
    [string]$Repository = "dbt-images",
    [string]$Job = "bq-exporter"
)

$ErrorActionPreference = "Stop"

$tag = Get-Date -Format "yyyyMMdd-HHmmss"
$image = "$Region-docker.pkg.dev/$Project/$Repository/bq-exporter:$tag"

Write-Host "==> Building $image"
gcloud builds submit $PSScriptRoot --tag $image --project $Project --region $Region --quiet
if ($LASTEXITCODE -ne 0) { throw "Cloud Build failed" }

Write-Host "==> Updating Cloud Run Job $Job"
gcloud run jobs update $Job --image $image --region $Region --project $Project --quiet
if ($LASTEXITCODE -ne 0) { throw "Job update failed" }

Write-Host "==> Deployed. Run it: https://console.cloud.google.com/run/jobs/details/$Region/$Job/executions?project=$Project"
