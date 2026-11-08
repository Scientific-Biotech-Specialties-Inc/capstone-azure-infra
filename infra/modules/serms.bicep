// serms.bicep — Smart Expense Reimbursement Management System (SERMS)

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
param sermsWebImage string
param sermsApiImage string

// Secrets
@secure()
param sermsAppKey string
@secure()
param mysqlPassword string
@secure()
param jwtSecret string
@secure()
param aiServiceApiKey string
@secure()
param supabaseAccessKey string = ''
@secure()
param supabaseSecretKey string = ''

// Service configs
param mysqlHost string
param mysqlPort string = '3306'
param redisHost string
param redisPort string = '6379'
param authServiceUrl string
param aiServiceUrl string
param supabaseUrl string = ''
param supabaseRegion string = ''
param supabaseBucket string = ''
param supabaseEndpoint string = ''

// ---------------------------------------------------------------------------
// serms-web: static Vue build served by nginx (base /serms/, port 80)
// ---------------------------------------------------------------------------
resource sermsWeb 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'serms-web'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 80, transport: 'http', allowInsecure: true }
      registries: registryConfig
      secrets: registrySecret
    }
    template: {
      containers: [
        {
          name: 'serms-web'
          image: sermsWebImage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: 3
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
// serms-api: Laravel REST API
// ---------------------------------------------------------------------------
resource sermsApi 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'serms-api'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 8000, transport: 'http', allowInsecure: true }
      registries: registryConfig
      secrets: concat(registrySecret, [
        { name: 'app-key', value: sermsAppKey }
        { name: 'db-password', value: mysqlPassword }
        { name: 'jwt-secret', value: jwtSecret }
        { name: 'ai-api-key', value: aiServiceApiKey }
        { name: 'supabase-key', value: supabaseAccessKey }
        { name: 'supabase-secret', value: supabaseSecretKey }
      ])
    }
    template: {
      containers: [
        {
          name: 'serms-api'
          image: sermsApiImage
          args: [ 'php', 'artisan', 'serve', '--host=0.0.0.0', '--port=8000', '--no-reload' ]
          resources: { cpu: json('0.5'), memory: '1.0Gi' }
          env: [
            { name: 'APP_ENV', value: 'production' }
            { name: 'APP_DEBUG', value: 'false' }
            { name: 'APP_KEY', secretRef: 'app-key' }
            { name: 'DB_CONNECTION', value: 'mysql' }
            { name: 'DB_HOST', value: mysqlHost }
            { name: 'DB_PORT', value: mysqlPort }
            { name: 'DB_DATABASE', value: 'serms' }
            { name: 'DB_USERNAME', value: 'root' }
            { name: 'DB_PASSWORD', secretRef: 'db-password' }
            { name: 'REDIS_HOST', value: redisHost }
            { name: 'REDIS_PORT', value: redisPort }
            { name: 'REDIS_CLIENT', value: 'predis' }
            { name: 'CACHE_STORE', value: 'redis' }
            { name: 'QUEUE_CONNECTION', value: 'database' }
            { name: 'SERMS_SERVICE_ROLE', value: 'api' }
            { name: 'AUTH_SERVICE_URL', value: authServiceUrl }
            { name: 'JWT_SECRET', secretRef: 'jwt-secret' }
            { name: 'JWT_PUBLIC_KEY_PATH', value: 'storage/oauth-public.key' }
            { name: 'AI_SERVICE_URL', value: aiServiceUrl }
            { name: 'AI_SERVICE_API_KEY', secretRef: 'ai-api-key' }
            { name: 'AI_SERVICE_TIMEOUT', value: '60' }
            { name: 'AI_SERVICE_CALLBACK_BASE_URL', value: 'http://serms-api' }
            { name: 'SUPABASE_STORAGE_DRIVER', value: 's3' }
            { name: 'SUPABASE_URL', value: supabaseUrl }
            { name: 'SUPABASE_REGION', value: supabaseRegion }
            { name: 'SUPABASE_BUCKET', value: supabaseBucket }
            { name: 'SUPABASE_ENDPOINT', value: supabaseEndpoint }
            { name: 'SUPABASE_ACCESS_KEY_ID', secretRef: 'supabase-key' }
            { name: 'SUPABASE_SECRET_ACCESS_KEY', secretRef: 'supabase-secret' }
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
// serms-worker: Laravel DB-backed queue worker
// ---------------------------------------------------------------------------
resource sermsWorker 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'serms-worker'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      registries: registryConfig
      secrets: concat(registrySecret, [
        { name: 'app-key', value: sermsAppKey }
        { name: 'db-password', value: mysqlPassword }
        { name: 'jwt-secret', value: jwtSecret }
        { name: 'ai-api-key', value: aiServiceApiKey }
        { name: 'supabase-key', value: supabaseAccessKey }
        { name: 'supabase-secret', value: supabaseSecretKey }
      ])
    }
    template: {
      containers: [
        {
          name: 'serms-worker'
          image: sermsApiImage
          command: [ 'php' ]
          args: [ 'artisan', 'queue:work', '--sleep=3', '--tries=3' ]
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'APP_ENV', value: 'production' }
            { name: 'APP_KEY', secretRef: 'app-key' }
            { name: 'DB_CONNECTION', value: 'mysql' }
            { name: 'DB_HOST', value: mysqlHost }
            { name: 'DB_PORT', value: mysqlPort }
            { name: 'DB_DATABASE', value: 'serms' }
            { name: 'DB_USERNAME', value: 'root' }
            { name: 'DB_PASSWORD', secretRef: 'db-password' }
            { name: 'REDIS_HOST', value: redisHost }
            { name: 'REDIS_PORT', value: redisPort }
            { name: 'REDIS_CLIENT', value: 'predis' }
            { name: 'CACHE_STORE', value: 'redis' }
            { name: 'QUEUE_CONNECTION', value: 'database' }
            { name: 'SERMS_SERVICE_ROLE', value: 'worker' }
            { name: 'AUTH_SERVICE_URL', value: authServiceUrl }
            { name: 'JWT_SECRET', secretRef: 'jwt-secret' }
            { name: 'AI_SERVICE_URL', value: aiServiceUrl }
            { name: 'AI_SERVICE_API_KEY', secretRef: 'ai-api-key' }
            { name: 'SUPABASE_ACCESS_KEY_ID', secretRef: 'supabase-key' }
            { name: 'SUPABASE_SECRET_ACCESS_KEY', secretRef: 'supabase-secret' }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: 2
      }
    }
  }
}

output sermsWebFqdn string = sermsWeb.properties.configuration.ingress.fqdn
output sermsApiFqdn string = sermsApi.properties.configuration.ingress.fqdn
