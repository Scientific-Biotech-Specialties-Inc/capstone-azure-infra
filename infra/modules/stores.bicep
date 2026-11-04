// stores.bicep — Shared persistent data stores (MySQL, Redis, Postgres, MongoDB)

@description('Region — must match the Managed Environment region.')
param location string

@description('Managed Environment ID.')
param managedEnvironmentId string

@description('Minimum replicas. 1 = always running, 0 = scale to zero.')
param minReplicas int = 1

@secure()
param mysqlRootPassword string

@secure()
param postgresPassword string

param mysqlImage string = 'docker.io/library/mysql:8.0'
param redisImage string = 'docker.io/library/redis:7-alpine'
param postgresImage string = 'docker.io/pgvector/pgvector:pg16'
param mongoImage string = 'docker.io/library/mongo:7'

param storageEnabled bool = true
param storageName string = 'db-backups-storage'

var volumeConfig = storageEnabled ? [
  {
    name: 'backup-vol'
    storageType: 'AzureFile'
    storageName: storageName
  }
] : []

var volumeMountsConfig = storageEnabled ? [
  {
    volumeName: 'backup-vol'
    mountPath: '/backups'
  }
] : []

// ---------------------------------------------------------------------------
// Shared MySQL
// ---------------------------------------------------------------------------
resource mysqlDb 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'shared-mysql'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: false, targetPort: 3306, transport: 'tcp', exposedPort: 3306 }
      secrets: [
        { name: 'root-password', value: mysqlRootPassword }
      ]
    }
    template: {
      volumes: volumeConfig
      containers: [
        {
          name: 'shared-mysql'
          image: mysqlImage
          resources: { cpu: json('0.5'), memory: '1.0Gi' }
          env: [
            { name: 'MYSQL_ROOT_PASSWORD', secretRef: 'root-password' }
            { name: 'MYSQL_DATABASE', value: 'serms' }
            { name: 'MYSQL_USER', value: 'serms_user' }
            { name: 'MYSQL_PASSWORD', secretRef: 'root-password' }
          ]
          volumeMounts: volumeMountsConfig
        }
      ]
      scale: { minReplicas: minReplicas, maxReplicas: 1 }
    }
  }
}

// ---------------------------------------------------------------------------
// Shared Redis
// ---------------------------------------------------------------------------
resource redis 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'shared-redis'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: false, targetPort: 6379, transport: 'tcp', exposedPort: 6379 }
    }
    template: {
      volumes: volumeConfig
      containers: [
        {
          name: 'shared-redis'
          image: redisImage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          volumeMounts: volumeMountsConfig
        }
      ]
      scale: { minReplicas: minReplicas, maxReplicas: 1 }
    }
  }
}

// ---------------------------------------------------------------------------
// Shared PostgreSQL + pgvector
// ---------------------------------------------------------------------------
resource postgres 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'shared-postgres'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: false, targetPort: 5432, transport: 'tcp', exposedPort: 5432 }
      secrets: [
        { name: 'pg-password', value: postgresPassword }
      ]
    }
    template: {
      volumes: volumeConfig
      containers: [
        {
          name: 'shared-postgres'
          image: postgresImage
          resources: { cpu: json('0.5'), memory: '1.0Gi' }
          env: [
            { name: 'POSTGRES_USER', value: 'ocr_user' }
            { name: 'POSTGRES_PASSWORD', secretRef: 'pg-password' }
            { name: 'POSTGRES_DB', value: 'ocr_pipeline' }
          ]
          volumeMounts: volumeMountsConfig
        }
      ]
      scale: { minReplicas: minReplicas, maxReplicas: 1 }
    }
  }
}

// ---------------------------------------------------------------------------
// Shared MongoDB
// ---------------------------------------------------------------------------
resource mongo 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'shared-mongo'
  location: location
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { transport: 'tcp', targetPort: 27017, exposedPort: 27017, external: false }
    }
    template: {
      volumes: volumeConfig
      containers: [
        {
          name: 'shared-mongo'
          image: mongoImage
          resources: { cpu: json('0.5'), memory: '1.0Gi' }
          volumeMounts: volumeMountsConfig
        }
      ]
      scale: { minReplicas: minReplicas, maxReplicas: 1 }
    }
  }
}

output mysqlFqdn string = mysqlDb.properties.configuration.ingress.fqdn
output redisFqdn string = redis.properties.configuration.ingress.fqdn
output postgresFqdn string = postgres.properties.configuration.ingress.fqdn
output mongoFqdn string = mongo.properties.configuration.ingress.fqdn
