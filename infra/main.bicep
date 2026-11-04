// main.bicep — Core infrastructure for the capstone microservices.
//
// Deploys the shared building blocks that everything else depends on:
//  1. Azure Container Registry (ACR) [Optional/Default]
//  2. Virtual Network & Delegated Subnet for TCP Ingress & ACA
//  3. Container Apps Managed Environment + Log Analytics
//
// Zero-edit account switching: acrName auto-generates using
// uniqueString(subscription().subscriptionId, resourceGroup().id).

@description('Azure region for all resources.')
param location string = 'eastasia'

@description('Name of the Container Apps Managed Environment. Becomes part of every app FQDN: <app>.<env>.<region>.azurecontainerapps.io')
param environmentName string = 'capstone-env'

@description('Deploy Azure Container Registry. Set false if using ghcr.io exclusively.')
param deployAcr bool = true

@description('Globally unique name for the Azure Container Registry. Defaults to deterministic hash per subscription and RG.')
param acrName string = 'capacr${uniqueString(subscription().subscriptionId, resourceGroup().id)}'

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

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'capstone-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'infra-subnet'
        properties: {
          addressPrefix: '10.0.0.0/23'
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
    ]
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
    vnetConfiguration: {
      infrastructureSubnetId: vnet.properties.subnets[0].id
      internal: false
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

output acrLoginServer string = deployAcr ? acr!.properties.loginServer : ''
output managedEnvironmentId string = managedEnvironment.id
output acrName string = deployAcr ? acr!.name : ''
output environmentName string = managedEnvironment.name
