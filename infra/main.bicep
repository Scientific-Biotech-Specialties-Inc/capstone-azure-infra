// main.bicep — Core infrastructure for the capstone microservices.
//
// Deploys the shared building blocks that everything else depends on:
//  1. Azure Container Registry (ACR) [Optional/Default]
//  2. Container Apps Managed Environment + Log Analytics
//  3. Azure Storage Account + Azure Files Share for persistent DB backups/mounts [Optional/Default]
//
// Zero-edit account switching: acrName and storageAccountName auto-generate using
// uniqueString(subscription().subscriptionId, resourceGroup().id).

@description('Azure region for all resources.')
param location string = 'eastus'

@description('Name of the Container Apps Managed Environment. Becomes part of every app FQDN: <app>.<env>.<region>.azurecontainerapps.io')
param environmentName string = 'capstone-env'

@description('Deploy Azure Container Registry. Set false if using ghcr.io exclusively.')
param deployAcr bool = true

@description('Globally unique name for the Azure Container Registry. Defaults to deterministic hash per subscription and RG.')
param acrName string = 'capacr${uniqueString(subscription().subscriptionId, resourceGroup().id)}'

@description('Deploy Azure Files Storage for persistent database state across restarts.')
param deployStorage bool = true

@description('Globally unique name for the Storage Account. Defaults to deterministic hash per subscription and RG.')
param storageAccountName string = 'capst${uniqueString(subscription().subscriptionId, resourceGroup().id)}'

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = if (deployAcr) {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
  }
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${environmentName}-logs'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: environmentName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = if (deployStorage) {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowSharedKeyAccess: true
  }
}

resource fileServices 'Microsoft.Storage/storageAccounts/fileServices@2023-01-01' = if (deployStorage) {
  parent: storageAccount
  name: 'default'
}

resource dbBackupShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = if (deployStorage) {
  parent: fileServices
  name: 'db-backups'
  properties: {
    shareQuota: 5
  }
}

resource envStorage 'Microsoft.App/managedEnvironments/storages@2024-03-01' = if (deployStorage) {
  parent: managedEnvironment
  name: 'db-backups-storage'
  properties: {
    azureFile: {
      accountName: deployStorage ? storageAccount!.name : ''
      accountKey: deployStorage ? storageAccount!.listKeys().keys[0].value : ''
      shareName: deployStorage ? dbBackupShare!.name : ''
      accessMode: 'ReadWrite'
    }
  }
}

output acrLoginServer string = deployAcr ? acr!.properties.loginServer : ''
output managedEnvironmentId string = managedEnvironment.id
output acrName string = deployAcr ? acr!.name : ''
output environmentName string = managedEnvironment.name
output storageAccountName string = deployStorage ? storageAccount!.name : ''
output storageShareName string = deployStorage ? dbBackupShare!.name : ''
output envStorageName string = deployStorage ? envStorage!.name : ''
