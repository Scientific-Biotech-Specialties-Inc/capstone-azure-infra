<#
.SYNOPSIS
Deploy the full capstone microservice stack to Azure Container Apps.

Budget orientation: $100/yr credits, presentation-only, ephemeral data, single
env, free-tier compute. No Front Door / App Gateway / managed DBs / Key Vault.

Sequence (avoids the FQDN chicken-and-egg):
  1) Resource group + ACR + Managed Environment          (main.bicep)
  2) Container apps scaffolded (secrets wired)           (apps.bicep)
     - Docker-Hub stores (redis/postgres/mongo) come up healthy immediately.
     - ACR-backed apps get healthy once images are pushed (step 4).
  3) Build & push all images (serms-web is built with the REAL auth-proxy FQDN)
  4) Roll each ACR-backed app onto its image
  5) Print the front-door URL

PRE-REQUISITES
  - Azure CLI: az login
  - secrets.prod.json created from secrets.example.json and filled in
  - App repos already carry the deploy Dockerfiles this repo expects:
    serms  apps/web/Dockerfile.prod
    auth   deploy/nginx.Dockerfile
    ocr    Dockerfile.ollama

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
Write-Host "`n[1/5] Core infrastructure (ACR + Managed Environment)..." -ForegroundColor Green
az group create --name $Resource --location $Location --output none
az deployment group create `
    --resource-group $Resource `
    --name "capstone-infra" `
    --template-file (Join-Path $InfraRoot "infra\main.bicep") `
    --parameters location=$Location environmentName=$EnvironmentName acrName=$AcrName `
    --output none
if ($LASTEXITCODE -ne 0) { throw "Core infra deployment failed." }

# ---------------------------------------------------------------------------
# 2. Scaffold the container apps + secrets
# ---------------------------------------------------------------------------
Write-Host "`n[2/5] Deploying container apps (secrets wired)..." -ForegroundColor Green

$cfg = Get-Content -Raw (Join-Path $InfraRoot "infra\parameters.prod.json") | ConvertFrom-Json
$all = [ordered]@{}
$all["acrName"]         = $AcrName
$all["environmentName"] = $EnvironmentName
$all["location"]        = $Location
$all["imageTag"]        = $ImageTag
$all["minReplicas"]     = $MinReplicas
foreach ($k in @('supabaseUrl','supabaseBucket','supabaseRegion','supabaseEndpoint','brevoBaseUrl','brevoWebhookSecret','brevoWebhookHeader','vendorManagementUrl','authWebApiUrl')) {
    if ($null -ne $cfg.parameters.$k) { $all[$k] = $cfg.parameters.$k.value }
}
foreach ($p in $secrets.PSObject.Properties) { $all[$p.Name] = $p.Value }

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
# 3. Build & push images (now that auth-proxy FQDN is known)
# ---------------------------------------------------------------------------
$authProxyFqdn = (az containerapp show -n "auth-proxy" -g $Resource --query "properties.configuration.ingress.fqdn" -o tsv)
if (-not $authProxyFqdn) { throw "Could not resolve auth-proxy FQDN." }
Write-Host "`n[3/5] Building & pushing images (auth-proxy FQDN: $authProxyFqdn)..." -ForegroundColor Green

$builds = @(
    @{ Name = "$acrLoginServer/serms-api:$ImageTag";  Ctx = "$RepoRoot\smart-expense-management-system\apps\api";  Dockerfile = "Dockerfile";       Args = @() }
    @{ Name = "$acrLoginServer/serms-web:$ImageTag";  Ctx = "$RepoRoot\smart-expense-management-system\apps\web";  Dockerfile = "Dockerfile.prod";  Args = @("VITE_AUTH_MODULE_URL=https://$authProxyFqdn", "VITE_API_BASE_URL=") }
    @{ Name = "$acrLoginServer/auth-api:$ImageTag";   Ctx = "$RepoRoot\capstone-auth-module\auth-service";         Dockerfile = "Dockerfile";          Args = @() }
    @{ Name = "$acrLoginServer/auth-web:$ImageTag";   Ctx = "$RepoRoot\capstone-auth-module\web-interface";        Dockerfile = "Dockerfile";          Args = @() }
    @{ Name = "$acrLoginServer/auth-proxy:$ImageTag"; Ctx = "$RepoRoot\capstone-auth-module";                     Dockerfile = "deploy\nginx.Dockerfile"; Args = @() }
    @{ Name = "$acrLoginServer/ocr-api:$ImageTag";    Ctx = "$RepoRoot\ocr-pipeline";                             Dockerfile = "Dockerfile";          Args = @() }
    @{ Name = "$acrLoginServer/ocr-ollama:$ImageTag"; Ctx = "$RepoRoot\ocr-pipeline";                             Dockerfile = "Dockerfile.ollama";   Args = @() }
    @{ Name = "$acrLoginServer/mysql-init:$ImageTag"; Ctx = (Join-Path $InfraRoot "containers\mysql");            Dockerfile = "Dockerfile";          Args = @() }
)

$n = 0
foreach ($b in $builds) {
    $n++
    Write-Host "  ($n/$($builds.Count)) $($b.Dockerfile) -> $($b.Name)" -ForegroundColor Yellow
    $argList = @("build","--registry",$AcrName,"--image",$b.Name,"--file",$b.Dockerfile,"--context",$b.Ctx)
    foreach ($a in $b.Args) { $argList += @("--build-arg", $a) }
    az @argList --output none
    if ($LASTEXITCODE -ne 0) { throw "Build failed for $($b.Name)" }
}

# ---------------------------------------------------------------------------
# 4. Roll each ACR-backed app onto its freshly pushed image
# ---------------------------------------------------------------------------
Write-Host "`n[4/5] Rolling apps onto images..." -ForegroundColor Green
$rolls = @(
    @{ App = "auth-proxy";    Img = "$acrLoginServer/auth-proxy:$ImageTag" }
    @{ App = "auth-web";      Img = "$acrLoginServer/auth-web:$ImageTag" }
    @{ App = "auth-api";      Img = "$acrLoginServer/auth-api:$ImageTag" }
    @{ App = "auth-worker";   Img = "$acrLoginServer/auth-api:$ImageTag" }
    @{ App = "serms-web";     Img = "$acrLoginServer/serms-web:$ImageTag" }
    @{ App = "serms-api";     Img = "$acrLoginServer/serms-api:$ImageTag" }
    @{ App = "serms-worker";  Img = "$acrLoginServer/serms-api:$ImageTag" }
    @{ App = "ocr-api";       Img = "$acrLoginServer/ocr-api:$ImageTag" }
    @{ App = "ocr-worker";    Img = "$acrLoginServer/ocr-api:$ImageTag" }
    @{ App = "ocr-ollama";    Img = "$acrLoginServer/ocr-ollama:$ImageTag" }
    @{ App = "shared-mysql";  Img = "$acrLoginServer/mysql-init:$ImageTag" }
)
foreach ($r in $rolls) {
    Write-Host "  rolling $($r.App)" -ForegroundColor DarkGray
    az containerapp update -n $r.App -g $Resource --image $r.Img --output none
    if ($LASTEXITCODE -ne 0) { throw "Roll failed for $($r.App)" }
}

# ---------------------------------------------------------------------------
# 5. Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== DEPLOYED ===" -ForegroundColor Green
Write-Host "SERMS (front door /serms): https://$authProxyFqdn/serms"
Write-Host "Auth admin (/)           : https://$authProxyFqdn"
Write-Host ""
Write-Host "Next: warm the stack (first Ollama model pull takes minutes), seed a"
Write-Host "demo user in the auth API, then present. Then ALWAYS tear down:" -ForegroundColor Yellow
Write-Host "  .\scripts\teardown.ps1 -Resource $Resource"