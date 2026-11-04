<#
.SYNOPSIS
Manage replica scaling for Capstone Azure Container Apps stack.

Modes:
  - Serverless : minReplicas 0 for Web/API/Workers, 1 for DBs (lowest active burn).
  - WarmDemo   : minReplicas 1 for all apps including Ollama (instant response for presentation).
  - SleepAll   : minReplicas 0 for ALL apps including DBs ($0.00/hr credit burn when idle).

.EXAMPLE
  .\scripts\scale.ps1 -Mode Serverless
  .\scripts\scale.ps1 -Mode WarmDemo
  .\scripts\scale.ps1 -Mode SleepAll
#>
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("Serverless", "WarmDemo", "SleepAll")]
    [string]$Mode,

    [string]$Resource = "rg-capstone",
    [string]$Sub = ""
)

$ErrorActionPreference = "Stop"
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI not found."
}

if (-not [string]::IsNullOrWhiteSpace($Sub)) {
    az account set --subscription $Sub
}

Write-Host "Fetching container apps in resource group '$Resource'..." -ForegroundColor Cyan
$apps = az containerapp list -g $Resource --query "[].{name:name, minReplicas:properties.template.scale.minReplicas}" -o json | ConvertFrom-Json

if (-not $apps -or $apps.Count -eq 0) {
    Write-Host "No container apps found in '$Resource'." -ForegroundColor Yellow
    return
}

$dbApps = @("shared-mysql", "shared-redis", "shared-postgres", "shared-mongo")

Write-Host "Applying Scaling Profile: $Mode..." -ForegroundColor Green

foreach ($app in $apps) {
    $name = $app.name
    $targetMin = 0

    if ($Mode -eq "WarmDemo") {
        $targetMin = 1
    } elseif ($Mode -eq "Serverless") {
        if ($dbApps -contains $name) {
            $targetMin = 1
        } else {
            $targetMin = 0
        }
    } elseif ($Mode -eq "SleepAll") {
        $targetMin = 0
    }

    Write-Host "  -> Setting $name minReplicas = $targetMin" -ForegroundColor DarkGray
    az containerapp update -n $name -g $Resource --min-replicas $targetMin --output none
}

Write-Host "`nProfile '$Mode' applied successfully to $($apps.Count) container apps!" -ForegroundColor Green
