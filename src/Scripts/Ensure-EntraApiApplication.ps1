#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication
# Project-Version: 1.4.20261022.1
# Author: andreas.lucas@outlook.com (aka Kili)

# Copyright 2026 Andreas Lucas
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the project root for license information.

<#
.SYNOPSIS
Creates or updates the Entra application used by the Autopilot import API.

.DESCRIPTION
Ensures an Entra app registration and enterprise application exist for the
Function API. The installer uses the returned application and scope identifiers
to configure the web app registration, Easy Auth, and the Function App's token
audience.

The script performs the following operations:
- Finds the app registration by client ID or display name, or creates it.
- Exposes the DeviceHash.Import delegated permission with an api:// application
  ID URI and version 2 access tokens.
- Adds security group claims used for Group Tag authorization.
- Preauthorizes Azure PowerShell for the delegated permission because the
  shipped PowerShell clients acquire API tokens through Get-AzAccessToken.
- Creates the corresponding service principal and permits endpoint-level
  authorization instead of requiring an enterprise-app role assignment.

The operation is idempotent and preserves unrelated scopes, roles, application
ID URIs, and preauthorized clients.

.PARAMETER TenantId
GUID of the Microsoft Entra tenant in which to manage the application.

.PARAMETER ClientId
Application (client) ID of an existing app registration. When omitted, the
script searches for an application whose display name matches DisplayName and
creates it when no match exists.

.PARAMETER DisplayName
Display name used to find or create the app registration. The default is
Autopilot Import API.

.PARAMETER ForceGraphSignIn
Signs out the cached Microsoft Graph account and uses device-code
authentication to select an account explicitly.

.EXAMPLE
.\scripts\Ensure-EntraApiApplication.ps1 `
    -TenantId '11111111-1111-1111-1111-111111111111'

Creates or updates the default API application.

.EXAMPLE
.\scripts\Ensure-EntraApiApplication.ps1 `
    -TenantId '11111111-1111-1111-1111-111111111111' `
    -ClientId '33333333-3333-3333-3333-333333333333' `
    -WhatIf

Previews changes to a specific existing application.

.OUTPUTS
PSCustomObject containing the app registration client and object IDs, enterprise
application object ID, API Application ID URI, delegated scope name and ID, and
the installing user's object ID and user principal name.

.NOTES
Requires Microsoft.Graph.Authentication and delegated permissions
Application.ReadWrite.All and User.Read.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [guid] $TenantId,

    [string] $ClientId,

    [string] $DisplayName = 'Autopilot Import API',

    [switch] $ForceGraphSignIn
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$azurePowerShellClientId = '1950a258-227b-4e31-a9cf-717495945fc2'
$scopeValue = 'DeviceHash.Import'

function Get-GraphCollectionItems {
    <#
    .SYNOPSIS
    Normalizes Microsoft Graph collection responses to a PowerShell array.

    .DESCRIPTION
    Invoke-MgGraphRequest can return a dictionary, a deserialized object with a
    value property, or a single object depending on module and response shape.
    This helper gives the discovery queries one consistent collection shape.
    #>
    param(
        [object] $Response
    )
    # Return an empty array if the response is null.
    if ($null -eq $Response) {
        return @()
    }
    # Return the 'value' property if it exists in the response dictionary.
    if ($Response -is [System.Collections.IDictionary] -and $Response.Contains('value')) {
        return @($Response['value'])
    }
    # Return the 'value' property if it exists as a PSObject property.
    if ($Response.PSObject.Properties.Name -contains 'value') {
        return @($Response.value)
    }
    return @($Response)
}

# Use delegated Graph permissions so the administrator performing installation
# remains visible and can be passed to the infrastructure deployment.
$graphConnectParameters = @{
    TenantId  = $TenantId
    Scopes    = @('Application.ReadWrite.All', 'User.Read')
    NoWelcome = $true
}
# Prompt for Graph sign-in if forced.
if ($ForceGraphSignIn) {
    Disconnect-MgGraph -SignOutFromBroker -ErrorAction SilentlyContinue | Out-Null
    $graphConnectParameters.UseDeviceCode = $true
    Write-Host "Sign in with the Entra administrator for tenant '$TenantId'."
}
# Connect to Microsoft Graph with the prepared parameters.
Connect-MgGraph @graphConnectParameters
# Retrieve information about the currently signed-in user.
$installingUser = Invoke-MgGraphRequest `
    -Method GET `
    -Uri 'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName'

# Prefer a stable client ID when supplied. Display-name discovery supports the
# first installation, but rejects duplicates rather than updating an arbitrary
# app registration.
if ([string]::IsNullOrWhiteSpace($ClientId)) {
    $escapedDisplayName = $DisplayName.Replace("'", "''")
    $filter = [uri]::EscapeDataString("displayName eq '$escapedDisplayName'")
    $response = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=$filter&`$select=id,appId,displayName,identifierUris,groupMembershipClaims,api,appRoles"
    $applications = @(Get-GraphCollectionItems -Response $response)
    # Throw an error if multiple applications with the same display name are found.
    if ($applications.Count -gt 1) {
        throw "More than one Entra application named '$DisplayName' exists. Pass -EntraClientId explicitly."
    }

    $application = $applications | Select-Object -First 1
}
else {
    # Validate that the provided Client ID is a GUID.
    $parsedClientId = [guid]::Empty
    # Attempt to parse the Client ID as a GUID.
    if (-not [guid]::TryParse($ClientId, [ref] $parsedClientId)) {
        throw 'Entra API application Client ID must be a GUID.'
    }
    # If parsing succeeds, $parsedClientId contains the valid GUID.
    $filter = [uri]::EscapeDataString("appId eq '$ClientId'")
    # Prepare the filter for querying the application by its App ID.
    $response = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=$filter&`$select=id,appId,displayName,identifierUris,groupMembershipClaims,api,appRoles"
    $application = @(Get-GraphCollectionItems -Response $response) | Select-Object -First 1
    if (-not $application) {
        throw "No Entra application with Client ID '$ClientId' was found in tenant '$TenantId'."
    }
}

# If no application was found, prompt to create a new one.
if (-not $application) {
    # Confirm with the user before creating a new Entra API application.
    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'Create Entra API application')) {
        return
    }
    # Create the new Entra API application using Microsoft Graph.
    $application = Invoke-MgGraphRequest `
        -Method POST `
        -Uri 'https://graph.microsoft.com/v1.0/applications' `
        -Body @{
            displayName    = $DisplayName
            signInAudience = 'AzureADMyOrg'
        }
    # Convert the response to a usable object if necessary.
    Write-Host "Created Entra application '$DisplayName' ($($application.appId))."
}
else {
    Write-Host "Using existing Entra application '$($application.displayName)' ($($application.appId))."
}

# Reuse the existing scope ID because changing it would invalidate delegated
# permission grants held by the web and PowerShell clients.
$scope = @($application.api.oauth2PermissionScopes | Where-Object value -eq $scopeValue) |
    Select-Object -First 1
$scopeId = if ($scope) { [string] $scope.id } else { [guid]::NewGuid().ToString() }
$applicationIdUri = "api://$($application.appId)"

# Microsoft Graph replaces nested API collections during PATCH operations.
# Retain every scope, preauthorized client, and identifier URI not managed here.
$otherScopes = @($application.api.oauth2PermissionScopes | Where-Object value -ne $scopeValue |
    ForEach-Object { $_ | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable })
# Convert the pre-existing scopes to hashtables to retain them during the update.
$otherPreAuthorizedApplications = @(
    $application.api.preAuthorizedApplications |
        Where-Object appId -ne $azurePowerShellClientId |
        ForEach-Object { $_ | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable }
)
# Convert the pre-existing identifier URIs to strings to retain them during the update.
$identifierUris = @($application.identifierUris | ForEach-Object { [string] $_ })
# Prepare the body for the PATCH request to update the application.
$updateBody = @{
    identifierUris = @($identifierUris + $applicationIdUri | Select-Object -Unique)
    groupMembershipClaims = 'SecurityGroup'
    api = @{
        requestedAccessTokenVersion = 2
        oauth2PermissionScopes      = @($otherScopes) + @(
            @{
                id                         = $scopeId
                value                      = $scopeValue
                type                       = 'Admin'
                isEnabled                  = $true
                adminConsentDisplayName    = 'Import Autopilot device hashes'
                adminConsentDescription    = 'Allows users to call the Autopilot import function.'
                userConsentDisplayName     = $null
                userConsentDescription     = $null
            }
        )
    }
}
# Determine if the scope or API configuration needs to be updated.
$scopeNeedsUpdate = $null -eq $scope -or
    -not $scope.isEnabled -or
    $scope.type -ne 'Admin'
# Determine if the API configuration needs to be updated based on the current application state.
$apiConfigurationNeedsUpdate =
    $applicationIdUri -notin $identifierUris -or
    $application.groupMembershipClaims -ne 'SecurityGroup' -or
    $application.api.requestedAccessTokenVersion -ne 2 -or
    $scopeNeedsUpdate
# Update the application if the API configuration needs to be changed.
if ($apiConfigurationNeedsUpdate -and
    $PSCmdlet.ShouldProcess($applicationIdUri, 'Configure API scope')) {
    Write-Host "Updating Entra application API configuration..."
    $updateJson = $updateBody | ConvertTo-Json -Depth 20 -Compress
    try {
        # Send the PATCH request to update the Entra application with the new API configuration.
        Invoke-MgGraphRequest `
            -Method PATCH `
            -Uri "https://graph.microsoft.com/v1.0/applications/$($application.id)" `
            -Body $updateJson `
            -ContentType 'application/json' | Out-Null
    }
    catch {
        if ($_.Exception.Message -match '403|Authorization_RequestDenied') {
            throw "Updating Entra application '$DisplayName' requires ownership of the application or the Application Administrator or Cloud Application Administrator role. $($_.Exception.Message)"
        }
        throw
    }
}
elseif (-not $apiConfigurationNeedsUpdate) {
    Write-Host "Entra application API configuration is already current."
}
# Determine if Azure PowerShell preauthorization needs to be updated for the application.
# Azure PowerShell is the public client used by Get-AzAccessToken in the shipped
# PowerShell tools. Preauthorization avoids an additional interactive consent
# prompt while still limiting the client to the DeviceHash.Import scope.
$existingPreAuthorization = @($application.api.preAuthorizedApplications |
    Where-Object appId -eq $azurePowerShellClientId) |
    Select-Object -First 1
# Determine if the existing preauthorization includes the required scope for Azure PowerShell.
$preAuthorizationNeedsUpdate = $null -eq $existingPreAuthorization -or
    $scopeId -notin @($existingPreAuthorization.delegatedPermissionIds)
# Update the preauthorization if necessary.
if ($preAuthorizationNeedsUpdate -and
    $PSCmdlet.ShouldProcess($applicationIdUri, 'Preauthorize Azure PowerShell')) {
    # Prepare the body for the PATCH request to update the preauthorization for Azure PowerShell.
    $preAuthorizationBody = @{
        api = @{
            requestedAccessTokenVersion = 2
            oauth2PermissionScopes      = $updateBody.api.oauth2PermissionScopes
            preAuthorizedApplications  = @($otherPreAuthorizedApplications) + @(
                @{
                    appId                  = $azurePowerShellClientId
                    delegatedPermissionIds = @($scopeId)
                }
            )
        }
    } | ConvertTo-Json -Depth 20 -Compress
    # Send the PATCH request to update the preauthorization for Azure PowerShell.
    try {
        Invoke-MgGraphRequest `
            -Method PATCH `
            -Uri "https://graph.microsoft.com/v1.0/applications/$($application.id)" `
            -Body $preAuthorizationBody `
            -ContentType 'application/json' | Out-Null
    }
    catch {
        if ($_.Exception.Message -match '403|Authorization_RequestDenied') {
            throw "Preauthorizing Azure PowerShell for Entra application '$DisplayName' requires ownership of the application or the Application Administrator or Cloud Application Administrator role. $($_.Exception.Message)"
        }
        throw
    }
}
elseif (-not $preAuthorizationNeedsUpdate) {
    Write-Host 'Azure PowerShell is already preauthorized for the API scope.'
}

# The app registration defines the API. Its tenant-local service principal is
# the enterprise application evaluated when callers request and present tokens.
# Retrieve the service principal for the application to manage its configuration.
$servicePrincipalFilter = [uri]::EscapeDataString("appId eq '$($application.appId)'")
$servicePrincipalResponse = Invoke-MgGraphRequest `
    -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$servicePrincipalFilter&`$select=id,appId,appRoleAssignmentRequired"
$servicePrincipal = @(Get-GraphCollectionItems -Response $servicePrincipalResponse) |
    Select-Object -First 1

# Create the service principal if it does not exist.
if (-not $servicePrincipal -and $PSCmdlet.ShouldProcess($DisplayName, 'Create enterprise application')) {
    $servicePrincipal = Invoke-MgGraphRequest `
        -Method POST `
        -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals' `
        -Body @{ appId = [string] $application.appId }
}

# Disable app role assignment requirement for the service principal to allow endpoint-level authorization.
if ($servicePrincipal -and $servicePrincipal.appRoleAssignmentRequired -and
    $PSCmdlet.ShouldProcess($DisplayName, 'Allow endpoint-level authorization')) {
    Invoke-MgGraphRequest `
        -Method PATCH `
        -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($servicePrincipal.id)" `
        -Body @{ appRoleAssignmentRequired = $false } | Out-Null
}
# Output a summary of the application and service principal configuration.
[pscustomobject]@{
    DisplayName              = [string] $application.displayName
    ClientId                 = [string] $application.appId
    ApplicationObjectId      = [string] $application.id
    ServicePrincipalObjectId = if ($servicePrincipal) { [string] $servicePrincipal.id } else { $null }
    ApplicationIdUri         = $applicationIdUri
    Scope                    = $scopeValue
    ScopeId                  = $scopeId
    InstallingUserObjectId   = [string] $installingUser.id
    InstallingUserPrincipalName = [string] $installingUser.userPrincipalName
}