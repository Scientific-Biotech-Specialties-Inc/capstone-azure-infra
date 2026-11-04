<#
.SYNOPSIS
Deploy and orchestrate capstone microservices and subgroup projects to Azure Container Apps.

Supports:
  - Multi-account Azure for Students ($100 credit) rotation
  - Subgroup self-service deployment (Mode 1: -Module prs, -Module cms, -Module ticketing)
  - True serverless scale-to-zero (-ScaleMode Serverless) or pre-warmed demo (-ScaleMode WarmDemo)
  - GHCR (free, no local builds) or ACR with local Docker build fallback (-RegistryMode ghcr|acr)
  - Fast gateway sync (-SyncProxy) to rewire front door in seconds

.EXAMPLE
  .\scripts\deploy.ps1 -Module core -ScaleMode Serverless
  .\scripts\deploy.ps1 -Module prs -ScaleMode Serverless
  .\scripts\deploy.ps1 -SyncProxy
  .\scripts\deploy.ps1 -SwitchAccount
#>
param(
    [ValidateSet("core", "auth", "serms", "ocr", "prs", "cms", "ticketing", "all")]
    [string[]]$Module = @("core"),

    [ValidateSet("ghcr", "acr")]
    [string]$RegistryMode = "ghcr",

    [ValidateSet("Serverless", "WarmDemo")]
    [string]$ScaleMode = "Serverless",

    [switch]$SwitchAccount,
    [switch]$UseDeviceCode,
    [switch]$SyncProxy,
    [switch]$DryRun,

    [string]$ConfigFile = "",
    [string]$SecretsFile = "",
    [string]$RepoRoot = "C:\Projects",
    [string]$Sub = "",
    [string]$Resource = "",
    [string]$Location = "",
    [string]$EnvironmentName = "",
    [string]$ImageTag = "",
    [int]$MinReplicas = -1
)

$ErrorActionPreference = "Stop"
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}
$InfraRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

# --------------------------------------------------------------------------
# 0. Pre-flight & Account Resolution
# --------------------------------------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI not found. Install from https://aka.ms/install-azure-cli"
}

if ($SwitchAccount) {
    Write-Host "`n=== Azure Account Switch ===" -ForegroundColor Cyan
    if ($UseDeviceCode) {
        az login --use-device-code
    } else {
        az login
    }
}

$accountJson = $null
try {
    $accountJson = az account show -o json 2>$null
} catch {
    $accountJson = $null
}

if (-not $accountJson) {
    Write-Host "No active Azure login session. Starting az login..." -ForegroundColor Yellow
    if ($UseDeviceCode) { az login --use-device-code } else { az login }
    $accountJson = az account show -o json
}
$ctx = $accountJson | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($Sub)) { $Sub = $ctx.id }
az account set --subscription $Sub
Write-Host "Active Subscription: $($ctx.name) ($($ctx.id))" -ForegroundColor Magenta
Write-Host "Account User:        $($ctx.user.name)" -ForegroundColor DarkGray

# --------------------------------------------------------------------------
# 1. Config & Secrets Ingestion
# --------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
    $ConfigFile = Join-Path $InfraRoot "config\deploy.config.json"
}
if (-not (Test-Path $ConfigFile)) {
    throw "Missing config file: $ConfigFile"
}
$cfg = Get-Content -Raw $ConfigFile | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($SecretsFile)) {
    $SecretsFile = Join-Path $InfraRoot "secrets.prod.json"
}
if (-not (Test-Path $SecretsFile)) {
    throw "Missing $SecretsFile. Copy secrets.example.json -> secrets.prod.json and fill in values."
}
$secrets = Get-Content -Raw $SecretsFile | ConvertFrom-Json

# Derive default variables from config if not passed as CLI args
if ([string]::IsNullOrWhiteSpace($Resource))        { $Resource = if ($cfg.resourceGroup) { $cfg.resourceGroup } else { "rg-capstone" } }
if ([string]::IsNullOrWhiteSpace($Location))        { $Location = if ($cfg.location) { $cfg.location } else { "eastus" } }
if ([string]::IsNullOrWhiteSpace($EnvironmentName)) { $EnvironmentName = if ($cfg.environmentName) { $cfg.environmentName } else { "capstone-env" } }
if ([string]::IsNullOrWhiteSpace($ImageTag))        { $ImageTag = if ($cfg.registry.imageTag) { $cfg.registry.imageTag } else { "latest" } }
if ($MinReplicas -lt 0) {
    $MinReplicas = if ($ScaleMode -eq "WarmDemo") { 1 } else { 0 }
}

# Auto-register Azure resource providers if not registered
$providers = @("Microsoft.App", "Microsoft.ContainerRegistry", "Microsoft.OperationalInsights", "Microsoft.Storage")
foreach ($p in $providers) {
    $regState = (az provider show -n $p --query "registrationState" -o tsv 2>$null)
    if ($regState -ne "Registered") {
        Write-Host "Registering resource provider $p..." -ForegroundColor Yellow
        az provider register -n $p --output none
    }
}

# Determine module flags
$deployStores    = $false
$deployAuth      = $false
$deploySerms     = $false
$deployOcr       = $false
$deployPrs       = $false
$deployCms       = $false
$deployTicketing = $false

if ($Module -contains "all") {
    $deployStores = $deployAuth = $deploySerms = $deployOcr = $deployPrs = $deployCms = $deployTicketing = $true
} elseif ($Module -contains "core") {
    $deployStores = $deployAuth = $deploySerms = $deployOcr = $true
} else {
    if ($Module -contains "auth")      { $deployAuth = $true }
    if ($Module -contains "serms")     { $deploySerms = $true }
    if ($Module -contains "ocr")       { $deployOcr = $true }
    if ($Module -contains "prs")       { $deployPrs = $true }
    if ($Module -contains "cms")       { $deployCms = $true }
    if ($Module -contains "ticketing") { $deployTicketing = $true }
}

Write-Host "`nTarget Profile: RG=$Resource | Env=$EnvironmentName | Loc=$Location | Mode=$ScaleMode (minReplicas=$MinReplicas)" -ForegroundColor Cyan
Write-Host "Active Modules: Stores=$deployStores | Auth=$deployAuth | SERMS=$deploySerms | OCR=$deployOcr | PRS=$deployPrs | CMS=$deployCms | TS=$deployTicketing" -ForegroundColor DarkCyan

if ($DryRun) {
    Write-Host "`n[DRY RUN] Configuration validated successfully. Exiting." -ForegroundColor Green
    return
}

# --------------------------------------------------------------------------
# Quick Path: -SyncProxy (Update auth-proxy upstream URLs only)
# --------------------------------------------------------------------------
if ($SyncProxy) {
    Write-Host "`n[SyncProxy] Updating auth-proxy upstream routing rules..." -ForegroundColor Green
    $subgroups = $cfg.subgroups
    az containerapp update -n "auth-proxy" -g $Resource --set-env-vars `
        "PRS_WEB_URL=$(if ($subgroups.prs.webUrl) { $subgroups.prs.webUrl } else { 'http://127.0.0.1:59999' })" `
        "PRS_API_URL=$(if ($subgroups.prs.apiUrl) { $subgroups.prs.apiUrl } else { 'http://127.0.0.1:59999' })" `
        "CMS_WEB_URL=$(if ($subgroups.cms.webUrl) { $subgroups.cms.webUrl } else { 'http://127.0.0.1:59999' })" `
        "CMS_VENDOR_URL=$(if ($subgroups.cms.vendorUrl) { $subgroups.cms.vendorUrl } else { 'http://127.0.0.1:59999' })" `
        "CMS_CONTRACT_URL=$(if ($subgroups.cms.contractUrl) { $subgroups.cms.contractUrl } else { 'http://127.0.0.1:59999' })" `
        "CMS_SEARCH_URL=$(if ($subgroups.cms.searchUrl) { $subgroups.cms.searchUrl } else { 'http://127.0.0.1:59999' })" `
        "CMS_NOTIFICATION_URL=$(if ($subgroups.cms.notificationUrl) { $subgroups.cms.notificationUrl } else { 'http://127.0.0.1:59999' })" `
        "CMS_AI_URL=$(if ($subgroups.cms.aiUrl) { $subgroups.cms.aiUrl } else { 'http://127.0.0.1:59999' })" `
        "CMS_ANALYTICS_URL=$(if ($subgroups.cms.analyticsUrl) { $subgroups.cms.analyticsUrl } else { 'http://127.0.0.1:59999' })" `
        "TICKETING_WEB_URL=$(if ($subgroups.ticketing.webUrl) { $subgroups.ticketing.webUrl } else { 'http://127.0.0.1:59999' })" `
        "TICKETING_GATEWAY_URL=$(if ($subgroups.ticketing.gatewayUrl) { $subgroups.ticketing.gatewayUrl } else { 'http://127.0.0.1:59999' })" `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "SyncProxy failed." }
    Write-Host "[SyncProxy] auth-proxy upstream routes re-synchronized successfully!" -ForegroundColor Green
    return
}

# --------------------------------------------------------------------------
# 2. Deploy Core Infrastructure (main.bicep)
# --------------------------------------------------------------------------
Write-Host "`n[1/4] Core infrastructure (Resource Group + Environment + Storage)..." -ForegroundColor Green
az group create --name $Resource --location $Location --output none

$deployAcr = ($RegistryMode -eq "acr")
$coreDeploy = az deployment group create `
    --resource-group $Resource `
    --name "capstone-core-infra" `
    --template-file (Join-Path $InfraRoot "infra\main.bicep") `
    --parameters location=$Location environmentName=$EnvironmentName deployAcr=$deployAcr deployStorage=$true `
    --query "properties.outputs" -o json | ConvertFrom-Json

if ($LASTEXITCODE -ne 0) { throw "Core infra deployment failed." }

$acrName = if ($coreDeploy.acrName) { $coreDeploy.acrName.value } else { "" }
$regServer = if ($RegistryMode -eq "ghcr") { $cfg.registry.ghcrOrg } else { "$acrName.azurecr.io" }
$regUser = if ($RegistryMode -eq "ghcr") { if ($secrets.ghcrUsername) { $secrets.ghcrUsername } else { "" } } else { "" }
$regPass = if ($RegistryMode -eq "ghcr") { if ($secrets.ghcrToken) { $secrets.ghcrToken } else { "" } } else { "" }

# --------------------------------------------------------------------------
# 3. Deploy Container Apps (apps.bicep)
# --------------------------------------------------------------------------
Write-Host "`n[2/4] Deploying Container Apps (Module: $($Module -join ',')) with minReplicas=$MinReplicas..." -ForegroundColor Green

$allParams = [ordered]@{}
$allParams["location"]        = $Location
$allParams["environmentName"] = $EnvironmentName
$allParams["imageTag"]        = $ImageTag
$allParams["minReplicas"]     = $MinReplicas
$allParams["registryMode"]    = $RegistryMode
$allParams["registryServer"]  = $regServer
$allParams["registryUser"]    = $regUser
$allParams["registryPassword"]= $regPass
$allParams["acrName"]         = $acrName

# Module switches
$allParams["deployStores"]    = $deployStores
$allParams["deployAuth"]      = $deployAuth
$allParams["deploySerms"]     = $deploySerms
$allParams["deployOcr"]       = $deployOcr
$allParams["deployPrs"]       = $deployPrs
$allParams["deployCms"]       = $deployCms
$allParams["deployTicketing"] = $deployTicketing

# External Subgroup URLs from config
$sub = $cfg.subgroups
$allParams["externalSermsWebUrl"]          = if ($sub.serms.webUrl) { $sub.serms.webUrl } else { "" }
$allParams["externalSermsApiUrl"]          = if ($sub.serms.apiUrl) { $sub.serms.apiUrl } else { "" }
$allParams["externalPrsWebUrl"]            = if ($sub.prs.webUrl) { $sub.prs.webUrl } else { "" }
$allParams["externalPrsApiUrl"]            = if ($sub.prs.apiUrl) { $sub.prs.apiUrl } else { "" }
$allParams["externalCmsWebUrl"]            = if ($sub.cms.webUrl) { $sub.cms.webUrl } else { "" }
$allParams["externalCmsVendorUrl"]         = if ($sub.cms.vendorUrl) { $sub.cms.vendorUrl } else { "" }
$allParams["externalCmsContractUrl"]       = if ($sub.cms.contractUrl) { $sub.cms.contractUrl } else { "" }
$allParams["externalCmsSearchUrl"]         = if ($sub.cms.searchUrl) { $sub.cms.searchUrl } else { "" }
$allParams["externalCmsNotificationUrl"]   = if ($sub.cms.notificationUrl) { $sub.cms.notificationUrl } else { "" }
$allParams["externalCmsAiUrl"]             = if ($sub.cms.aiUrl) { $sub.cms.aiUrl } else { "" }
$allParams["externalCmsAnalyticsUrl"]      = if ($sub.cms.analyticsUrl) { $sub.cms.analyticsUrl } else { "" }
$allParams["externalTicketingWebUrl"]      = if ($sub.ticketing.webUrl) { $sub.ticketing.webUrl } else { "" }
$allParams["externalTicketingGatewayUrl"]  = if ($sub.ticketing.gatewayUrl) { $sub.ticketing.gatewayUrl } else { "" }

# Third party configs
$ext = $cfg.externalServices
$allParams["supabaseUrl"]        = if ($ext.supabaseUrl) { $ext.supabaseUrl } else { "" }
$allParams["supabaseBucket"]     = if ($ext.supabaseBucket) { $ext.supabaseBucket } else { "" }
$allParams["supabaseRegion"]     = if ($ext.supabaseRegion) { $ext.supabaseRegion } else { "" }
$allParams["supabaseEndpoint"]   = if ($ext.supabaseEndpoint) { $ext.supabaseEndpoint } else { "" }
$allParams["brevoBaseUrl"]       = if ($ext.brevoBaseUrl) { $ext.brevoBaseUrl } else { "https://api.brevo.com/v3" }
$allParams["brevoWebhookHeader"] = if ($ext.brevoWebhookHeader) { $ext.brevoWebhookHeader } else { "X-Brevo-Webhook-Secret" }

# Ingest secrets
foreach ($p in $secrets.PSObject.Properties) {
    if (-not $p.Name.StartsWith('//')) { $allParams[$p.Name] = $p.Value }
}

$inner = @{}
foreach ($k in $allParams.Keys) { $inner[$k] = @{ value = $allParams[$k] } }
$paramFile = Join-Path $env:TEMP "capstone-apps-params.json"
@{ parameters = $inner } | ConvertTo-Json -Depth 8 | Set-Content -Path $paramFile -Encoding utf8

$appsDeploy = az deployment group create `
    --resource-group $Resource `
    --name "capstone-apps-deploy" `
    --template-file (Join-Path $InfraRoot "infra\apps.bicep") `
    --parameters "@$paramFile" `
    --query "properties.outputs" -o json | ConvertFrom-Json

if ($LASTEXITCODE -ne 0) { throw "Container apps deployment failed." }

# --------------------------------------------------------------------------
# 4. Local Build & Push (Only if RegistryMode is ACR)
# --------------------------------------------------------------------------
if ($RegistryMode -eq "acr") {
    Write-Host "`n[3/4] Building & pushing images locally to $acrName.azurecr.io..." -ForegroundColor Yellow
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker Desktop required for ACR local build mode."
    }
    az acr login --name $acrName

    # Build and roll apps onto freshly pushed images
    # ...
} else {
    Write-Host "`n[3/4] Pulled pre-built images from $regServer (zero build time, zero local upload)." -ForegroundColor Green
}

# --------------------------------------------------------------------------
# 5. Extract FQDNs & Update Subgroups Registry
# --------------------------------------------------------------------------
Write-Host "`n[4/4] Verifying and recording deployed endpoints..." -ForegroundColor Green

$fqdns = @{}
if ($deployAuth -and $appsDeploy.authProxyFqdn) {
    $fqdns["authProxy"] = "https://$($appsDeploy.authProxyFqdn.value)"
    $fqdns["authWeb"]   = "http://$($appsDeploy.authWebFqdn.value)"
    $fqdns["authApi"]   = "http://$($appsDeploy.authApiFqdn.value)"
}
if ($deploySerms -and $appsDeploy.sermsWebFqdn) {
    $fqdns["sermsWeb"] = "http://$($appsDeploy.sermsWebFqdn.value)"
    $fqdns["sermsApi"] = "http://$($appsDeploy.sermsApiFqdn.value)"
    $cfg.subgroups.serms.webUrl = $fqdns["sermsWeb"]
    $cfg.subgroups.serms.apiUrl = $fqdns["sermsApi"]
}
if ($deployPrs -and $appsDeploy.prsWebFqdn) {
    $fqdns["prsWeb"] = "http://$($appsDeploy.prsWebFqdn.value)"
    $fqdns["prsApi"] = "http://$($appsDeploy.prsApiFqdn.value)"
    $cfg.subgroups.prs.webUrl = $fqdns["prsWeb"]
    $cfg.subgroups.prs.apiUrl = $fqdns["prsApi"]
}
if ($deployCms -and $appsDeploy.cmsWebFqdn) {
    $fqdns["cmsWeb"] = "http://$($appsDeploy.cmsWebFqdn.value)"
    $cfg.subgroups.cms.webUrl = $fqdns["cmsWeb"]
}
if ($deployTicketing -and $appsDeploy.ticketingWebFqdn) {
    $fqdns["ticketingWeb"] = "http://$($appsDeploy.ticketingWebFqdn.value)"
    $cfg.subgroups.ticketing.webUrl = $fqdns["ticketingWeb"]
}

# Save updated config
$cfg | ConvertTo-Json -Depth 6 | Set-Content -Path $ConfigFile -Encoding utf8

Write-Host "`n=== DEPLOYMENT COMPLETED ===" -ForegroundColor Green
if ($fqdns.authProxy) {
    Write-Host "Front Door Gateway (Single URL) : $($fqdns.authProxy)" -ForegroundColor Cyan
    Write-Host "  - SERMS Module               : $($fqdns.authProxy)/serms"
    Write-Host "  - Auth Administration        : $($fqdns.authProxy)"
    Write-Host "  - PRS Module                 : $($fqdns.authProxy)/prs"
    Write-Host "  - CMS Module                 : $($fqdns.authProxy)/cms"
    Write-Host "  - Ticketing Module           : $($fqdns.authProxy)/ticketing"
} else {
    Write-Host "Subgroup Deployed Successfully!" -ForegroundColor Green
    foreach ($k in $fqdns.Keys) {
        Write-Host "  - $k : $($fqdns[$k])"
    }
    Write-Host "`nTo link these endpoints to the primary front door, commit config/deploy.config.json"
    Write-Host "and run: .\scripts\deploy.ps1 -SyncProxy" -ForegroundColor Yellow
}
Write-Host "`nUseful commands:" -ForegroundColor DarkGray
Write-Host "  Switch account : .\scripts\deploy.ps1 -SwitchAccount"
Write-Host "  Scale to zero  : .\scripts\scale.ps1 -Mode Serverless"
Write-Host "  Warm for demo  : .\scripts\scale.ps1 -Mode WarmDemo"
Write-Host "  Hibernate all  : .\scripts\scale.ps1 -Mode SleepAll"
Write-Host "  Teardown       : .\scripts\teardown.ps1 -Resource $Resource"