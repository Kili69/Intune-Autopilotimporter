#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication
# Project-Version: 1.0.20260828.1
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
.SYNOPSIS
Creates or updates the Entra single-page application for the web frontend.

.DESCRIPTION
Ensures a single-tenant SPA registration, its redirect URI, delegated access to
the Autopilot import API, an enterprise application, and API preauthorization.
The SPA uses the authorization code flow with PKCE and requires no client secret.

.PARAMETER TenantId
Microsoft Entra tenant containing the API and web applications.

.PARAMETER ApiApplicationObjectId
Object ID of the Autopilot import API app registration.

.PARAMETER ApiClientId
Application Client ID of the Autopilot import API.

.PARAMETER ApiScopeId
Object ID of the DeviceHash.Import delegated permission scope.

.PARAMETER RedirectUri
HTTPS URL of the deployed web frontend.

.PARAMETER ClientId
Optional Client ID of an existing SPA registration.

.PARAMETER DisplayName
Display name used to find or create the SPA registration.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [guid] $TenantId,

    [Parameter(Mandatory)]
    [guid] $ApiApplicationObjectId,

    [Parameter(Mandatory)]
    [guid] $ApiClientId,

    [Parameter(Mandatory)]
    [guid] $ApiScopeId,

    [Parameter(Mandatory)]
    [ValidatePattern('^https://')]
    [string] $RedirectUri,

    [guid] $ClientId = [guid]::Empty,

    [string] $DisplayName = 'Autopilot Import Web',

    [switch] $ForceGraphSignIn
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-GraphItems {
    param([object] $Response)

    if ($null -eq $Response) { return @() }
    if ($Response -is [System.Collections.IDictionary] -and
        $Response.Contains('value')) {
        return @($Response['value'])
    }
    if ($Response.PSObject.Properties.Name -contains 'value') {
        return @($Response.value)
    }
    return @($Response)
}

$connectParameters = @{
    TenantId  = $TenantId
    Scopes    = @('Application.ReadWrite.All', 'User.Read')
    NoWelcome = $true
}
if ($ForceGraphSignIn) {
    Disconnect-MgGraph -SignOutFromBroker -ErrorAction SilentlyContinue | Out-Null
    $connectParameters.UseDeviceCode = $true
}
Connect-MgGraph @connectParameters

if ($ClientId -ne [guid]::Empty) {
    $filter = [uri]::EscapeDataString("appId eq '$ClientId'")
}
else {
    $escapedName = $DisplayName.Replace("'", "''")
    $filter = [uri]::EscapeDataString("displayName eq '$escapedName'")
}
$response = Invoke-MgGraphRequest `
    -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=$filter&`$select=id,appId,displayName,signInAudience,spa,requiredResourceAccess"
$applications = @(Get-GraphItems -Response $response)
if ($applications.Count -gt 1) {
    throw "More than one Entra application named '$DisplayName' exists. Pass -WebClientId explicitly."
}
$application = $applications | Select-Object -First 1

if (-not $application) {
    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'Create Entra web application')) {
        return
    }
    $application = Invoke-MgGraphRequest `
        -Method POST `
        -Uri 'https://graph.microsoft.com/v1.0/applications' `
        -Body @{
            displayName    = $DisplayName
            signInAudience = 'AzureADMyOrg'
        }
}

$existingRedirectUris = if ($application.PSObject.Properties['spa'] -and
    $application.spa) {
    @($application.spa.redirectUris | ForEach-Object { [string] $_ })
}
else {
    @()
}
$redirectUris = @($existingRedirectUris + $RedirectUri | Select-Object -Unique)
$requiredResourceAccess = if ($application.PSObject.Properties['requiredResourceAccess']) {
    @($application.requiredResourceAccess)
}
else {
    @()
}
$otherResourceAccess = @($requiredResourceAccess | Where-Object {
    [string] $_.resourceAppId -ne $ApiClientId.ToString()
} | ForEach-Object {
    $_ | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
})
$existingApiResourceAccess = @($requiredResourceAccess | Where-Object {
    [string] $_.resourceAppId -eq $ApiClientId.ToString()
} | Select-Object -First 1)
$existingApiAccess = if ($existingApiResourceAccess.Count -gt 0) {
    @($existingApiResourceAccess[0].resourceAccess)
}
else {
    @()
}
$apiResourceAccess = @($existingApiAccess | Where-Object {
    [string] $_.id -ne $ApiScopeId.ToString()
} | ForEach-Object {
    @{ id = [string] $_.id; type = [string] $_.type }
}) + @(@{ id = $ApiScopeId.ToString(); type = 'Scope' })

$updateBody = @{
    spa = @{
        redirectUris = $redirectUris
    }
    requiredResourceAccess = @($otherResourceAccess) + @(
        @{
            resourceAppId  = $ApiClientId.ToString()
            resourceAccess = $apiResourceAccess
        }
    )
} | ConvertTo-Json -Depth 20 -Compress
if ($PSCmdlet.ShouldProcess($application.displayName, 'Configure SPA redirect and API permission')) {
    Invoke-MgGraphRequest `
        -Method PATCH `
        -Uri "https://graph.microsoft.com/v1.0/applications/$($application.id)" `
        -Body $updateBody `
        -ContentType 'application/json' | Out-Null
}

$servicePrincipalFilter = [uri]::EscapeDataString("appId eq '$($application.appId)'")
$servicePrincipalResponse = Invoke-MgGraphRequest `
    -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$servicePrincipalFilter&`$select=id,appId"
$servicePrincipal = @(Get-GraphItems -Response $servicePrincipalResponse) |
    Select-Object -First 1
if (-not $servicePrincipal -and
    $PSCmdlet.ShouldProcess($application.displayName, 'Create enterprise application')) {
    $servicePrincipal = Invoke-MgGraphRequest `
        -Method POST `
        -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals' `
        -Body @{ appId = [string] $application.appId }
}

$apiApplication = Invoke-MgGraphRequest `
    -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/applications/${ApiApplicationObjectId}?`$select=id,api"
$otherPreAuthorizedApplications = @($apiApplication.api.preAuthorizedApplications |
    Where-Object { [string] $_.appId -ne [string] $application.appId } |
    ForEach-Object {
        $_ | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
    })
$existingWebPreAuthorization = @($apiApplication.api.preAuthorizedApplications |
    Where-Object { [string] $_.appId -eq [string] $application.appId } |
    Select-Object -First 1)
$existingDelegatedPermissionIds = if ($existingWebPreAuthorization.Count -gt 0) {
    @($existingWebPreAuthorization[0].delegatedPermissionIds)
}
else {
    @()
}
$delegatedPermissionIds = @(
    $existingDelegatedPermissionIds + $ApiScopeId.ToString() |
        ForEach-Object { [string] $_ } |
        Select-Object -Unique
)
$preAuthorizationBody = @{
    api = @{
        requestedAccessTokenVersion = $apiApplication.api.requestedAccessTokenVersion
        oauth2PermissionScopes      = @($apiApplication.api.oauth2PermissionScopes |
            ForEach-Object {
                $_ | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
            })
        preAuthorizedApplications  = @($otherPreAuthorizedApplications) + @(
            @{
                appId                  = [string] $application.appId
                delegatedPermissionIds = $delegatedPermissionIds
            }
        )
    }
} | ConvertTo-Json -Depth 20 -Compress
if ($PSCmdlet.ShouldProcess($apiApplication.id, 'Preauthorize web application for API scope')) {
    Invoke-MgGraphRequest `
        -Method PATCH `
        -Uri "https://graph.microsoft.com/v1.0/applications/$($apiApplication.id)" `
        -Body $preAuthorizationBody `
        -ContentType 'application/json' | Out-Null
}

[pscustomobject]@{
    DisplayName              = [string] $application.displayName
    ClientId                 = [string] $application.appId
    ApplicationObjectId      = [string] $application.id
    ServicePrincipalObjectId = if ($servicePrincipal) { [string] $servicePrincipal.id } else { $null }
    RedirectUri              = $RedirectUri
    ApiScopeId               = $ApiScopeId.ToString()
}
