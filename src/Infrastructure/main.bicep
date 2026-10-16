/*
Autopilot Import infrastructure deployed into the selected resource group.

Creates a PowerShell Function App on a Consumption plan, private configuration
storage, an audit/state table, workspace-based monitoring and Storage data roles.
Easy Auth protects the API while the frontend remains publicly accessible.

The installer separately configures the Entra API/web applications, assigns
Microsoft Graph permissions, uploads the policy blob and publishes Function code.
Those operations, custom-domain bindings and certificates are not defined here.
Azure Storage RBAC assignments below do not grant Microsoft Graph permissions.

Resource references establish deployment dependencies automatically. Reusing the
same parameters/resource group targets the same names and role-assignment GUIDs;
an update can still reconcile settings on existing resources.
*/

// API and web client IDs refer to separate, existing Entra app registrations.
// The deploying tenant supplies the token issuer and frontend authority.
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

// Storage names permit only lowercase letters/digits and at most 24 characters.
// A resource-group-derived suffix participates in this deterministic name;
// changing the app name or resource group can therefore select a new account.
var storageAccountName = take(toLower(replace('${functionAppName}${uniqueString(resourceGroup().id)}', '-', '')), 24)
var applicationInsightsName = '${functionAppName}-insights'
var logAnalyticsWorkspaceName = '${functionAppName}-la'
var hostingPlanName = '${functionAppName}-plan'
// Well-known Azure PowerShell public-client ID used by the command-line client.
// This is an application identifier, not a client secret.
var azurePowerShellClientId = '1950a258-227b-4e31-a9cf-717495945fc2'
// Data-plane roles are separate from Azure management-plane Contributor.
// The role definitions are referenced at subscription scope; assignments below
// are limited to this deployment's Storage Account.
var storageBlobDataOwnerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
var storageBlobDataContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
var storageQueueDataContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
var storageTableDataContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')

// Shared backing account for the Functions host, policy blob, processing queues
// and audit/state table. Queue bindings use this account at runtime; individual
// application queues are not explicitly provisioned by this template.
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  #disable-next-line BCP334 // uniqueString guarantees 13 characters after replacement.
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    // Public network reachability is needed by this non-VNet Consumption setup.
    // It does not make blobs anonymous: public blob access is disabled, and the
    // configuration container below also denies anonymous reads.
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Enabled'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

// Child service resources provide explicit parents for containers and tables.
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

// The installer uploads tag-authorization-policy.json here. The container is
// created empty; policy content is not embedded as a blob resource.
resource configurationContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'configuration'
  properties: {
    publicAccess: 'None'
  }
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

// The application separates history ("imports") and persistent device-group
// tracking ("devicePolicies") with partition keys in this same table.
// Application retention cleanup is independent of telemetry retention below.
resource importAuditTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tableService
  name: 'importaudit'
}

// Keep telemetry in a dedicated workspace with 30-day retention. PerGB2018 is
// usage-based billing; this setting does not limit daily ingestion or cost.
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

// Workspace-based Application Insights receives Function telemetry. Its
// connection string is passed to the worker rather than configured manually.
resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: applicationInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
  }
}

// Y1/Dynamic selects Consumption hosting; there is no fixed worker size here.
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
    // Azure manages this service principal's lifecycle with the Function App.
    // profile.ps1 uses it for Azure sign-in and subsequent Graph token requests.
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: hostingPlan.id
    httpsOnly: true
    siteConfig: {
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        // Identity-based host Storage connection: no account key/connection
        // string is supplied by these settings. Data-role grants follow below.
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storageAccount.name
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'IMPORT_AUDIT_TABLE_NAME'
          value: importAuditTable.name
        }
        // Functions host major version and PowerShell worker/runtime selection.
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
          // Enables the repository's proxies.json routing configuration.
          name: 'AzureWebJobsFeatureFlags'
          value: 'EnableProxies'
        }
        {
          // Execute the published ZIP as a mounted package rather than relying
          // on individual source-file changes in the deployed wwwroot.
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '1'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: applicationInsights.properties.ConnectionString
        }
        {
          // Legacy policy fallback; current handlers prefer the configuration
          // blob. Manager authorization remains in its separate app setting.
          name: 'TAG_AUTHORIZATION_POLICY'
          value: tagAuthorizationPolicy
        }
        {
          name: 'MANAGER_AUTHORIZATION_POLICY'
          value: managerAuthorizationPolicy
        }
        {
          // Lets management code identify the Azure resource whose effective
          // administrative permissions must be evaluated.
          name: 'FUNCTION_RESOURCE_ID'
          value: resourceId('Microsoft.Web/sites', functionAppName)
        }
        {
          // Legacy tag-to-attribute default; named policies may define their
          // own explicit extension-attribute actions instead.
          name: 'DEVICE_TAG_EXTENSION_ATTRIBUTE'
          value: deviceTagExtensionAttribute
        }
        {
          // Public browser/API identifiers used to generate /api/ui/config.
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

// Deterministic assignment names avoid creating a new grant on every deploy.
// Blob Data Owner supports identity-based host blob operations and policy reads.
resource functionStorageBlobDataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, storageBlobDataOwnerRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: storageBlobDataOwnerRoleId
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Allows queue triggers/output bindings to read, enqueue and delete work items,
// including the downstream device-processing workflow.
resource functionStorageQueueDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, storageQueueDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: storageQueueDataContributorRoleId
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Allows the app to write audit/state entities and delete expired history.
resource functionStorageTableDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, storageTableDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: storageTableDataContributorRoleId
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// The installing user needs blob data access to upload policy configuration.
// This grant does not provide table/queue access or Azure role administration.
resource installerStorageBlobDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, installerPrincipalId, storageBlobDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: storageBlobDataContributorRoleId
    principalId: installerPrincipalId
    principalType: 'User'
  }
}

// Easy Auth validates requests before the PowerShell handlers execute and
// supplies the trusted x-ms-client-principal header they consume.
resource authentication 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: functionApp
  name: 'authsettingsV2'
  properties: {
    platform: {
      enabled: true
      runtimeVersion: '~1'
    }
    globalValidation: {
      // APIs return 401 instead of redirecting to interactive sign-in. The
      // public frontend starts its own MSAL flow and then calls protected APIs.
      requireAuthentication: true
      unauthenticatedClientAction: 'Return401'
      excludedPaths: [
        // Permit the root/frontend routes, not the device/management APIs.
        '/'
        '/api/ui/*'
      ]
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          // Bind validation to the API application and the deployment tenant.
          clientId: entraClientId
          openIdIssuer: '${environment().authentication.loginEndpoint}${tenant().tenantId}/v2.0'
        }
        validation: {
          // Accept either the API's configured URI audience or its client ID.
          allowedAudiences: [
            apiAudience
            entraClientId
          ]
          defaultAuthorizationPolicy: {
            // Restrict calling client applications to Azure PowerShell and,
            // when configured, this deployment's SPA. This does not replace
            // per-user Group Tag/manager authorization inside the handlers.
            allowedApplications: empty(webClientId)
              ? [azurePowerShellClientId]
              : [azurePowerShellClientId, webClientId]
          }
        }
      }
    }
    login: {
      tokenStore: {
        // The SPA/client manages its own tokens; no Easy Auth token store.
        enabled: false
      }
    }
    httpSettings: {
      requireHttps: true
    }
  }
}

// The installer consumes these endpoints/IDs for client settings, smoke tests,
// Graph permission grants and policy upload. URLs use the Azure default host;
// custom-domain configuration is handled separately.
output functionUrl string = 'https://${functionApp.properties.defaultHostName}/api/devices/import'
output managementUrl string = 'https://${functionApp.properties.defaultHostName}/api/management/tag-policy'
output webUrl string = 'https://${functionApp.properties.defaultHostName}/api/ui/index.html'
output managedIdentityObjectId string = functionApp.identity.principalId
output storageAccountName string = storageAccount.name
