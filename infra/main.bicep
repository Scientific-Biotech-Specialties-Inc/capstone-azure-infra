// main.bicep — Core infrastructure for the capstone microservices.
//
// Deploys the two shared building blocks that everything else depends on:
//  1. Azure Container Registry (ACR)   — holds all container images
//  2. Container Apps Managed Environment — the single ACA environment the
//     14 container apps (auth-proxy, serms, ocr, stores) live in
//
// The container apps themselves are defined in apps.bicep and are deployed in
// a second phase AFTER the images have been built and pushed to ACR.
//
// Cost: ACR Basic (~$0 at low usage) + ACA Consumption tier (free allowance).

@description('Azure region for all resources.')
param location string = 'eastus'

@description('Name of the Container Apps Managed Environment. Becomes part of every app FQDN: <app>.<env>.<region>.azurecontainerapps.io')
param environmentName string = 'capstone-env'

@description('Globally unique name for the Azure Container Registry (lowercase letters + digits only).')
@minLength(5)
@maxLength(50)
param acrName string

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
  }
}

resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: environmentName
  location: location
  properties: {
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
        minimumNodeCount: 0
        maximumNodeCount: 0
      }
    ]
  }
}

output acrLoginServer string = acr.properties.loginServer
output managedEnvironmentId string = managedEnvironment.id
output acrName string = acr.name
output environmentName string = managedEnvironment.name
