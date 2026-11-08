// cms.bicep — Contract Management System (CMS/CRMS) Subgroup Module

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
param cmsWebImage string = 'docker.io/library/nginx:alpine'
param cmsBackendImagePrefix string
param cmsBackendImageTag string

// Shared env/secrets
@secure()
param mysqlPassword string
@secure()
param jwtSecret string
@secure()
param internalServiceSecret string
@secure()
@minLength(1)
param appKey string
@secure()
@minLength(1)
param fieldEncryptionKey string
@secure()
@minLength(1)
param postgresPassword string
@secure()
@minLength(1)
param meilisearchKey string

@minLength(1)
param mysqlHost string
@minLength(1)
param redisHost string
@minLength(1)
param postgresHost string
@minLength(1)
param postgresUsername string
@minLength(1)
param mongoHost string
param meilisearchUrl string = ''
param authServiceUrl string
param defaultDomain string = ''

// ---------------------------------------------------------------------------
// Internal Meilisearch (serverless scale-to-zero in-cluster instance)
// ---------------------------------------------------------------------------
var internalMeilisearchName = 'cms-meilisearch'
var activeMeilisearchUrl = !empty(meilisearchUrl) ? meilisearchUrl : 'http://${internalMeilisearchName}:7700'

resource meilisearch 'Microsoft.App/containerApps@2024-03-01' = if (empty(meilisearchUrl)) {
  name: internalMeilisearchName
  location: location
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: false, targetPort: 7700, transport: 'http', allowInsecure: true }
      secrets: [
        { name: 'meili-key', value: meilisearchKey }
      ]
    }
    template: {
      containers: [
        {
          name: internalMeilisearchName
          image: 'docker.io/getmeili/meilisearch:v1.8'
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'MEILI_MASTER_KEY', secretRef: 'meili-key' }
            { name: 'MEILI_ENV', value: 'production' }
            { name: 'MEILI_NO_ANALYTICS', value: 'true' }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: 1
      }
    }
  }
}

// ---------------------------------------------------------------------------
// cms-web: Unified Nginx Gateway + Vue Frontend (port 5001, external: true)
// ---------------------------------------------------------------------------
resource cmsWeb 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'cms-web'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 5001, transport: 'http', allowInsecure: false }
      registries: registryConfig
      secrets: registrySecret
    }
    template: {
      containers: [
        {
          name: 'cms-web'
          image: cmsWebImage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'INTERNAL_DOMAIN', value: !empty(defaultDomain) ? '.internal.${defaultDomain}' : '' }
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
// Helper array for the 6 microservices
// ---------------------------------------------------------------------------
var cmsServices = [
  'vendor-management'
  'contract-management'
  'search'
  'notification'
  'ai-service'
  'analytics-service'
]

// ---------------------------------------------------------------------------
// CMS Backend Services (each at 0.5 vCPU, 1.0 GiB RAM, scaled to 0 when idle)
// ---------------------------------------------------------------------------
resource cmsMicroservices 'Microsoft.App/containerApps@2024-03-01' = [for svc in cmsServices: {
  name: svc
  location: location
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 8000, transport: 'http', allowInsecure: true }
      registries: registryConfig
      secrets: concat(registrySecret, [
        { name: 'db-password', value: svc == 'ai-service' ? postgresPassword : mysqlPassword }
        { name: 'app-key', value: appKey }
        { name: 'jwt-secret', value: jwtSecret }
        { name: 'internal-secret', value: internalServiceSecret }
        { name: 'field-encryption-key', value: fieldEncryptionKey }
      ], contains(['contract-management', 'search'], svc) ? [
        { name: 'meilisearch-key', value: meilisearchKey }
      ] : [])
    }
    template: {
      containers: [
        {
          name: svc
          image: '${cmsBackendImagePrefix}cms-${svc}:${cmsBackendImageTag}'
          command: svc == 'ai-service' ? ['/bin/sh', '-c'] : []
          args: svc == 'ai-service' ? ['php artisan config:clear 2>/dev/null || true; php artisan migrate --force --no-interaction 2>/dev/null || true; exec php artisan serve --host=0.0.0.0 --port=8000'] : []
          resources: { cpu: json('0.5'), memory: '1.0Gi' }
          env: concat([
            { name: 'APP_ENV', value: 'production' }
            { name: 'APP_KEY', secretRef: 'app-key' }
            { name: 'SERVICE_NAME', value: svc }
            { name: 'DB_CONNECTION', value: svc == 'ai-service' ? 'pgsql' : 'mysql' }
            { name: 'DB_HOST', value: svc == 'ai-service' ? postgresHost : mysqlHost }
            { name: 'DB_PORT', value: svc == 'ai-service' ? '5432' : '3306' }
            { name: 'DB_DATABASE', value: 'cms_${replace(svc, '-', '_')}' }
            { name: 'DB_USERNAME', value: svc == 'ai-service' ? postgresUsername : 'root' }
            { name: 'DB_PASSWORD', secretRef: 'db-password' }
            { name: 'REDIS_HOST', value: redisHost }
            { name: 'AUTH_SERVICE_URL', value: authServiceUrl }
            { name: 'JWT_SECRET', secretRef: 'jwt-secret' }
            { name: 'INTERNAL_SERVICE_SECRET', secretRef: 'internal-secret' }
            { name: 'FIELD_ENCRYPTION_KEY', secretRef: 'field-encryption-key' }
            { name: 'VENDOR_SERVICE_URL', value: 'http://vendor-management/api' }
            { name: 'CONTRACT_SERVICE_URL', value: svc == 'notification' ? 'http://contract-management' : 'http://contract-management/api' }
            { name: 'NOTIFICATION_SERVICE_URL', value: 'http://notification/api' }
            { name: 'AI_SERVICE_URL', value: 'http://ai-service/api' }
          ], contains(['contract-management', 'search'], svc) ? [
            { name: 'MEILISEARCH_HOST', value: activeMeilisearchUrl }
            { name: 'MEILISEARCH_KEY', secretRef: 'meilisearch-key' }
          ] : [], contains(['contract-management', 'vendor-management'], svc) ? [
            { name: 'MONGODB_URI', value: 'mongodb://${mongoHost}:27017' }
          ] : [], svc == 'contract-management' ? [
            { name: 'CLAMD_FAIL_OPEN', value: 'true' }
          ] : [])
          probes: [
            {
              type: 'Readiness'
              httpGet: { path: '/up', port: 8000 }
              initialDelaySeconds: 10
              periodSeconds: 5
              timeoutSeconds: 3
              failureThreshold: 24
            }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: 1
        rules: [
          {
            name: 'http-scaler'
            http: { metadata: { concurrentRequests: '15' } }
          }
        ]
      }
    }
  }
}]

output cmsWebFqdn string = cmsWeb.properties.configuration.ingress.fqdn
output vendorManagementFqdn string = cmsMicroservices[0].properties.configuration.ingress.fqdn
output contractManagementFqdn string = cmsMicroservices[1].properties.configuration.ingress.fqdn
output searchFqdn string = cmsMicroservices[2].properties.configuration.ingress.fqdn
output notificationFqdn string = cmsMicroservices[3].properties.configuration.ingress.fqdn
output aiServiceFqdn string = cmsMicroservices[4].properties.configuration.ingress.fqdn
output analyticsServiceFqdn string = cmsMicroservices[5].properties.configuration.ingress.fqdn
