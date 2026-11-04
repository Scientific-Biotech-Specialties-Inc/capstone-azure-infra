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

var hasRegistry = !empty(registryServer) && !empty(registryUser)
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
param cmsBackendImage string = 'docker.io/library/nginx:alpine'

// Shared env/secrets
@secure()
param mysqlPassword string = ''
@secure()
param jwtSecret string = ''
@secure()
param internalEncryptionKey string = ''

param mysqlHost string = ''
param redisHost string = ''
param authServiceUrl string = ''

// ---------------------------------------------------------------------------
// cms-web: Vue frontend (port 5001)
// ---------------------------------------------------------------------------
resource cmsWeb 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'cms-web'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 5001, transport: 'http', allowInsecure: true }
      registries: registryConfig
      secrets: registrySecret
    }
    template: {
      containers: [
        {
          name: 'cms-web'
          image: cmsWebImage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
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
// CMS Backend Services (each at 0.25 vCPU, 0.5 GiB RAM, scaled to 0 when idle)
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
        { name: 'db-password', value: mysqlPassword }
        { name: 'jwt-secret', value: jwtSecret }
        { name: 'encryption-key', value: internalEncryptionKey }
      ])
    }
    template: {
      containers: [
        {
          name: svc
          image: cmsBackendImage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'APP_ENV', value: 'production' }
            { name: 'SERVICE_NAME', value: svc }
            { name: 'DB_HOST', value: mysqlHost }
            { name: 'DB_DATABASE', value: 'cms_${replace(svc, '-', '_')}' }
            { name: 'DB_PASSWORD', secretRef: 'db-password' }
            { name: 'REDIS_HOST', value: redisHost }
            { name: 'AUTH_SERVICE_URL', value: authServiceUrl }
            { name: 'JWT_SECRET', secretRef: 'jwt-secret' }
            { name: 'INTERNAL_ENCRYPTION_KEY', secretRef: 'encryption-key' }
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
