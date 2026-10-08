#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication
# Project-Version: 1.3.20261007.4
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

    if ($null -eq $Response) {
        return @()
    }
    if ($Response -is [System.Collections.IDictionary] -and $Response.Contains('value')) {
        return @($Response['value'])
    }
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
if ($ForceGraphSignIn) {
    Disconnect-MgGraph -SignOutFromBroker -ErrorAction SilentlyContinue | Out-Null
    $graphConnectParameters.UseDeviceCode = $true
    Write-Host "Sign in with the Entra administrator for tenant '$TenantId'."
}
Connect-MgGraph @graphConnectParameters

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

    if ($applications.Count -gt 1) {
        throw "More than one Entra application named '$DisplayName' exists. Pass -EntraClientId explicitly."
    }

    $application = $applications | Select-Object -First 1
}
else {
    $parsedClientId = [guid]::Empty
    if (-not [guid]::TryParse($ClientId, [ref] $parsedClientId)) {
        throw 'Entra API application Client ID must be a GUID.'
    }

    $filter = [uri]::EscapeDataString("appId eq '$ClientId'")
    $response = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=$filter&`$select=id,appId,displayName,identifierUris,groupMembershipClaims,api,appRoles"
    $application = @(Get-GraphCollectionItems -Response $response) | Select-Object -First 1
    if (-not $application) {
        throw "No Entra application with Client ID '$ClientId' was found in tenant '$TenantId'."
    }
}

if (-not $application) {
    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'Create Entra API application')) {
        return
    }

    $application = Invoke-MgGraphRequest `
        -Method POST `
        -Uri 'https://graph.microsoft.com/v1.0/applications' `
        -Body @{
            displayName    = $DisplayName
            signInAudience = 'AzureADMyOrg'
        }
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
$otherPreAuthorizedApplications = @(
    $application.api.preAuthorizedApplications |
        Where-Object appId -ne $azurePowerShellClientId |
        ForEach-Object { $_ | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable }
)
$identifierUris = @($application.identifierUris | ForEach-Object { [string] $_ })

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

$scopeNeedsUpdate = $null -eq $scope -or
    -not $scope.isEnabled -or
    $scope.type -ne 'Admin'
$apiConfigurationNeedsUpdate =
    $applicationIdUri -notin $identifierUris -or
    $application.groupMembershipClaims -ne 'SecurityGroup' -or
    $application.api.requestedAccessTokenVersion -ne 2 -or
    $scopeNeedsUpdate

if ($apiConfigurationNeedsUpdate -and
    $PSCmdlet.ShouldProcess($applicationIdUri, 'Configure API scope')) {
    $updateJson = $updateBody | ConvertTo-Json -Depth 20 -Compress
    try {
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

# Azure PowerShell is the public client used by Get-AzAccessToken in the shipped
# PowerShell tools. Preauthorization avoids an additional interactive consent
# prompt while still limiting the client to the DeviceHash.Import scope.
$existingPreAuthorization = @($application.api.preAuthorizedApplications |
    Where-Object appId -eq $azurePowerShellClientId) |
    Select-Object -First 1
$preAuthorizationNeedsUpdate = $null -eq $existingPreAuthorization -or
    $scopeId -notin @($existingPreAuthorization.delegatedPermissionIds)
if ($preAuthorizationNeedsUpdate -and
    $PSCmdlet.ShouldProcess($applicationIdUri, 'Preauthorize Azure PowerShell')) {
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
$servicePrincipalFilter = [uri]::EscapeDataString("appId eq '$($application.appId)'")
$servicePrincipalResponse = Invoke-MgGraphRequest `
    -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$servicePrincipalFilter&`$select=id,appId,appRoleAssignmentRequired"
$servicePrincipal = @(Get-GraphCollectionItems -Response $servicePrincipalResponse) |
    Select-Object -First 1

if (-not $servicePrincipal -and $PSCmdlet.ShouldProcess($DisplayName, 'Create enterprise application')) {
    $servicePrincipal = Invoke-MgGraphRequest `
        -Method POST `
        -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals' `
        -Body @{ appId = [string] $application.appId }
}

# Authorization is enforced by Easy Auth and the Function endpoints. Requiring
# an enterprise-app assignment here would add a second, unintended access gate.
if ($servicePrincipal -and $servicePrincipal.appRoleAssignmentRequired -and
    $PSCmdlet.ShouldProcess($DisplayName, 'Allow endpoint-level authorization')) {
    Invoke-MgGraphRequest `
        -Method PATCH `
        -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($servicePrincipal.id)" `
        -Body @{ appRoleAssignmentRequired = $false } | Out-Null
}

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