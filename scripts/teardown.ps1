<#
.SYNOPSIS
Tear down everything to stop burning Azure credits. Deletes the resource group
(the ACR + all container apps + env) and any backups created by this repo.

.EXAMPLE
  .\scripts\teardown.ps1 -Resource rg-capstone
#>
param(
    [string]$Resource = "rg-capstone"
)
$ErrorActionPreference = "Stop"
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw "Azure CLI not found." }

Write-Host "Deleting resource group '$Resource' (all 14 apps + ACR + env)..." -ForegroundColor Yellow
az group delete --name $Resource --yes --no-wait
Write-Host "Resource group deletion initiated. Verify with:" -ForegroundColor Green
Write-Host "  az group list -o table"