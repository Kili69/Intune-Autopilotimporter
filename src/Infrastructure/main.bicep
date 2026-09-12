@description('Globally unique name of the Azure Function App.')
@minLength(2)
@maxLength(60)
param functionAppName string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Client ID of the Entra app registration that protects the Function API.')
param entraClientId string

@description('Client ID of the single-page application used by the web frontend.')
param webClientId string = ''

@description('Application ID URI configured under Expose an API.')
param apiAudience string = 'api://${entraClientId}'

@description('JSON policy mapping Entra group object IDs to allowed Autopilot Group Tags.')
@minLength(2)
param tagAuthorizationPolicy string

@description('JSON policy containing users and groups allowed to manage Group Tags.')
@minLength(2)
param managerAuthorizationPolicy string

@description('Entra device extension attribute that receives the authorized Autopilot Group Tag.')
@allowed([
  'extensionAttribute1'
  'extensionAttribute2'
  'extensionAttribute3'
  'extensionAttribute4'
  'extensionAttribute5'
  'extensionAttribute6'
  'extensionAttribute7'
  'extensionAttribute8'
  'extensionAttribute9'
  'extensionAttribute10'
  'extensionAttribute11'
  'extensionAttribute12'
  'extensionAttribute13'
  'extensionAttribute14'
  'extensionAttribute15'
])
param deviceTagExtensionAttribute string = 'extensionAttribute1'

@description('Object ID of the user performing the deployment and initial policy upload.')
param installerPrincipalId string

var storageAccountName = take(toLower(replace('${functionAppName}${uniqueString(resourceGroup().id)}', '-', '')), 24)
var applicationInsightsName = '${functionAppName}-insights'
var logAnalyticsWorkspaceName = '${functionAppName}-la'
var hostingPlanName = '${functionAppName}-plan'
var azurePowerShellClientId = '1950a258-227b-4e31-a9cf-717495945fc2'
var storageBlobDataOwnerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
var storageBlobDataContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
var storageQueueDataContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')

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
    publicNetworkAccess: 'Enabled'
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

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  properties: {
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: applicationInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
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
          name: 'AzureWebJobsStorage__accountName'
          value: storageAccount.name
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
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
          name: 'AzureWebJobsDisableHomepage'
          value: 'true'
        }
        {
          name: 'AzureWebJobsFeatureFlags'
          value: 'EnableProxies'
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
        {
          name: 'DEVICE_TAG_EXTENSION_ATTRIBUTE'
          value: deviceTagExtensionAttribute
        }
        {
          name: 'WEB_CLIENT_ID'
          value: webClientId
        }
        {
          name: 'API_AUDIENCE'
          value: apiAudience
        }
        {
          name: 'TENANT_ID'
          value: tenant().tenantId
        }
      ]
    }
  }
}

resource functionStorageBlobDataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, storageBlobDataOwnerRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: storageBlobDataOwnerRoleId
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource functionStorageQueueDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, storageQueueDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: storageQueueDataContributorRoleId
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource installerStorageBlobDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, installerPrincipalId, storageBlobDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: storageBlobDataContributorRoleId
    principalId: installerPrincipalId
    principalType: 'User'
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
      excludedPaths: [
        '/'
        '/api/ui/*'
      ]
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
            entraClientId
          ]
          defaultAuthorizationPolicy: {
            allowedApplications: empty(webClientId)
              ? [azurePowerShellClientId]
              : [azurePowerShellClientId, webClientId]
          }
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
output webUrl string = 'https://${functionApp.properties.defaultHostName}/api/ui/index.html'
output managedIdentityObjectId string = functionApp.identity.principalId
output storageAccountName string = storageAccount.name
