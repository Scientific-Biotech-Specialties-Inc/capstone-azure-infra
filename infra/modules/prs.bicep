// prs.bicep — Productivity Report System (PRS) Module

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
param prsWebImage string = 'docker.io/library/nginx:alpine'
param prsApiImage string = 'docker.io/library/nginx:alpine'

// Secrets & connections
@secure()
param prsAppKey string = ''
@secure()
param mysqlPassword string = ''
@secure()
param jwtSecret string = ''
@secure()
param prsApiKey string = ''

param mysqlHost string = ''
param mysqlPort string = '3306'
param redisHost string = ''
param redisPort string = '6379'
param authServiceUrl string = ''
param ocrServiceUrl string = ''

// ---------------------------------------------------------------------------
// prs-web: Vue frontend (port 5003)
// ---------------------------------------------------------------------------
resource prsWeb 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'prs-web'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 5003, transport: 'http', allowInsecure: true }
      registries: registryConfig
      secrets: registrySecret
    }
    template: {
      containers: [
        {
          name: 'prs-web'
          image: prsWebImage
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
// prs-api: Backend API (port 8000)
// ---------------------------------------------------------------------------
resource prsApi 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'prs-api'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 8000, transport: 'http', allowInsecure: true }
      registries: registryConfig
      secrets: concat(registrySecret, [
        { name: 'app-key', value: !empty(prsAppKey) ? prsAppKey : 'base64:default_key' }
        { name: 'db-password', value: mysqlPassword }
        { name: 'jwt-secret', value: jwtSecret }
        { name: 'prs-api-key', value: prsApiKey }
      ])
    }
    template: {
      containers: [
        {
          name: 'prs-api'
          image: prsApiImage
          resources: { cpu: json('0.5'), memory: '1.0Gi' }
          env: [
            { name: 'APP_ENV', value: 'production' }
            { name: 'APP_KEY', secretRef: 'app-key' }
            { name: 'DB_CONNECTION', value: 'mysql' }
            { name: 'DB_HOST', value: mysqlHost }
            { name: 'DB_PORT', value: mysqlPort }
            { name: 'DB_DATABASE', value: 'prs' }
            { name: 'DB_USERNAME', value: 'root' }
            { name: 'DB_PASSWORD', secretRef: 'db-password' }
            { name: 'REDIS_HOST', value: redisHost }
            { name: 'REDIS_PORT', value: redisPort }
            { name: 'AUTH_SERVICE_URL', value: authServiceUrl }
            { name: 'OCR_SERVICE_URL', value: ocrServiceUrl }
            { name: 'PRS_API_KEY', secretRef: 'prs-api-key' }
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

output prsWebFqdn string = prsWeb.properties.configuration.ingress.fqdn
output prsApiFqdn string = prsApi.properties.configuration.ingress.fqdn
