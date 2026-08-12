@description('Globally unique name of the Azure Function App.')
@minLength(3)
param functionAppName string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Client ID of the Entra app registration that protects the Function API.')
param entraClientId string

@description('Application ID URI configured under Expose an API.')
param apiAudience string = 'api://${entraClientId}'

@description('JSON policy mapping Entra group object IDs to allowed Autopilot Group Tags.')
@minLength(2)
param tagAuthorizationPolicy string

@description('JSON policy containing users and groups allowed to manage Group Tags.')
@minLength(2)
param managerAuthorizationPolicy string

var storageAccountName = take(replace('${functionAppName}${uniqueString(resourceGroup().id)}', '-', ''), 24)
var applicationInsightsName = '${functionAppName}-insights'
var hostingPlanName = '${functionAppName}-plan'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  #disable-next-line BCP334 // uniqueString guarantees 13 characters after replacement.
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource configurationContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'configuration'
  properties: {
    publicAccess: 'None'
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: applicationInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

resource hostingPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: hostingPlanName
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {}
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: hostingPlan.id
    httpsOnly: true
    siteConfig: {
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'powershell'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME_VERSION'
          value: '7.4'
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '1'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: applicationInsights.properties.ConnectionString
        }
        {
          name: 'TAG_AUTHORIZATION_POLICY'
          value: tagAuthorizationPolicy
        }
        {
          name: 'MANAGER_AUTHORIZATION_POLICY'
          value: managerAuthorizationPolicy
        }
      ]
    }
  }
}

resource authentication 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: functionApp
  name: 'authsettingsV2'
  properties: {
    platform: {
      enabled: true
      runtimeVersion: '~1'
    }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'Return401'
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: entraClientId
          openIdIssuer: '${environment().authentication.loginEndpoint}${tenant().tenantId}/v2.0'
        }
        validation: {
          allowedAudiences: [
            apiAudience
          ]
        }
      }
    }
    login: {
      tokenStore: {
        enabled: false
      }
    }
    httpSettings: {
      requireHttps: true
    }
  }
}

output functionUrl string = 'https://${functionApp.properties.defaultHostName}/api/devices/import'
output managementUrl string = 'https://${functionApp.properties.defaultHostName}/api/management/tag-policy'
output managedIdentityObjectId string = functionApp.identity.principalId
output storageAccountName string = storageAccount.name
