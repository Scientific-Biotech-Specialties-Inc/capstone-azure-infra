<#
.SYNOPSIS
Deploy the full capstone microservice stack to Azure Container Apps.

Budget orientation: $100/yr credits, presentation-only, ephemeral data, single
env, free-tier compute. No Front Door / App Gateway / managed DBs / Key Vault.

Sequences:
  1) Resource group + ACR + Managed Environment (main.bicep)
  2) Build & push all images to ACR (az acr build, no local Docker needed)
  3) Deploy the 14 container apps + secrets (apps.bicep)

PRE-REQUISITES
  - Azure CLI: az login
  - secrets.prod.json created from secrets.example.json and filled in
  - The three app repos must have the Dockerfiles/workflows this repo expects
    (serms's apps/web/Dockerfile.prod, auth's deploy/nginx.Dockerfile,
     ocr's Dockerfile.ollama). See README.md.

.EXAMPLE
  .\scripts\deploy.ps1
  .\scripts\deploy.ps1 -MinReplicas 0   # scale-to-zero (cheap when idle)
#>
param(
    [string]$RepoRoot = "C:\Projects",
    [string]$Sub = "",
    [string]$Resource = "rg-capstone",
    [string]$Location = "eastus",
    [string]$EnvironmentName = "capstone-env",
    [string]$AcrName = "capstoneacr0001",
    [string]$ImageTag = "latest",
    [int]$MinReplicas = 1
)

$ErrorActionPreference = "Stop"
$InfraRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

# --------------------------------------------------------------------------
# 0. Pre-flight
# --------------------------------------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI not found. Install from https://aka.ms/install-azure-cli"
}

$secretsFile = Join-Path $InfraRoot "secrets.prod.json"
if (-not (Test-Path $secretsFile)) {
    throw "Missing $secretsFile. Copy secrets.example.json -> secrets.prod.json and fill in."
}
$secrets = Get-Content -Raw $secretsFile | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($Sub)) {
    $ctx = az account show -o json | ConvertFrom-Json
    $Sub = $ctx.id
    Write-Host "Using subscription: $($ctx.name) ($($ctx.id))" -ForegroundColor Magenta
}
az account set --subscription $Sub

Write-Host "RG=$Resource | env=$EnvironmentName | acr=$AcrName | loc=$Location | tag=$ImageTag" -ForegroundColor Cyan
$acrLoginServer = "$AcrName.azurecr.io"

# --------------------------------------------------------------------------
# 1. Resource group + ACR + Managed Environment
# --------------------------------------------------------------------------
Write-Host "`n[1/3] Core infrastructure..." -ForegroundColor Green
az group create --name $Resource --location $Location --output none
az deployment group create `
    --resource-group $Resource `
    --name "capstone-infra" `
    --template-file (Join-Path $InfraRoot "infra\main.bicep") `
    --parameters location=$Location environmentName=$EnvironmentName acrName=$AcrName `
    --output none
if ($LASTEXITCODE -ne 0) { throw "Core infra deployment failed." }

# ---------------------------------------------------------------------------
# 2. Build & push images to ACR
# ---------------------------------------------------------------------------
$builds = @(
    @{ Name = "$acrLoginServer/serms-api:$ImageTag";  Ctx = "$RepoRoot\smart-expense-management-system\apps\api";  Dockerfile = "Dockerfile" }
    @{ Name = "$acrLoginServer/serms-web:$ImageTag";  Ctx = "$RepoRoot\smart-expense-management-system\apps\web";  Dockerfile = "Dockerfile.prod" }
    @{ Name = "$acrLoginServer/auth-api:$ImageTag";   Ctx = "$RepoRoot\capstone-auth-module\auth-service";         Dockerfile = "Dockerfile" }
    @{ Name = "$acrLoginServer/auth-web:$ImageTag";   Ctx = "$RepoRoot\capstone-auth-module\web-interface";        Dockerfile = "Dockerfile" }
    @{ Name = "$acrLoginServer/auth-proxy:$ImageTag"; Ctx = "$RepoRoot\capstone-auth-module";                     Dockerfile = "deploy\nginx.Dockerfile" }
    @{ Name = "$acrLoginServer/ocr-api:$ImageTag";    Ctx = "$RepoRoot\ocr-pipeline";                             Dockerfile = "Dockerfile" }
    @{ Name = "$acrLoginServer/ocr-ollama:$ImageTag"; Ctx = "$RepoRoot\ocr-pipeline";                             Dockerfile = "Dockerfile.ollama" }
    @{ Name = "$acrLoginServer/mysql-init:$ImageTag"; Ctx = (Join-Path $InfraRoot "containers\mysql");            Dockerfile = "Dockerfile" }
)
Write-Host "`n[2/3] Building & pushing $($builds.Count) images (slowest step)..." -ForegroundColor Cyan
$n = 0
foreach ($b in $builds) {
    $n++
    Write-Host "  ($n/$($builds.Count)) $($b.Dockerfile) -> $($b.Name)" -ForegroundColor Yellow
    az acr build --registry $AcrName --image $b.Name --file $b.Dockerfile --context $b.Ctx --output none
    if ($LASTEXITCODE -ne 0) { throw "Build failed for $($b.Name)" }
}

# ---------------------------------------------------------------------------
# 3. Deploy the container apps + secrets
# ---------------------------------------------------------------------------
Write-Host "`n[3/3] Deploying container apps..." -ForegroundColor Cyan

$cfg = Get-Content -Raw (Join-Path $InfraRoot "infra\parameters.prod.json") | ConvertFrom-Json

$all = [ordered]@{}
$all["acrName"]        = $AcrName
$all["environmentName"]= $EnvironmentName
$all["location"]       = $Location
$all["imageTag"]       = $ImageTag
$all["minReplicas"]    = $MinReplicas

# non-secret config from parameters.prod.json
foreach ($k in @('supabaseUrl','supabaseBucket','supabaseRegion','supabaseEndpoint','brevoBaseUrl','brevoWebhookSecret','brevoWebhookHeader','vendorManagementUrl','brevoTemplates','authWebApiUrl')) {
    if ($null -ne $cfg.parameters.$k) { $all[$k] = $cfg.parameters.$k.value }
}
# secrets from secrets.prod.json
foreach ($p in $secrets.PSObject.Properties) { $all[$p.Name] = $p.Value }

# az deployment parameters file -> { "parameters": { "<name>": { "value": v } } }
$inner = @{}
foreach ($k in $all.Keys) { $inner[$k] = @{ value = $all[$k] } }
$paramFile = Join-Path $env:TEMP "capstone-apps-params.json"
@{ parameters = $inner } | ConvertTo-Json -Depth 8 | Set-Content -Path $paramFile -Encoding utf8

az deployment group create `
    --resource-group $Resource `
    --name "capstone-apps" `
    --template-file (Join-Path $InfraRoot "infra\apps.bicep") `
    --parameters "@$paramFile" `
    --output none
if ($LASTEXITCODE -ne 0) { throw "Container apps deployment failed." }

# ---------------------------------------------------------------------------
# 4. Done — surface the front-door URL
# ---------------------------------------------------------------------------
$proxyFqdn = (az containerapp show -n "auth-proxy" -g $Resource --query "properties.configuration.ingress.fqdn" -o tsv)
Write-Host ""
Write-Host "=== DEPLOYED ===" -ForegroundColor Green
Write-Host "SERMS (front door /serms): https://$proxyFqdn/serms"
Write-Host "Auth admin (/)           : https://$proxyFqdn"
Write-Host ""
Write-Host "Next: warm the stack (first Ollama model pull can take minutes),"
Write-Host "seed a demo user in the auth API, then present. Then ALWAYS tear down:" -ForegroundColor Yellow
Write-Host "  .\scripts\teardown.ps1 -Resource $Resource"