// auth.bicep — Central Auth Module + Nginx Gateway Front Door

@description('Region — must match the Managed Environment region.')
param location string

@description('Managed Environment ID.')
param managedEnvironmentId string

@description('Minimum replicas. 0 = serverless scale-to-zero, 1 = warm.')
param minReplicas int = 0

// ---------------------------------------------------------------------------
// Registry config
// ---------------------------------------------------------------------------
param registryServer string = ''
param registryUser string = ''
@secure()
param registryPassword string = ''

var hasRegistry = !empty(registryServer) && !empty(registryUser) && !empty(registryPassword)
var registryConfig = hasRegistry ? [
  {
    server: registryServer
    username: registryUser
    passwordSecretRef: 'reg-pass'
  }
] : []
var registrySecret = hasRegistry ? [
  { name: 'reg-pass', value: registryPassword }
] : []

// Images
param authProxyImage string
param authWebImage string
param authApiImage string

// Secrets
@secure()
param authAppKey string
@secure()
param mysqlPassword string
@secure()
param internalEncryptionKey string
@secure()
param mailPassword string = ''
@secure()
param brevoApiKey string = ''

// Service configs
param mysqlHost string
param mysqlPort string = '3306'
param redisHost string
param redisPort string = '6379'
param brevoBaseUrl string = 'https://api.brevo.com/v3'
@secure()
param brevoWebhookSecret string = ''
param brevoWebhookHeader string = 'X-Brevo-Webhook-Secret'
param mailFromAddress string = 'noreply@capstone.local'
param mailFromName string = 'Capstone Auth'
param vendorManagementUrl string = ''

// Subgroup URLs routed through auth-proxy
param sermsWebUrl string = ''
param sermsApiUrl string = ''
param prsWebUrl string = ''
param prsApiUrl string = ''
param cmsWebUrl string = ''
param cmsVendorUrl string = ''
param cmsContractUrl string = ''
param cmsSearchUrl string = ''
param cmsNotificationUrl string = ''
param cmsAiUrl string = ''
param cmsAnalyticsUrl string = ''
param ticketingWebUrl string = ''
param ticketingGatewayUrl string = ''

// ---------------------------------------------------------------------------
// PUBLIC FRONT DOOR — capstone-auth-module reverse proxy
// ---------------------------------------------------------------------------
resource authProxy 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'auth-proxy'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 5173
        transport: 'http'
        allowInsecure: false
      }
      registries: registryConfig
      secrets: registrySecret
    }
    template: {
      containers: [
        {
          name: 'auth-proxy'
          image: authProxyImage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'AUTH_WEB_URL', value: 'http://${authWeb.properties.configuration.ingress.fqdn}' }
            { name: 'AUTH_API_URL', value: 'http://${authApi.properties.configuration.ingress.fqdn}' }
            { name: 'SERMS_WEB_URL', value: !empty(sermsWebUrl) ? sermsWebUrl : 'http://127.0.0.1:59999' }
            { name: 'SERMS_API_URL', value: !empty(sermsApiUrl) ? sermsApiUrl : 'http://127.0.0.1:59999' }
            { name: 'PRS_WEB_URL', value: !empty(prsWebUrl) ? prsWebUrl : 'http://127.0.0.1:59999' }
            { name: 'PRS_API_URL', value: !empty(prsApiUrl) ? prsApiUrl : 'http://127.0.0.1:59999' }
            { name: 'CMS_WEB_URL', value: !empty(cmsWebUrl) ? cmsWebUrl : 'http://127.0.0.1:59999' }
            { name: 'CMS_VENDOR_URL', value: !empty(cmsVendorUrl) ? cmsVendorUrl : 'http://127.0.0.1:59999' }
            { name: 'CMS_CONTRACT_URL', value: !empty(cmsContractUrl) ? cmsContractUrl : 'http://127.0.0.1:59999' }
            { name: 'CMS_SEARCH_URL', value: !empty(cmsSearchUrl) ? cmsSearchUrl : 'http://127.0.0.1:59999' }
            { name: 'CMS_NOTIFICATION_URL', value: !empty(cmsNotificationUrl) ? cmsNotificationUrl : 'http://127.0.0.1:59999' }
            { name: 'CMS_AI_URL', value: !empty(cmsAiUrl) ? cmsAiUrl : 'http://127.0.0.1:59999' }
            { name: 'CMS_ANALYTICS_URL', value: !empty(cmsAnalyticsUrl) ? cmsAnalyticsUrl : 'http://127.0.0.1:59999' }
            { name: 'TICKETING_WEB_URL', value: !empty(ticketingWebUrl) ? ticketingWebUrl : 'http://127.0.0.1:59999' }
            { name: 'TICKETING_GATEWAY_URL', value: !empty(ticketingGatewayUrl) ? ticketingGatewayUrl : 'http://127.0.0.1:59999' }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: 3
        rules: [
          {
            name: 'http-scaler'
            http: { metadata: { concurrentRequests: '25' } }
          }
        ]
      }
    }
  }
}

// ---------------------------------------------------------------------------
// auth-web: Vue admin UI / login page
// ---------------------------------------------------------------------------
resource authWeb 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'auth-web'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 5000, transport: 'http', allowInsecure: true }
      registries: registryConfig
      secrets: concat(registrySecret, [
        { name: 'internal-encryption-key', value: internalEncryptionKey }
      ])
    }
    template: {
      containers: [
        {
          name: 'auth-web'
          image: authWebImage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'VITE_API_URL', value: 'http://${authApi.properties.configuration.ingress.fqdn}' }
            { name: 'VITE_INTERNAL_ENCRYPTION_KEY', secretRef: 'internal-encryption-key' }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: 2
        rules: [
          {
            name: 'http-scaler'
            http: { metadata: { concurrentRequests: '20' } }
          }
        ]
      }
    }
  }
}

// ---------------------------------------------------------------------------
// auth-api: Laravel REST API
// ---------------------------------------------------------------------------
resource authApi 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'auth-api'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 8000, transport: 'http', allowInsecure: true }
      registries: registryConfig
      secrets: concat(registrySecret, [
        { name: 'app-key', value: authAppKey }
        { name: 'db-password', value: mysqlPassword }
        { name: 'encryption-key', value: internalEncryptionKey }
        { name: 'internal-secret', value: internalEncryptionKey }
        { name: 'mail-password', value: mailPassword }
        { name: 'brevo-key', value: brevoApiKey }
      ])
    }
    template: {
      containers: [
        {
          name: 'auth-api'
          image: authApiImage
          resources: { cpu: json('0.5'), memory: '1.0Gi' }
          env: [
            { name: 'APP_ENV', value: 'production' }
            { name: 'APP_DEBUG', value: 'false' }
            { name: 'APP_KEY', secretRef: 'app-key' }
            { name: 'INTERNAL_ENCRYPTION_KEY', secretRef: 'encryption-key' }
            { name: 'DB_CONNECTION', value: 'mysql' }
            { name: 'DB_HOST', value: mysqlHost }
            { name: 'DB_PORT', value: mysqlPort }
            { name: 'DB_DATABASE', value: 'capstone_auth' }
            { name: 'DB_USERNAME', value: 'root' }
            { name: 'DB_PASSWORD', secretRef: 'db-password' }
            { name: 'REDIS_CLIENT', value: 'phpredis' }
            { name: 'REDIS_HOST', value: redisHost }
            { name: 'REDIS_PORT', value: redisPort }
            { name: 'REDIS_PASSWORD', value: '' }
            { name: 'CACHE_STORE', value: 'redis' }
            { name: 'QUEUE_CONNECTION', value: 'redis' }
            { name: 'INTERNAL_SERVICE_SECRET', secretRef: 'internal-secret' }
            { name: 'VENDOR_MANAGEMENT_URL', value: vendorManagementUrl }
            { name: 'MAIL_MAILER', value: 'log' }
            { name: 'MAIL_FROM_ADDRESS', value: mailFromAddress }
            { name: 'MAIL_FROM_NAME', value: mailFromName }
            { name: 'EMAIL_NOTIFICATIONS_PROVIDER', value: 'log' }
            { name: 'BREVO_BASE_URL', value: brevoBaseUrl }
            { name: 'BREVO_API_KEY', secretRef: 'brevo-key' }
            { name: 'BREVO_WEBHOOK_SECRET', value: brevoWebhookSecret }
            { name: 'BREVO_WEBHOOK_SECRET_HEADER', value: brevoWebhookHeader }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: 2
        rules: [
          {
            name: 'http-scaler'
            http: { metadata: { concurrentRequests: '20' } }
          }
        ]
      }
    }
  }
}

// ---------------------------------------------------------------------------
// auth-worker: Redis queue worker
// ---------------------------------------------------------------------------
resource authWorker 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'auth-worker'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      registries: registryConfig
      secrets: concat(registrySecret, [
        { name: 'app-key', value: authAppKey }
        { name: 'db-password', value: mysqlPassword }
        { name: 'encryption-key', value: internalEncryptionKey }
        { name: 'mail-password', value: mailPassword }
        { name: 'brevo-key', value: brevoApiKey }
      ])
    }
    template: {
      containers: [
        {
          name: 'auth-worker'
          image: authApiImage
          command: [ 'php' ]
          args: [ 'artisan', 'queue:work', '--tries=3', '--sleep=3' ]
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'APP_ENV', value: 'production' }
            { name: 'APP_KEY', secretRef: 'app-key' }
            { name: 'INTERNAL_ENCRYPTION_KEY', secretRef: 'encryption-key' }
            { name: 'DB_HOST', value: mysqlHost }
            { name: 'DB_DATABASE', value: 'capstone_auth' }
            { name: 'DB_USERNAME', value: 'root' }
            { name: 'DB_PASSWORD', secretRef: 'db-password' }
            { name: 'REDIS_HOST', value: redisHost }
            { name: 'REDIS_PORT', value: redisPort }
            { name: 'QUEUE_CONNECTION', value: 'redis' }
            { name: 'MAIL_MAILER', value: 'log' }
            { name: 'EMAIL_NOTIFICATIONS_PROVIDER', value: 'log' }
            { name: 'BREVO_API_KEY', secretRef: 'brevo-key' }
            { name: 'MAIL_PASSWORD', secretRef: 'mail-password' }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: 2
        rules: [
          {
            name: 'redis-scaler'
            custom: {
              type: 'redis'
              metadata: {
                address: '${redisHost}:${redisPort}'
                listName: 'queues:default'
                listLength: '1'
              }
            }
          }
        ]
      }
    }
  }
}

output authProxyFqdn string = authProxy.properties.configuration.ingress.fqdn
output authWebFqdn string = authWeb.properties.configuration.ingress.fqdn
output authApiFqdn string = authApi.properties.configuration.ingress.fqdn
