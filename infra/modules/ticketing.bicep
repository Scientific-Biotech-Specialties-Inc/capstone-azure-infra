// ticketing.bicep — Ticketing System (TS) Subgroup Module

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
param ticketingWebImage string = 'docker.io/library/nginx:alpine'
param ticketingGatewayImage string = 'docker.io/library/nginx:alpine'

// Shared env/secrets
@secure()
param mysqlPassword string = ''
@secure()
param jwtSecret string = ''

param mysqlHost string = ''
param redisHost string = ''
param authServiceUrl string = ''

// ---------------------------------------------------------------------------
// ticketing-web: Vue/React frontend (port 5005)
// ---------------------------------------------------------------------------
resource ticketingWeb 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ticketing-web'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 5005, transport: 'http', allowInsecure: true }
      registries: registryConfig
      secrets: registrySecret
    }
    template: {
      containers: [
        {
          name: 'ticketing-web'
          image: ticketingWebImage
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
// ticketing-gateway: Backend gateway / storage entrypoint (port 80)
// ---------------------------------------------------------------------------
resource ticketingGateway 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ticketing-gateway'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 80, transport: 'http', allowInsecure: true }
      registries: registryConfig
      secrets: concat(registrySecret, [
        { name: 'db-password', value: mysqlPassword }
        { name: 'jwt-secret', value: jwtSecret }
      ])
    }
    template: {
      containers: [
        {
          name: 'ticketing-gateway'
          image: ticketingGatewayImage
          resources: { cpu: json('0.5'), memory: '1.0Gi' }
          env: [
            { name: 'APP_ENV', value: 'production' }
            { name: 'DB_HOST', value: mysqlHost }
            { name: 'DB_DATABASE', value: 'ticketing' }
            { name: 'DB_PASSWORD', secretRef: 'db-password' }
            { name: 'REDIS_HOST', value: redisHost }
            { name: 'AUTH_SERVICE_URL', value: authServiceUrl }
            { name: 'JWT_SECRET', secretRef: 'jwt-secret' }
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

output ticketingWebFqdn string = ticketingWeb.properties.configuration.ingress.fqdn
output ticketingGatewayFqdn string = ticketingGateway.properties.configuration.ingress.fqdn
