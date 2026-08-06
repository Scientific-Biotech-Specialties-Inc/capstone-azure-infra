// apps.bicep — All 14 container apps + secret wiring.
//
// Deploy this AFTER building & pushing images to ACR (see scripts/deploy.ps1).
// Apps talk to each other over the ACA internal/public FQDNs computed from each
// sibling Container App's `ingress.fqdn`, replacing the old Docker hostnames
// (e.g. `serms_api:8000`).
//
// Scheduling notes
// - `scale.minReplicas` defaults to 1 so the presentation is warm and reliable.
//   For cost control, lower to 0 for idle apps or teardown after the demo.
// - Data stores use TCP ingress on public endpoints (the free ACA tier has no
//   private VNet). Radom app names + immediate teardown mitigates exposure.

@description('Region — must match the Managed Environment region.')
param location string

@description('Managed Environment name (see main.bicep).')
param environmentName string

@description('ACR name (see main.bicep).')
param acrName string

@description('Image tag to deploy. Default latest.')
param imageTag string = 'latest'

@description('Minimum replicas per app. 1 = always warm, 0 = scale to zero.')
param minReplicas int = 1

// ---------------------------------------------------------------------------
// Secure secrets (passed via CLI / CI, never committed)
// ---------------------------------------------------------------------------
@secure() param mysqlRootPassword string
@secure() param postgresPassword string
@secure() param jwtSecret string
@secure() param internalEncryptionKey string
@secure() param sermsAppKey string
@secure() param authAppKey string
@secure() param supabaseAccessKey string = ''
@secure() param supabaseSecretKey string = ''
@secure() param aiServiceApiKey string
@secure() param prsApiKey string = ''
@secure() param brevoApiKey string = ''
@secure() param mailPassword string = ''

// ---------------------------------------------------------------------------
//  Non-secret configuration
// ---------------------------------------------------------------------------
param supabaseUrl string = ''
param supabaseBucket string = ''
param supabaseRegion string = ''
param supabaseEndpoint string = ''
param brevoBaseUrl string = 'https://api.brevo.com/v3'
param brevoWebhookSecret string = ''
param brevoWebhookHeader string = 'X-Brevo-Webhook-Secret'
param maillerHost string = '127.0.0.1'
param mailPort string = '1025'
param mailFromAddress string = 'noreply@capstone.local'
param mailFromName string = 'Capstone Auth'
param vendorManagementUrl string = ''
param brevoTemplates string = '{}'
param authWebApiUrl string = 'http://localhost:8000'

// ---------------------------------------------------------------------------
//  Shared references
// ---------------------------------------------------------------------------
var loginServer = '${acrName}.azurecr.io'

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: environmentName
}

// ACR admin credentials for pulling images.
var acrUser = acr.listCredentials().username
var acrPass = acr.listCredentials().passwords[0].value

// ---------------------------------------------------------------------------
//  PUBLIC FRONT DOOR — capstone-auth-module reverse proxy
//  Routes: / -> auth-web, /serms -> serms-web, /api/serms -> serms-api,
//          /api -> auth-api. PRS/CMS routes return 503 (not deployed here).
// ---------------------------------------------------------------------------
resource authProxy 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'auth-proxy'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 5173
        transport: 'http'
        allowInsecure: false
      }
      registries: [
        { server: loginServer, username: acrUser, passwordSecretRef: 'acr-pass' }
      ]
      secrets: [
        { name: 'acr-pass', value: acrPass }
      ]
    }
    template: {
      containers: [
        {
          name: 'auth-proxy'
          image: '${loginServer}/auth-proxy:${imageTag}'
          resources: { cpu: '0.25', memory: '0.5Gi' }
          env: [
            { name: 'AUTH_WEB_URL', value: 'http://${authWeb.properties.configuration.ingress.fqdn}' }
            { name: 'AUTH_API_URL', value: 'http://${authApi.properties.configuration.ingress.fqdn}' }
            { name: 'SERMS_WEB_URL', value: 'http://${sermsWeb.properties.configuration.ingress.fqdn}' }
            { name: 'SERMS_API_URL', value: 'http://${sermsApi.properties.configuration.ingress.fqdn}' }
          ]
        }
      ]
      scale: { minReplicas: minReplicas, maxReplicas: 3 }
    }
  }
}

// ---------------------------------------------------------------------------
//  capstone-auth-module
// ---------------------------------------------------------------------------
// auth-web: Vue admin UI / login page (served by the proxy at /)
resource authWeb 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'auth-web'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 5000, transport: 'http', allowInsecure: true }
      registries: [
        { server: loginServer, username: acrUser, passwordSecretRef: 'acr-pass' }
      ]
      secrets: [
        { name: 'acr-pass', value: acrPass }
        { name: 'internal-encryption-key', value: internalEncryptionKey }
      ]
    }
    template: {
      containers: [
        {
          name: 'auth-web'
          image: '${loginServer}/auth-web:${imageTag}'
          resources: { cpu: '0.25', memory: '0.5Gi' }
          env: [
            { name: 'VITE_API_URL', value: authWebApiUrl }
            { name: 'VITE_INTERNAL_ENCRYPTION_KEY', secretRef: 'internal-encryption-key' }
          ]
        }
      ]
      scale: { minReplicas: minReplicas, maxReplicas: 2 }
    }
  }
}

// auth-api: Laravel REST API (artisan serve, entrypoint runs migrations)
resource authApi 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'auth-api'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 8000, transport: 'http', allowInsecure: true }
      registries: [
        { server: loginServer, username: acrUser, passwordSecretRef: 'acr-pass' }
      ]
      secrets: [
        { name: 'acr-pass', value: acrPass }
        { name: 'app-key', value: authAppKey }
        { name: 'db-password', value: mysqlRootPassword }
        { name: 'encryption-key', value: internalEncryptionKey }
        { name: 'internal-secret', value: internalEncryptionKey }
        { name: 'mail-password', value: mailPassword }
        { name: 'brevo-key', value: brevoApiKey }
      ]
    }
    template: {
      containers: [
        {
          name: 'auth-api'
          image: '${loginServer}/auth-api:${imageTag}'
          resources: { cpu: '0.5', memory: '1.0Gi' }
          env: [
            { name: 'APP_ENV', value: 'production' }
            { name: 'APP_DEBUG', value: 'false' }
            { name: 'APP_KEY', secretRef: 'app-key' }
            { name: 'INTERNAL_ENCRYPTION_KEY', secretRef: 'encryption-key' }
            { name: 'DB_CONNECTION', value: 'mysql' }
            { name: 'DB_HOST', value: mysqlDb.properties.configuration.ingress.fqdn }
            { name: 'DB_PORT', value: '3306' }
            { name: 'DB_DATABASE', value: 'capstone_auth' }
            { name: 'DB_USERNAME', value: 'root' }
            { name: 'DB_PASSWORD', secretRef: 'db-password' }
            { name: 'REDIS_CLIENT', value: 'phpredis' }
            { name: 'REDIS_HOST', value: redis.properties.configuration.ingress.fqdn }
            { name: 'REDIS_PORT', value: '6379' }
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
            { name: 'BREVO_TEMPLATE_WELCOME_TEMP_PASSWORD', value: '' }
            { name: 'BREVO_TEMPLATE_PASSWORD_RESET', value: 'free' }
            { name: 'BREVO_TEMPLATE_EMAIL_VERIFICATION', value: '' }
            { name: 'BREVO_TEMPLATE_PASSWORD_CHANGED_CONFIRMATION', value: '' }
          ]
        }
      ]
      scale: { minReplicas: minReplicas, maxReplicas: 2 }
    }
  }
}

// auth-worker: Redis queue worker (skips migrations)
resource authWorker 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'auth-worker'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: [
        { server: loginServer, username: acrUser, passwordSecretRef: 'acr-pass' }
      ]
      secrets: [
        { name: 'acr-pass', value: acrPass }
        { name: 'app-key', value: authAppKey }
        { name: 'db-password', value: mysqlRootPassword }
        { name: 'encryption-key', value: internalEncryptionKey }
        { name: 'mail-password', value: mailPassword }
        { name: 'brevo-key', value: brevoApiKey }
      ]
    }
    template: {
      containers: [
        {
          name: 'auth-worker'
          image: '${loginServer}/auth-api:${imageTag}'
          command: [ 'php' ]
          args: [ 'artisan', 'queue:work', '--tries=3', '--sleep=3' ]
          resources: { cpu: '0.25', memory: '0.5Gi' }
          env: [
            { name: 'APP_ENV', value: 'production' }
            { name: 'APP_KEY', secretRef: 'app-key' }
            { name: 'INTERNAL_ENCRYPTION_KEY', secretRef: 'encryption-key' }
            { name: 'DB_HOST', value: mysqlDb.properties.configuration.ingress.fqdn }
            { name: 'DB_DATABASE', value: 'capstone_auth' }
            { name: 'DB_USERNAME', value: 'root' }
            { name: 'DB_PASSWORD', secretRef: 'db-password' }
            { name: 'REDIS_HOST', value: redis.properties.configuration.ingress.fqdn }
            { name: 'REDIS_PORT', value: '6379' }
            { name: 'QUEUE_CONNECTION', value: 'redis' }
            { name: 'MAIL_MAILER', value: 'log' }
            { name: 'EMAIL_NOTIFICATIONS_PROVIDER', value: 'log' }
            { name: 'BREVO_API_KEY', secretRef: 'brevo-key' }
            { name: 'MAIL_PASSWORD', secretRef: 'mail-password' }
          ]
        }
      ]
      scale: { minReplicas: minReplicas, maxReplicas: 2 }
    }
  }
}

// ---------------------------------------------------------------------------
//  SERMS
// ---------------------------------------------------------------------------
// serms-web: static Vue build served by nginx (base /serms/, port 80)
resource sermsWeb 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'serms-web'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 80, transport: 'http', allowInsecure: true }
      registries: [
        { server: loginServer, username: acrUser, passwordSecretRef: 'acr-pass' }
      ]
      secrets: [ { name: 'acr-pass', value: acrPass } ]
    }
    template: {
      containers: [
        {
          name: 'serms-web'
          image: '${loginServer}/serms-web:${imageTag}'
          resources: { cpu: '0.25', memory: '0.5Gi' }
        }
      ]
      scale: { minReplicas: minReplicas, maxReplicas: 3 }
    }
  }
}

// serms-api: Laravel API (artisan serve override; entrypoint runs migrations)
resource sermsApi 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'serms-api'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 8000, transport: 'http', allowInsecure: true }
      registries: [
        { server: loginServer, username: acrUser, passwordSecretRef: 'acr-pass' }
      ]
      secrets: [
        { name: 'acr-pass', value: acrPass }
        { name: 'app-key', value: sermsAppKey }
        { name: 'db-password', value: mysqlRootPassword }
        { name: 'jwt-secret', value: jwtSecret }
        { name: 'ai-api-key', value: aiServiceApiKey }
        { name: 'supabase-key', value: supabaseAccessKey }
        { name: 'supabase-secret', value: supabaseSecretKey }
      ]
    }
    template: {
      containers: [
        {
          name: 'serms-api'
          image: '${loginServer}/serms-api:${imageTag}'
          args: [ 'php', 'artisan', 'serve', '--host=0.0.0.0', '--port=8000', '--no-reload' ]
          resources: { cpu: '0.5', memory: '1.0Gi' }
          env: [
            { name: 'APP_ENV', value: 'production' }
            { name: 'APP_DEBUG', value: 'false' }
            { name: 'APP_KEY', secretRef: 'app-key' }
            { name: 'APP_URL', value: 'http://${loginServer}' }
            { name: 'DB_CONNECTION', value: 'mysql' }
            { name: 'DB_HOST', value: mysqlDb.properties.configuration.ingress.fqdn }
            { name: 'DB_PORT', value: '3306' }
            { name: 'DB_DATABASE', value: 'serms' }
            { name: 'DB_USERNAME', value: 'root' }
            { name: 'DB_PASSWORD', secretRef: 'db-password' }
            { name: 'REDIS_HOST', value: redis.properties.configuration.ingress.fqdn }
            { name: 'REDIS_PORT', value: '6379' }
            { name: 'REDIS_PASSWORD', value: '' }
            { name: 'CACHE_STORE', value: 'redis' }
            { name: 'QUEUE_CONNECTION', value: 'database' }
            { name: 'SERMS_SERVICE_ROLE', value: 'api' }
            { name: 'AUTH_SERVICE_URL', value: 'http://${authApi.properties.configuration.ingress.fqdn}' }
            { name: 'JWT_SECRET', secretRef: 'jwt-secret' }
            { name: 'JWT_PUBLIC_KEY_PATH', value: 'storage/oauth-public.key' }
            { name: 'AI_SERVICE_URL', value: 'http://${ocrApi.properties.configuration.ingress.fqdn}' }
            { name: 'AI_SERVICE_API_KEY', secretRef: 'ai-api-key' }
            { name: 'AI_SERVICE_CALLBACK_BASE_URL', value: 'http://${sermsApi.properties.configuration.ingress.fqdn}' }
            { name: 'AI_SERVICE_TIMEOUT', value: '10' }
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
      scale: { minReplicas: minReplicas, maxReplicas: 2 }
    }
  }
}

// serms-worker: Laravel DB-backed queue worker
resource sermsWorker 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'serms-worker'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: [
        { server: loginServer, username: acrUser, passwordSecretRef: 'acr-pass' }
      ]
      secrets: [
        { name: 'acr-pass', value: acrPass }
        { name: 'app-key', value: sermsAppKey }
        { name: 'db-password', value: mysqlRootPassword }
        { name: 'jwt-secret', value: jwtSecret }
        { name: 'ai-api-key', value: aiServiceApiKey }
        { name: 'supabase-key', value: supabaseAccessKey }
        { name: 'supabase-secret', value: supabaseSecretKey }
      ]
    }
    template: {
      containers: [
        {
          name: 'serms-worker'
          image: '${loginServer}/serms-api:${imageTag}'
          command: [ 'php' ]
          args: [ 'artisan', 'queue:work', '--sleep=3', '--tries=3' ]
          resources: { cpu: '0.25', memory: '0.5Gi' }
          env: [
            { name: 'APP_ENV', value: 'production' }
            { name: 'APP_KEY', secretRef: 'app-key' }
            { name: 'DB_HOST', value: mysqlDb.properties.configuration.ingress.fqdn }
            { name: 'DB_PORT', value: '3306' }
            { name: 'DB_DATABASE', value: 'serms' }
            { name: 'DB_USERNAME', value: 'root' }
            { name: 'DB_PASSWORD', secretRef: 'db-password' }
            { name: 'REDIS_HOST', value: redis.properties.configuration.ingress.fqdn }
            { name: 'QUEUE_CONNECTION', value: 'database' }
            { name: 'SERMS_SERVICE_ROLE', value: 'worker' }
            { name: 'AUTH_SERVICE_URL', value: 'http://${authApi.properties.configuration.ingress.fqdn}' }
            { name: 'JWT_SECRET', secretRef: 'jwt-secret' }
            { name: 'AI_SERVICE_URL', value: 'http://${ocrApi.properties.configuration.ingress.fqdn}' }
            { name: 'AI_SERVICE_API_KEY', secretRef: 'ai-api-key' }
            { name: 'AI_SERVICE_CALLBACK_BASE_URL', value: 'http://${sermsApi.properties.configuration.ingress.fqdn}' }
            { name: 'SUPABASE_ACCESS_KEY_ID', secretRef: 'supabase-key' }
            { name: 'SUPABASE_SECRET_ACCESS_KEY', secretRef: 'supabase-secret' }
          ]
        }
      ]
      scale: { minReplicas: minReplicas, maxReplicas: 2 }
    }
  }
}

// ---------------------------------------------------------------------------
//  OCR pipeline (FastAPI + Celery worker + local Ollama LLM)
// ---------------------------------------------------------------------------
resource ocrApi 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ocr-api'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 8010, transport: 'http', allowInsecure: true }
      registries: [
        { server: loginServer, username: acrUser, passwordSecretRef: 'acr-pass' }
      ]
      secrets: [
        { name: 'acr-pass', value: acrPass }
        { name: 'serms-api-key', value: aiServiceApiKey }
        { name: 'prs-api-key', value: prsApiKey }
        { name: 'callback-api-key', value: aiServiceApiKey }
        { name: 'pg-password', value: postgresPassword }
        { name: 'pg-user', value: 'ocr_user' }
      ]
    }
    template: {
      containers: [
        {
          name: 'ocr-api'
          image: '${loginServer}/ocr-api:${imageTag}'
          resources: { cpu: '0.5', memory: '1.0Gi' }
          env: [
            { name: 'APP_ENV', value: 'production' }
            { name: 'SERMS_API_KEY', secretRef: 'serms-api-key' }
            { name: 'PRS_API_KEY', secretRef: 'prs-api-key' }
            { name: 'CALLBACK_API_KEY', secretRef: 'callback-api-key' }
            { name: 'OLLAMA_BASE_URL', value: 'http://${ollama.properties.configuration.ingress.fqdn}' }
            { name: 'OLLAMA_MODEL', value: 'qwen2.5:1.5b' }
            { name: 'REDIS_URL', value: 'redis://${redis.properties.configuration.ingress.fqdn}:6379/0' }
            { name: 'MONGODB_URL', value: 'mongodb://${mongo.properties.configuration.ingress.fqdn}:27017' }
            { name: 'MONGODB_DATABASE', value: 'ocr_pipeline' }
            { name: 'POSTGRES_URL', value: 'postgresql+asyncpg://ocr_user:${postgresPassword}@${postgres.properties.configuration.ingress.fqdn}:5432/ocr_pipeline' }
            { name: 'EMBEDDING_MODEL', value: 'all-MiniLM-L6-v2' }
          ]
        }
      ]
      scale: { minReplicas: minReplicas, maxReplicas: 2 }
    }
  }
}

resource ocrWorker 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ocr-worker'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: [
        { server: loginServer, username: acrUser, passwordSecretRef: 'acr-pass' }
      ]
      secrets: [
        { name: 'acr-pass', value: acrPass }
        { name: 'serms-api-key', value: aiServiceApiKey }
        { name: 'prs-api-key', value: prsApiKey }
        { name: 'callback-api-key', value: aiServiceApiKey }
        { name: 'pg-password', value: postgresPassword }
      ]
    }
    template: {
      containers: [
        {
          name: 'ocr-worker'
          image: '${loginServer}/ocr-api:${imageTag}'
          command: [ 'celery' ]
          args: [ '-A', 'app.tasks.celery_app', 'worker', '--loglevel=info' ]
          resources: { cpu: '1.0', memory: '1.5Gi' }
          env: [
            { name: 'APP_ENV', value: 'production' }
            { name: 'SERMS_API_KEY', secretRef: 'serms-api-key' }
            { name: 'PRS_API_KEY', secretRef: 'prs-api-key' }
            { name: 'CALLBACK_API_KEY', secretRef: 'callback-api-key' }
            { name: 'OLLAMA_BASE_URL', value: 'http://${ollama.properties.configuration.ingress.fqdn}' }
            { name: 'OLLAMA_MODEL', value: 'qwen2.5:1.5b' }
            { name: 'REDIS_URL', value: 'redis://${redis.properties.configuration.ingress.fqdn}:6379/0' }
            { name: 'MONGODB_URL', value: 'mongodb://${mongo.properties.configuration.ingress.fqdn}:27017' }
            { name: 'MONGODB_DATABASE', value: 'ocr_pipeline' }
            { name: 'POSTGRES_URL', value: 'postgresql+asyncpg://ocr_user:${postgresPassword}@${postgres.properties.configuration.ingress.fqdn}:5432/ocr_pipeline' }
            { name: 'OMP_NUM_THREADS', value: '1' }
            { name: 'OMP_THREAD_LIMIT', value: '1' }
          ]
        }
      ]
      scale: { minReplicas: minReplicas, maxReplicas: 3 }
    }
  }
}

// ---------------------------------------------------------------------------
//  OCR: local Ollama LLM (qwen2.5:1.5b) — the demo highlight
// ---------------------------------------------------------------------------
resource ollama 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ocr-ollama'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 11434, transport: 'http', allowInsecure: true }
      registries: [
        { server: loginServer, username: acrUser, passwordSecretRef: 'acr-pass' }
      ]
      secrets: [ { name: 'acr-pass', value: acrPass } ]
    }
    template: {
      containers: [
        {
          name: 'ocr-ollama'
          image: '${loginServer}/ocr-ollama:${imageTag}'
          resources: { cpu: '1.0', memory: '2.0Gi' }
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}

// ---------------------------------------------------------------------------
//  Data stores (ephemeral, shared across the services)
// ---------------------------------------------------------------------------
resource mysqlDb 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'shared-mysql'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 3306, transport: 'tcp', exposedPort: 3306 }
      registries: [
        { server: loginServer, username: acrUser, passwordSecretRef: 'acr-pass' }
      ]
      secrets: [
        { name: 'acr-pass', value: acrPass }
        { name: 'root-password', value: mysqlRootPassword }
      ]
    }
    template: {
      containers: [
        {
          name: 'shared-mysql'
          image: '${loginServer}/mysql-init:${imageTag}'
          resources: { cpu: '0.5', memory: '1.0Gi' }
          env: [
            { name: 'MYSQL_ROOT_PASSWORD', secretRef: 'root-password' }
            { name: 'MYSQL_DATABASE', value: 'serms' }
            { name: 'MYSQL_USER', value: 'serms_user' }
            { name: 'MYSQL_PASSWORD', secretRef: 'root-password' }
          ]
        }
      ]
      scale: { minReplicas: minReplicas, maxReplicas: 1 }
    }
  }
}

resource redis 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'shared-redis'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 6379, transport: 'tcp', exposedPort: 6379 }
      registries: [
        { server: loginServer, username: acrUser, passwordSecretRef: 'acr-pass' }
      ]
      secrets: [ { name: 'acr-pass', value: acrPass } ]
    }
    template: {
      containers: [
        {
          name: 'shared-redis'
          image: 'redis:7-alpine'
          resources: { cpu: '0.25', memory: '0.5Gi' }
        }
      ]
      scale: { minReplicas: minReplicas, maxReplicas: 1 }
    }
  }
}

resource postgres 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'shared-postgres'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, targetPort: 5432, transport: 'tcp', exposedPort: 5432 }
      registries: [
        { server: loginServer, username: acrUser, passwordSecretRef: 'acr-pass' }
      ]
      secrets: [
        { name: 'acr-pass', value: acrPass }
        { name: 'pg-password', value: postgresPassword }
      ]
    }
    template: {
      containers: [
        {
          name: 'shared-postgres'
          image: 'pgvector/pgvector:pg16'
          resources: { cpu: '0.5', memory: '1.0Gi' }
          env: [
            { name: 'POSTGRES_USER', value: 'ocr_user' }
            { name: 'POSTGRES_PASSWORD', secretRef: 'pg-password' }
            { name: 'POSTGRES_DB', value: 'ocr_pipeline' }
          ]
        }
      ]
      scale: { minReplicas: minReplicas, maxReplicas: 1 }
    }
  }
}

resource mongo 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'shared-mongo'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { transport: 'tcp', targetPort: 27017, exposedPort: 27017, external: true }
      registries: [
        { server: loginServer, username: acrUser, passwordSecretRef: 'acr-pass' }
      ]
      secrets: [ { name: 'acr-pass', value: acrPass } ]
    }
    template: {
      containers: [
        {
          name: 'shared-mongo'
          image: 'mongo:7'
          resources: { cpu: '0.5', memory: '1.0Gi' }
        }
      ]
      scale: { minReplicas: minReplicas, maxReplicas: 1 }
    }
  }
}

output authProxyFqdn string = authProxy.properties.configuration.ingress.fqdn