#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication
# Project-Version: 1.0.20260811.2
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
DISCLAIMER:
This sample script is not supported under any Microsoft standard support program or service.
The sample script is provided AS IS without warranty of any kind. Microsoft further disclaims
all implied warranties including, without limitation, any implied warranties of merchantability
or of fitness for a particular purpose. The entire risk arising out of the use or performance of
the sample scripts and documentation remains with you. In no event shall Microsoft, its authors,
or anyone else involved in the creation, production, or delivery of the scripts be liable for any
damages whatsoever (including, without limitation, damages for loss of business profits, business
interruption, loss of business information, or other pecuniary loss) arising out of the use of or
inability to use the sample scripts or documentation, even if Microsoft has been advised of the
possibility of such damages.
#>

<#
.SYNOPSIS
Creates or updates the Entra application used by the Autopilot import API.

.DESCRIPTION
Ensures an Entra app registration and enterprise application exist for the
Function API. Configures a delegated API scope, an application role, security
group claims, assignment requirements, Azure PowerShell preauthorization, and
optional group-to-app-role assignments.

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

.PARAMETER RequiredRole
App-role value assigned to authorized groups and required by the Function. The
default is DeviceHash.Importer.

.PARAMETER AuthorizedGroupId
One or more Entra security group object IDs that receive the required app role.

.EXAMPLE
.\scripts\Ensure-EntraApiApplication.ps1 `
    -TenantId '11111111-1111-1111-1111-111111111111' `
    -AuthorizedGroupId '22222222-2222-2222-2222-222222222222'

Creates or updates the default API application and authorizes one group.

.EXAMPLE
.\scripts\Ensure-EntraApiApplication.ps1 `
    -TenantId '11111111-1111-1111-1111-111111111111' `
    -ClientId '33333333-3333-3333-3333-333333333333' `
    -AuthorizedGroupId '22222222-2222-2222-2222-222222222222' `
    -WhatIf

Previews changes to a specific existing application.

.OUTPUTS
PSCustomObject describing the app registration, enterprise application, API
Application ID URI, delegated scope, and app role.

.NOTES
Requires Microsoft.Graph.Authentication and delegated permissions
Application.ReadWrite.All, AppRoleAssignment.ReadWrite.All, and Group.Read.All.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [guid] $TenantId,

    [string] $ClientId,

    [string] $DisplayName = 'Autopilot Import API',

    [string] $RequiredRole = 'DeviceHash.Importer',

    [guid[]] $AuthorizedGroupId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$azurePowerShellClientId = '1950a258-227b-4e31-a9cf-717495945fc2'
$scopeValue = 'DeviceHash.Import'

function Get-GraphCollectionItems {
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

Connect-MgGraph `
    -TenantId $TenantId `
    -Scopes 'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All', 'Group.Read.All' `
    -NoWelcome

if ([string]::IsNullOrWhiteSpace($ClientId)) {
    $escapedDisplayName = $DisplayName.Replace("'", "''")
    $filter = [uri]::EscapeDataString("displayName eq '$escapedDisplayName'")
    $response = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=$filter&`$select=id,appId,displayName,identifierUris,api,appRoles"
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
        -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=$filter&`$select=id,appId,displayName,identifierUris,api,appRoles"
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

$scope = @($application.api.oauth2PermissionScopes | Where-Object value -eq $scopeValue) |
    Select-Object -First 1
$scopeId = if ($scope) { [string] $scope.id } else { [guid]::NewGuid().ToString() }
$role = @($application.appRoles | Where-Object value -eq $RequiredRole) | Select-Object -First 1
$roleId = if ($role) { [string] $role.id } else { [guid]::NewGuid().ToString() }
$applicationIdUri = "api://$($application.appId)"

$otherScopes = @($application.api.oauth2PermissionScopes | Where-Object value -ne $scopeValue |
    ForEach-Object { $_ | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable })
$otherRoles = @($application.appRoles | Where-Object value -ne $RequiredRole |
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
    appRoles = @($otherRoles) + @(
        @{
            id                 = $roleId
            value              = $RequiredRole
            displayName        = 'Import Autopilot devices'
            description        = 'Allows importing devices through the Autopilot Function.'
            allowedMemberTypes = @('User')
            isEnabled          = $true
        }
    )
}

if ($PSCmdlet.ShouldProcess($applicationIdUri, 'Configure API scope and app role')) {
    $updateJson = $updateBody | ConvertTo-Json -Depth 20 -Compress
    Invoke-MgGraphRequest `
        -Method PATCH `
        -Uri "https://graph.microsoft.com/v1.0/applications/$($application.id)" `
        -Body $updateJson `
        -ContentType 'application/json' | Out-Null

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
    Invoke-MgGraphRequest `
        -Method PATCH `
        -Uri "https://graph.microsoft.com/v1.0/applications/$($application.id)" `
        -Body $preAuthorizationBody `
        -ContentType 'application/json' | Out-Null
}

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

if ($servicePrincipal -and -not $servicePrincipal.appRoleAssignmentRequired -and
    $PSCmdlet.ShouldProcess($DisplayName, 'Require user or group assignment')) {
    Invoke-MgGraphRequest `
        -Method PATCH `
        -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($servicePrincipal.id)" `
        -Body @{ appRoleAssignmentRequired = $true } | Out-Null
}

foreach ($groupId in @($AuthorizedGroupId)) {
    $group = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/groups/$groupId`?`$select=id,displayName"

    $assignmentResponse = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($servicePrincipal.id)/appRoleAssignedTo?`$select=principalId,appRoleId"
    $existingAssignment = @(Get-GraphCollectionItems -Response $assignmentResponse | Where-Object {
        [string] $_.principalId -eq [string] $groupId -and
        [string] $_.appRoleId -eq $roleId
    }) | Select-Object -First 1

    if (-not $existingAssignment -and
        $PSCmdlet.ShouldProcess($group.displayName, "Assign app role $RequiredRole")) {
        Invoke-MgGraphRequest `
            -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($servicePrincipal.id)/appRoleAssignedTo" `
            -Body @{
                principalId = [string] $group.id
                resourceId  = [string] $servicePrincipal.id
                appRoleId   = $roleId
            } | Out-Null
        Write-Host "Assigned group '$($group.displayName)' to app role '$RequiredRole'."
    }
}

[pscustomobject]@{
    DisplayName              = [string] $application.displayName
    ClientId                 = [string] $application.appId
    ApplicationObjectId      = [string] $application.id
    ServicePrincipalObjectId = if ($servicePrincipal) { [string] $servicePrincipal.id } else { $null }
    ApplicationIdUri         = $applicationIdUri
    Scope                    = $scopeValue
    AppRole                  = $RequiredRole
}