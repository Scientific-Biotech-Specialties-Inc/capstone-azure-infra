// apps.bicep — Modular orchestrator for all capstone microservices & subgroups

@description('Region — must match the Managed Environment region.')
param location string

@description('Managed Environment name (see main.bicep).')
param environmentName string

@description('ACR name (optional if using GHCR).')
param acrName string = ''

@description('Registry mode: ghcr or acr.')
param registryMode string = 'ghcr'

@description('GHCR organization or ACR login server.')
param registryServer string = ''

@description('Registry username (optional for public GHCR, required for private/ACR).')
param registryUser string = ''

@secure()
@description('Registry password or GitHub PAT.')
param registryPassword string = ''

@description('Image tag to deploy. Default latest.')
param imageTag string = 'latest'

@description('Image tag for CMS images. Set to the published CMS commit SHA for bootstrap.')
param cmsImageTag string = imageTag

@description('Minimum replicas for Web/API apps. 0 = serverless scale-to-zero, 1 = warm.')
param minReplicas int = 0

// ---------------------------------------------------------------------------
// Module activation flags
// ---------------------------------------------------------------------------
param deployStores bool = true
param deployAuth bool = true
param deploySerms bool = true
param deployOcr bool = true
param deployPrs bool = false
param deployCms bool = false
param deployTicketing bool = false

// ---------------------------------------------------------------------------
// Secure secrets
// ---------------------------------------------------------------------------
@secure()
param mysqlRootPassword string
@secure()
param postgresPassword string
@secure()
param jwtSecret string
@secure()
param internalEncryptionKey string
@secure()
param sermsAppKey string = ''
@secure()
param authAppKey string = ''
@secure()
param supabaseAccessKey string = ''
@secure()
param supabaseSecretKey string = ''
@secure()
param aiServiceApiKey string = ''
@secure()
param prsApiKey string = ''
@secure()
param brevoApiKey string = ''
@secure()
param mailPassword string = ''
@secure()
param brevoWebhookSecret string = ''
@secure()
param cmsAppKey string = ''
@secure()
param cmsFieldEncryptionKey string = ''
@secure()
param cmsPostgresPassword string = ''
@secure()
param cmsMeilisearchKey string = ''

// ---------------------------------------------------------------------------
// External / Third-party non-secret configuration
// ---------------------------------------------------------------------------
param supabaseUrl string = ''
param supabaseBucket string = ''
param supabaseRegion string = ''
param supabaseEndpoint string = ''
param brevoBaseUrl string = 'https://api.brevo.com/v3'
param brevoWebhookHeader string = 'X-Brevo-Webhook-Secret'
param mailFromAddress string = 'noreply@capstone.local'
param mailFromName string = 'Capstone Auth'
param vendorManagementUrl string = ''
param cmsPostgresUsername string = ''
param cmsMeilisearchUrl string = ''
param externalAuthUrl string = 'https://auth-proxy.ashyisland-db3cde0b.eastasia.azurecontainerapps.io'

// ---------------------------------------------------------------------------
// External subgroup URLs (used when subgroups are deployed on other subscriptions)
// ---------------------------------------------------------------------------
param externalSermsWebUrl string = ''
param externalSermsApiUrl string = ''
param externalPrsWebUrl string = ''
param externalPrsApiUrl string = ''
param externalCmsWebUrl string = ''
param externalCmsVendorUrl string = ''
param externalCmsContractUrl string = ''
param externalCmsSearchUrl string = ''
param externalCmsNotificationUrl string = ''
param externalCmsAiUrl string = ''
param externalCmsAnalyticsUrl string = ''
param externalTicketingWebUrl string = ''
param externalTicketingGatewayUrl string = ''

// External database hosts (used if deploying without local stores)
param externalMysqlHost string = ''
param externalRedisHost string = ''
param externalPostgresHost string = ''
param externalMongoHost string = ''

// ---------------------------------------------------------------------------
// Shared references
// ---------------------------------------------------------------------------
resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: environmentName
}

// Compute image prefix
var imgPrefix = registryMode == 'acr' && !empty(acrName) ? '${acrName}.azurecr.io/' : (!empty(registryServer) ? '${registryServer}/' : '')
var cleanRegistryServer = !empty(registryServer) ? split(registryServer, '/')[0] : ''

// ---------------------------------------------------------------------------
// 1. Data Stores Module (Shared MySQL, Redis, Postgres, MongoDB)
// ---------------------------------------------------------------------------
module stores 'modules/stores.bicep' = if (deployStores) {
  name: 'stores-deploy'
  params: {
    location: location
    managedEnvironmentId: managedEnvironment.id
    minReplicas: 1 // Data stores keep 1 replica while active to retain in-memory state
    registryServer: registryMode == 'acr' ? cleanRegistryServer : ''
    registryUser: registryMode == 'acr' ? registryUser : ''
    registryPassword: registryMode == 'acr' ? registryPassword : ''
    mysqlRootPassword: mysqlRootPassword
    postgresPassword: postgresPassword
    mysqlImage: registryMode == 'acr' ? '${imgPrefix}mysql-init:${imageTag}' : 'docker.io/library/mysql:8.0'
  }
}

var activeMysqlHost = deployStores ? stores!.outputs.mysqlFqdn : externalMysqlHost
var activeRedisHost = deployStores ? stores!.outputs.redisFqdn : externalRedisHost
var activePostgresHost = deployStores ? stores!.outputs.postgresFqdn : externalPostgresHost
var activeMongoHost = deployStores ? stores!.outputs.mongoFqdn : externalMongoHost

// ---------------------------------------------------------------------------
// 2. SERMS Module
// ---------------------------------------------------------------------------
module serms 'modules/serms.bicep' = if (deploySerms) {
  name: 'serms-deploy'
  params: {
    location: location
    managedEnvironmentId: managedEnvironment.id
    minReplicas: minReplicas
    registryServer: cleanRegistryServer
    registryUser: registryUser
    registryPassword: registryPassword
    sermsWebImage: '${imgPrefix}serms-web:${imageTag}'
    sermsApiImage: '${imgPrefix}serms-api:${imageTag}'
    sermsAppKey: sermsAppKey
    mysqlPassword: mysqlRootPassword
    jwtSecret: jwtSecret
    aiServiceApiKey: aiServiceApiKey
    supabaseAccessKey: supabaseAccessKey
    supabaseSecretKey: supabaseSecretKey
    mysqlHost: activeMysqlHost
    redisHost: activeRedisHost
    authServiceUrl: 'http://auth-api'
    aiServiceUrl: 'http://ocr-api'
    supabaseUrl: supabaseUrl
    supabaseRegion: supabaseRegion
    supabaseBucket: supabaseBucket
    supabaseEndpoint: supabaseEndpoint
  }
}

// ---------------------------------------------------------------------------
// 3. OCR Pipeline Module
// ---------------------------------------------------------------------------
module ocr 'modules/ocr.bicep' = if (deployOcr) {
  name: 'ocr-deploy'
  params: {
    location: location
    managedEnvironmentId: managedEnvironment.id
    minReplicas: minReplicas
    registryServer: cleanRegistryServer
    registryUser: registryUser
    registryPassword: registryPassword
    ocrApiImage: '${imgPrefix}ocr-api:${imageTag}'
    ocrWorkerImage: '${imgPrefix}ocr-api:${imageTag}'
    ocrOllamaImage: 'docker.io/ollama/ollama:latest'
    sermsApiKey: aiServiceApiKey
    prsApiKey: prsApiKey
    postgresPassword: postgresPassword
    redisHost: activeRedisHost
    postgresHost: activePostgresHost
    mongoHost: activeMongoHost
  }
}

// ---------------------------------------------------------------------------
// 4. PRS Module
// ---------------------------------------------------------------------------
module prs 'modules/prs.bicep' = if (deployPrs) {
  name: 'prs-deploy'
  params: {
    location: location
    managedEnvironmentId: managedEnvironment.id
    minReplicas: minReplicas
    registryServer: cleanRegistryServer
    registryUser: registryUser
    registryPassword: registryPassword
    prsWebImage: '${imgPrefix}prs-web:${imageTag}'
    prsApiImage: '${imgPrefix}prs-api:${imageTag}'
    mysqlPassword: mysqlRootPassword
    jwtSecret: jwtSecret
    prsApiKey: prsApiKey
    mysqlHost: activeMysqlHost
    redisHost: activeRedisHost
    authServiceUrl: 'http://auth-api'
    ocrServiceUrl: 'http://ocr-api'
  }
}

// ---------------------------------------------------------------------------
// 5. CMS Module
// ---------------------------------------------------------------------------
module cms 'modules/cms.bicep' = if (deployCms) {
  name: 'cms-deploy'
  params: {
    location: location
    managedEnvironmentId: managedEnvironment.id
    minReplicas: minReplicas
    registryServer: cleanRegistryServer
    registryUser: registryUser
    registryPassword: registryPassword
    cmsWebImage: '${imgPrefix}cms-web:${cmsImageTag}'
    cmsBackendImagePrefix: imgPrefix
    cmsBackendImageTag: cmsImageTag
    mysqlPassword: mysqlRootPassword
    jwtSecret: jwtSecret
    internalServiceSecret: internalEncryptionKey
    appKey: !empty(cmsAppKey) ? cmsAppKey : 'base64:c1NtUjM1UGxhY2Vob2xkZXJLZXkxMjM0NTY3ODkwMTI='
    fieldEncryptionKey: !empty(cmsFieldEncryptionKey) ? cmsFieldEncryptionKey : internalEncryptionKey
    postgresPassword: !empty(cmsPostgresPassword) ? cmsPostgresPassword : postgresPassword
    meilisearchKey: !empty(cmsMeilisearchKey) ? cmsMeilisearchKey : internalEncryptionKey
    mysqlHost: activeMysqlHost
    redisHost: activeRedisHost
    postgresHost: activePostgresHost
    postgresUsername: !empty(cmsPostgresUsername) ? cmsPostgresUsername : 'ocr_user'
    mongoHost: activeMongoHost
    meilisearchUrl: cmsMeilisearchUrl
    authServiceUrl: deployAuth ? 'http://auth-api/api' : '${externalAuthUrl}/api'
    defaultDomain: managedEnvironment.properties.defaultDomain
  }
}

// ---------------------------------------------------------------------------
// 6. Ticketing Module
// ---------------------------------------------------------------------------
module ticketing 'modules/ticketing.bicep' = if (deployTicketing) {
  name: 'ticketing-deploy'
  params: {
    location: location
    managedEnvironmentId: managedEnvironment.id
    minReplicas: minReplicas
    registryServer: cleanRegistryServer
    registryUser: registryUser
    registryPassword: registryPassword
    ticketingWebImage: '${imgPrefix}ticketing-web:${imageTag}'
    ticketingGatewayImage: '${imgPrefix}ticketing-gateway:${imageTag}'
    mysqlPassword: mysqlRootPassword
    jwtSecret: jwtSecret
    mysqlHost: activeMysqlHost
    redisHost: activeRedisHost
    authServiceUrl: 'http://auth-api'
  }
}

// ---------------------------------------------------------------------------
// 7. Central Auth Module & Nginx Gateway Front Door
// ---------------------------------------------------------------------------
var routedSermsWebUrl = deploySerms ? 'http://${serms!.outputs.sermsWebFqdn}' : externalSermsWebUrl
var routedSermsApiUrl = deploySerms ? 'http://${serms!.outputs.sermsApiFqdn}' : externalSermsApiUrl
var routedPrsWebUrl = deployPrs ? 'http://${prs!.outputs.prsWebFqdn}' : externalPrsWebUrl
var routedPrsApiUrl = deployPrs ? 'http://${prs!.outputs.prsApiFqdn}' : externalPrsApiUrl
var routedCmsWebUrl = deployCms ? 'http://${cms!.outputs.cmsWebFqdn}' : externalCmsWebUrl
var routedCmsVendorUrl = deployCms ? 'http://${cms!.outputs.vendorManagementFqdn}' : externalCmsVendorUrl
var routedCmsContractUrl = deployCms ? 'http://${cms!.outputs.contractManagementFqdn}' : externalCmsContractUrl
var routedCmsSearchUrl = deployCms ? 'http://${cms!.outputs.searchFqdn}' : externalCmsSearchUrl
var routedCmsNotificationUrl = deployCms ? 'http://${cms!.outputs.notificationFqdn}' : externalCmsNotificationUrl
var routedCmsAiUrl = deployCms ? 'http://${cms!.outputs.aiServiceFqdn}' : externalCmsAiUrl
var routedCmsAnalyticsUrl = deployCms ? 'http://${cms!.outputs.analyticsServiceFqdn}' : externalCmsAnalyticsUrl
var routedTicketingWebUrl = deployTicketing ? 'http://${ticketing!.outputs.ticketingWebFqdn}' : externalTicketingWebUrl
var routedTicketingGatewayUrl = deployTicketing ? 'http://${ticketing!.outputs.ticketingGatewayFqdn}' : externalTicketingGatewayUrl

module auth 'modules/auth.bicep' = if (deployAuth) {
  name: 'auth-deploy'
  params: {
    location: location
    managedEnvironmentId: managedEnvironment.id
    minReplicas: minReplicas
    registryServer: cleanRegistryServer
    registryUser: registryUser
    registryPassword: registryPassword
    authProxyImage: '${imgPrefix}auth-proxy:${imageTag}'
    authWebImage: '${imgPrefix}auth-web:${imageTag}'
    authApiImage: '${imgPrefix}auth-api:${imageTag}'
    authAppKey: authAppKey
    mysqlPassword: mysqlRootPassword
    internalEncryptionKey: internalEncryptionKey
    mailPassword: mailPassword
    brevoApiKey: brevoApiKey
    mysqlHost: activeMysqlHost
    redisHost: activeRedisHost
    brevoBaseUrl: brevoBaseUrl
    brevoWebhookSecret: brevoWebhookSecret
    brevoWebhookHeader: brevoWebhookHeader
    mailFromAddress: mailFromAddress
    mailFromName: mailFromName
    vendorManagementUrl: vendorManagementUrl
    sermsWebUrl: routedSermsWebUrl
    sermsApiUrl: routedSermsApiUrl
    prsWebUrl: routedPrsWebUrl
    prsApiUrl: routedPrsApiUrl
    cmsWebUrl: routedCmsWebUrl
    cmsVendorUrl: routedCmsVendorUrl
    cmsContractUrl: routedCmsContractUrl
    cmsSearchUrl: routedCmsSearchUrl
    cmsNotificationUrl: routedCmsNotificationUrl
    cmsAiUrl: routedCmsAiUrl
    cmsAnalyticsUrl: routedCmsAnalyticsUrl
    ticketingWebUrl: routedTicketingWebUrl
    ticketingGatewayUrl: routedTicketingGatewayUrl
  }
}

output authProxyFqdn string = deployAuth ? auth!.outputs.authProxyFqdn : ''
output authApiFqdn string = deployAuth ? auth!.outputs.authApiFqdn : ''
output authWebFqdn string = deployAuth ? auth!.outputs.authWebFqdn : ''
output sermsWebFqdn string = deploySerms ? serms!.outputs.sermsWebFqdn : externalSermsWebUrl
output sermsApiFqdn string = deploySerms ? serms!.outputs.sermsApiFqdn : externalSermsApiUrl
output prsWebFqdn string = deployPrs ? prs!.outputs.prsWebFqdn : externalPrsWebUrl
output prsApiFqdn string = deployPrs ? prs!.outputs.prsApiFqdn : externalPrsApiUrl
output cmsWebFqdn string = deployCms ? cms!.outputs.cmsWebFqdn : externalCmsWebUrl
output vendorManagementFqdn string = deployCms ? cms!.outputs.vendorManagementFqdn : externalCmsVendorUrl
output contractManagementFqdn string = deployCms ? cms!.outputs.contractManagementFqdn : externalCmsContractUrl
output searchFqdn string = deployCms ? cms!.outputs.searchFqdn : externalCmsSearchUrl
output notificationFqdn string = deployCms ? cms!.outputs.notificationFqdn : externalCmsNotificationUrl
output aiServiceFqdn string = deployCms ? cms!.outputs.aiServiceFqdn : externalCmsAiUrl
output analyticsServiceFqdn string = deployCms ? cms!.outputs.analyticsServiceFqdn : externalCmsAnalyticsUrl
output ticketingWebFqdn string = deployTicketing ? ticketing!.outputs.ticketingWebFqdn : externalTicketingWebUrl
