// ocr.bicep — OCR Pipeline (FastAPI, Celery worker, Ollama LLM)

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
param ocrApiImage string
param ocrWorkerImage string
param ocrOllamaImage string

// Secrets
@secure()
param sermsApiKey string
@secure()
param prsApiKey string = ''
@secure()
param postgresPassword string

// Service configs
param redisHost string
param redisPort string = '6379'
param postgresHost string
param postgresPort string = '5432'
param mongoHost string
param mongoPort string = '27017'

// ---------------------------------------------------------------------------
// ocr-ollama: Local LLM service
// ---------------------------------------------------------------------------
resource ollama 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ocr-ollama'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: false, targetPort: 11434, transport: 'http', allowInsecure: true }
    }
    template: {
      containers: [
        {
          name: 'ocr-ollama'
          image: !empty(ocrOllamaImage) ? ocrOllamaImage : 'docker.io/ollama/ollama:latest'
          command: [
            '/bin/sh'
            '-c'
            '/bin/ollama serve & pid=$!; while ! ollama list >/dev/null 2>&1; do sleep 1; done; ollama pull qwen2.5:1.5b; wait $pid'
          ]
          env: [
            { name: 'OLLAMA_HOST', value: '0.0.0.0' }
          ]
          resources: { cpu: json('1.0'), memory: '2.0Gi' }
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: 1
        rules: [
          {
            name: 'http-scaler'
            http: { metadata: { concurrentRequests: '5' } }
          }
        ]
      }
    }
  }
}

// ---------------------------------------------------------------------------
// ocr-api: FastAPI REST API
// ---------------------------------------------------------------------------
resource ocrApi 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ocr-api'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: false, targetPort: 8010, transport: 'http', allowInsecure: true }
      registries: registryConfig
      secrets: concat(registrySecret, [
        { name: 'serms-api-key', value: sermsApiKey }
        { name: 'prs-api-key', value: prsApiKey }
        { name: 'callback-api-key', value: sermsApiKey }
        { name: 'pg-password', value: postgresPassword }
      ])
    }
    template: {
      containers: [
        {
          name: 'ocr-api'
          image: ocrApiImage
          resources: { cpu: json('0.5'), memory: '1.0Gi' }
          env: [
            { name: 'APP_ENV', value: 'production' }
            { name: 'SERMS_API_KEY', secretRef: 'serms-api-key' }
            { name: 'PRS_API_KEY', secretRef: 'prs-api-key' }
            { name: 'CALLBACK_API_KEY', secretRef: 'callback-api-key' }
            { name: 'OLLAMA_BASE_URL', value: 'http://ocr-ollama:11434' }
            { name: 'OLLAMA_MODEL', value: 'qwen2.5:1.5b' }
            { name: 'REDIS_URL', value: 'redis://${redisHost}:${redisPort}/0' }
            { name: 'MONGODB_URL', value: 'mongodb://${mongoHost}:${mongoPort}' }
            { name: 'MONGODB_DATABASE', value: 'ocr_pipeline' }
            { name: 'POSTGRES_URL', value: 'postgresql+asyncpg://ocr_user:${postgresPassword}@${postgresHost}:${postgresPort}/ocr_pipeline' }
            { name: 'EMBEDDING_MODEL', value: 'all-MiniLM-L6-v2' }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: 2
        rules: [
          {
            name: 'http-scaler'
            http: { metadata: { concurrentRequests: '10' } }
          }
        ]
      }
    }
  }
}

// ---------------------------------------------------------------------------
// ocr-worker: Celery OCR processing worker
// ---------------------------------------------------------------------------
resource ocrWorker 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ocr-worker'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      registries: registryConfig
      secrets: concat(registrySecret, [
        { name: 'serms-api-key', value: sermsApiKey }
        { name: 'prs-api-key', value: prsApiKey }
        { name: 'callback-api-key', value: sermsApiKey }
        { name: 'pg-password', value: postgresPassword }
      ])
    }
    template: {
      containers: [
        {
          name: 'ocr-worker'
          image: ocrWorkerImage
          command: [ 'celery' ]
          args: [ '-A', 'app.tasks.celery_app', 'worker', '--loglevel=info' ]
          resources: { cpu: json('1.0'), memory: '2.0Gi' }
          env: [
            { name: 'APP_ENV', value: 'production' }
            { name: 'SERMS_API_KEY', secretRef: 'serms-api-key' }
            { name: 'PRS_API_KEY', secretRef: 'prs-api-key' }
            { name: 'CALLBACK_API_KEY', secretRef: 'callback-api-key' }
            { name: 'OLLAMA_BASE_URL', value: 'http://ocr-ollama:11434' }
            { name: 'OLLAMA_MODEL', value: 'qwen2.5:1.5b' }
            { name: 'REDIS_URL', value: 'redis://${redisHost}:${redisPort}/0' }
            { name: 'MONGODB_URL', value: 'mongodb://${mongoHost}:${mongoPort}' }
            { name: 'MONGODB_DATABASE', value: 'ocr_pipeline' }
            { name: 'POSTGRES_URL', value: 'postgresql+asyncpg://ocr_user:${postgresPassword}@${postgresHost}:${postgresPort}/ocr_pipeline' }
            { name: 'OMP_NUM_THREADS', value: '1' }
            { name: 'OMP_THREAD_LIMIT', value: '1' }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: 2
        rules: [
          {
            name: 'celery-scaler'
            custom: {
              type: 'redis'
              metadata: {
                address: '${redisHost}:${redisPort}'
                listName: 'celery'
                listLength: '1'
              }
            }
          }
        ]
      }
    }
  }
}

output ocrApiFqdn string = ocrApi.properties.configuration.ingress.fqdn
output ocrOllamaFqdn string = ollama.properties.configuration.ingress.fqdn
