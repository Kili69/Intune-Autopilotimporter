@description('Globally unique name of the Azure Function App.')
@minLength(2)
@maxLength(60)
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

@description('Controls whether the Function host Storage Account uses public or private data endpoints.')
@allowed([
  'Public'
  'Private'
])
param storageNetworkAccess string = 'Public'

var storageAccountName = take(toLower(replace('${functionAppName}${uniqueString(resourceGroup().id)}', '-', '')), 24)
var applicationInsightsName = '${functionAppName}-insights'
var hostingPlanName = '${functionAppName}-plan'
var virtualNetworkName = '${functionAppName}-vnet'
var functionSubnetName = 'function-integration'
var privateEndpointSubnetName = 'private-endpoints'
var deploymentContainerName = 'function-releases'
var deploymentIdentityName = '${functionAppName}-storage'
var usePrivateStorage = storageNetworkAccess == 'Private'
var azurePowerShellClientId = '1950a258-227b-4e31-a9cf-717495945fc2'
var storageBlobDataOwnerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
var storageBlobDataContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
var storageQueueDataContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
var storageTableDataContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
var storageAppSettings = usePrivateStorage ? [
  {
    name: 'AzureWebJobsStorage__blobServiceUri'
    value: storageAccount.properties.primaryEndpoints.blob
  }
  {
    name: 'AzureWebJobsStorage__queueServiceUri'
    value: storageAccount.properties.primaryEndpoints.queue
  }
  {
    name: 'AzureWebJobsStorage__tableServiceUri'
    value: storageAccount.properties.primaryEndpoints.table
  }
  {
    name: 'AzureWebJobsStorage__credential'
    value: 'managedidentity'
  }
  {
    name: 'AzureWebJobsStorage__clientId'
    value: deploymentIdentity!.properties.clientId
  }
] : [
  {
    name: 'AzureWebJobsStorage__accountName'
    value: storageAccount.name
  }
  {
    name: 'AzureWebJobsStorage__credential'
    value: 'managedidentity'
  }
]
var commonAppSettings = [
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
]
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
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    publicNetworkAccess: usePrivateStorage ? 'Disabled' : 'Enabled'
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

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = if (usePrivateStorage) {
  parent: blobService
  name: deploymentContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource deploymentIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (usePrivateStorage) {
  name: deploymentIdentityName
  location: location
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = if (usePrivateStorage) {
  name: virtualNetworkName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.42.0.0/24'
      ]
    }
  }
}

resource functionIntegrationSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = if (usePrivateStorage) {
  parent: virtualNetwork
  name: functionSubnetName
  properties: {
    addressPrefix: '10.42.0.0/27'
    delegations: [
      {
        name: 'flex-consumption'
        properties: {
          serviceName: 'Microsoft.App/environments'
        }
      }
    ]
  }
}

resource privateEndpointSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = if (usePrivateStorage) {
  parent: virtualNetwork
  name: privateEndpointSubnetName
  properties: {
    addressPrefix: '10.42.0.32/28'
    privateEndpointNetworkPolicies: 'Disabled'
  }
}

resource blobPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (usePrivateStorage) {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  location: 'global'
}

resource queuePrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (usePrivateStorage) {
  name: 'privatelink.queue.${environment().suffixes.storage}'
  location: 'global'
}

resource tablePrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (usePrivateStorage) {
  name: 'privatelink.table.${environment().suffixes.storage}'
  location: 'global'
}

resource blobPrivateDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (usePrivateStorage) {
  parent: blobPrivateDnsZone
  name: virtualNetworkName
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

resource queuePrivateDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (usePrivateStorage) {
  parent: queuePrivateDnsZone
  name: virtualNetworkName
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

resource tablePrivateDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (usePrivateStorage) {
  parent: tablePrivateDnsZone
  name: virtualNetworkName
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

resource blobPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = if (usePrivateStorage) {
  name: '${storageAccount.name}-blob-pe'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'blob'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
}

resource queuePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = if (usePrivateStorage) {
  name: '${storageAccount.name}-queue-pe'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'queue'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'queue'
          ]
        }
      }
    ]
  }
}

resource tablePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = if (usePrivateStorage) {
  name: '${storageAccount.name}-table-pe'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'table'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'table'
          ]
        }
      }
    ]
  }
}

resource blobPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = if (usePrivateStorage) {
  parent: blobPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: {
          privateDnsZoneId: blobPrivateDnsZone.id
        }
      }
    ]
  }
}

resource queuePrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = if (usePrivateStorage) {
  parent: queuePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'queue'
        properties: {
          privateDnsZoneId: queuePrivateDnsZone.id
        }
      }
    ]
  }
}

resource tablePrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = if (usePrivateStorage) {
  parent: tablePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'table'
        properties: {
          privateDnsZoneId: tablePrivateDnsZone.id
        }
      }
    ]
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

resource hostingPlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: hostingPlanName
  location: location
  kind: usePrivateStorage ? 'functionapp' : 'functionapp'
  sku: {
    name: usePrivateStorage ? 'FC1' : 'Y1'
    tier: usePrivateStorage ? 'FlexConsumption' : 'Dynamic'
  }
  properties: {
    reserved: usePrivateStorage
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  kind: usePrivateStorage ? 'functionapp,linux' : 'functionapp'
  identity: {
    type: usePrivateStorage ? 'SystemAssigned, UserAssigned' : 'SystemAssigned'
    userAssignedIdentities: usePrivateStorage ? {
      '${deploymentIdentity.id}': {}
    } : {}
  }
  properties: {
    serverFarmId: hostingPlan.id
    publicNetworkAccess: 'Enabled'
    httpsOnly: true
    siteConfig: {
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: concat(storageAppSettings, commonAppSettings, usePrivateStorage ? [] : [
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '1'
        }
      ])
    }
    virtualNetworkSubnetId: usePrivateStorage ? functionIntegrationSubnet.id : null
    functionAppConfig: usePrivateStorage ? {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageAccount.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: deploymentIdentity.id
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 100
        instanceMemoryMB: 2048
      }
      runtime: {
        name: 'powershell'
        version: '7.4'
      }
    } : null
  }
  dependsOn: usePrivateStorage ? [
    deploymentContainer
    deploymentIdentityStorageBlobDataOwner
    deploymentIdentityStorageQueueDataContributor
    deploymentIdentityStorageTableDataContributor
    blobPrivateDnsZoneGroup
    queuePrivateDnsZoneGroup
    tablePrivateDnsZoneGroup
  ] : []
}

resource functionStorageBlobDataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!usePrivateStorage) {
  name: guid(storageAccount.id, functionApp.id, storageBlobDataOwnerRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: storageBlobDataOwnerRoleId
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource functionStorageQueueDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!usePrivateStorage) {
  name: guid(storageAccount.id, functionApp.id, storageQueueDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: storageQueueDataContributorRoleId
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource installerStorageBlobDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!usePrivateStorage) {
  name: guid(storageAccount.id, installerPrincipalId, storageBlobDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: storageBlobDataContributorRoleId
    principalId: installerPrincipalId
    principalType: 'User'
  }
}

resource deploymentIdentityStorageBlobDataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (usePrivateStorage) {
  name: guid(storageAccount.id, deploymentIdentity.id, storageBlobDataOwnerRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: storageBlobDataOwnerRoleId
    principalId: deploymentIdentity!.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource deploymentIdentityStorageQueueDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (usePrivateStorage) {
  name: guid(storageAccount.id, deploymentIdentity.id, storageQueueDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: storageQueueDataContributorRoleId
    principalId: deploymentIdentity!.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource deploymentIdentityStorageTableDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (usePrivateStorage) {
  name: guid(storageAccount.id, deploymentIdentity.id, storageTableDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: storageTableDataContributorRoleId
    principalId: deploymentIdentity!.properties.principalId
    principalType: 'ServicePrincipal'
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
            entraClientId
          ]
          defaultAuthorizationPolicy: {
            allowedApplications: [
              azurePowerShellClientId
            ]
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
output managedIdentityObjectId string = functionApp.identity.principalId
output storageAccountName string = storageAccount.name
output storageNetworkAccess string = storageNetworkAccess
