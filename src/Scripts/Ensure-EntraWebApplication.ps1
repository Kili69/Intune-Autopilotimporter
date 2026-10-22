#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication
# Project-Version: 1.4.20261022.1
# Author: andreas.lucas@outlook.com (aka Kili)

<#
.SYNOPSIS
Creates or updates the Entra single-page application for the web frontend.

.DESCRIPTION
Ensures a single-tenant SPA registration, its redirect URI, delegated access to
the Autopilot import API and Azure Resource Manager, an enterprise application,
and import API preauthorization.
The SPA uses the authorization code flow with PKCE and requires no client secret.

The script is called by Install-AutopilotImport.ps1 after the API application
has been created by Ensure-EntraApiApplication.ps1, which supplies the API
object ID, Client ID, and scope ID required here.

The script performs the following operations:
- Finds the SPA registration by Client ID or display name, or creates it.
- Registers the frontend redirect URIs as SPA platform URIs, which enables the
  authorization code flow with PKCE instead of the legacy implicit flow.
- Derives the matching auth.html silent redirect URI for each frontend URL so
  that MSAL can renew tokens in a hidden iframe without user interaction.
- Requests the DeviceHash.Import delegated permission on the API application.
- Requests ARM user_impersonation for Owner/Contributor manager administration;
  this requires user/admin consent and does not grant Azure roles.
- Creates the enterprise application for the SPA in the tenant.
- Preauthorizes the SPA on the API application so that users are not prompted
  for an additional consent.

The operation is idempotent and preserves unrelated redirect URIs, API
permissions, and preauthorized clients.

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

.PARAMETER AdditionalRedirectUri
Optional additional HTTPS URLs for custom Function App domains.

.PARAMETER ClientId
Optional Client ID of an existing SPA registration.

.PARAMETER DisplayName
Display name used to find or create the SPA registration.

.PARAMETER ForceGraphSignIn
Signs out the cached Microsoft Graph account and uses device-code
authentication to select an account explicitly.

.EXAMPLE
.\scripts\Ensure-EntraWebApplication.ps1 `
    -TenantId '11111111-1111-1111-1111-111111111111' `
    -ApiApplicationObjectId '22222222-2222-2222-2222-222222222222' `
    -ApiClientId '33333333-3333-3333-3333-333333333333' `
    -ApiScopeId '44444444-4444-4444-4444-444444444444' `
    -RedirectUri 'https://func-example.azurewebsites.net/api/ui/index.html'

Creates or updates the SPA registration for the deployed web frontend.

.OUTPUTS
PSCustomObject containing the SPA display name, Client ID, application object
ID, enterprise application object ID, the primary redirect URI, all configured
redirect URIs, and the delegated API scope ID.

.NOTES
Requires Microsoft.Graph.Authentication and delegated permissions
Application.ReadWrite.All and User.Read.
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

    [ValidatePattern('^https://')]
    [string[]] $AdditionalRedirectUri,

    [guid] $ClientId = [guid]::Empty,

    [string] $DisplayName = 'Autopilot Import Web',

    [switch] $ForceGraphSignIn
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-GraphItems {
    <#
    .SYNOPSIS
    Normalizes Microsoft Graph collection responses to a PowerShell array.

    .DESCRIPTION
    Invoke-MgGraphRequest can return a dictionary, a deserialized object with a
    value property, or a single object depending on module and response shape.
    This helper gives the discovery queries one consistent collection shape.
    #>
    param([object] $Response)
    # Return an empty array if the response is null.
    if ($null -eq $Response) { return @() }
    # Return the 'value' property if it exists in the response dictionary.
    if ($Response -is [System.Collections.IDictionary] -and
        $Response.Contains('value')) {
        return @($Response['value'])
    }
    # Return the 'value' property if it exists as a PSObject property.
    if ($Response.PSObject.Properties.Name -contains 'value') {
        return @($Response.value)
    }
    return @($Response)
}

function Merge-WebRedirectUri {
    <#
    .SYNOPSIS
    Combines existing, primary, and additional SPA redirect URIs.

    .DESCRIPTION
    Returns the deduplicated set of redirect URIs and adds a silent redirect URI
    for every frontend URL. MSAL renews access tokens in a hidden iframe that
    loads auth.html, so that page must be registered in addition to index.html.
    Existing URIs are preserved because a Function App can be reachable through
    its default host name and additional custom domains.

    .PARAMETER ExistingRedirectUri
    Redirect URIs already registered on the SPA platform.

    .PARAMETER PrimaryRedirectUri
    Frontend URL of the current deployment.

    .PARAMETER AdditionalRedirectUri
    Frontend URLs of custom domains that must remain usable.

    .OUTPUTS
    String array of redirect URIs for the SPA platform configuration.
    #>
    param(
        [AllowNull()]
        [object[]] $ExistingRedirectUri,

        [Parameter(Mandatory)]
        [string] $PrimaryRedirectUri,

        [AllowNull()]
        [object[]] $AdditionalRedirectUri
    )
    # Combine and normalize all redirect URIs, removing duplicates and empty entries.
    $redirectUris = @(
        # Iterate over all provided redirect URIs and normalize them.
        foreach ($uri in @(
            @($ExistingRedirectUri)
            @($PrimaryRedirectUri)
            @($AdditionalRedirectUri)
        )) {
            $normalizedUri = ([string] $uri).Trim()
            if (-not [string]::IsNullOrWhiteSpace($normalizedUri)) {
                $normalizedUri
            }
        }
    ) | Select-Object -Unique
    # Derive silent redirect URIs for each frontend entry point.
    $silentRedirectUris = @(
        # Iterate over all normalized redirect URIs to generate corresponding silent redirect URIs.
        foreach ($uri in $redirectUris) {
            $parsedUri = $null
            # Derive the silent redirect only from frontend entry points. Any
            # other registered URI, including auth.html itself, is skipped so
            # that no unintended redirect targets are added.
            if ([uri]::TryCreate(
                    $uri,
                    [UriKind]::Absolute,
                    [ref] $parsedUri) -and
                $parsedUri.Scheme -eq 'https' -and
                $parsedUri.AbsolutePath -ieq '/api/ui/index.html') {
                "$($parsedUri.GetLeftPart([UriPartial]::Authority))/api/ui/auth.html"
            }
        }
    )

    return (@($redirectUris) + @($silentRedirectUris)) | Select-Object -Unique
}

function ConvertTo-ValidPermissionIds {
    <#
    .SYNOPSIS
    Filters preauthorized permission IDs down to those the API still defines.

    .DESCRIPTION
    Microsoft Graph rejects a preauthorization entry that references a scope or
    role that no longer exists on the API application. Existing entries can
    contain such stale or malformed IDs, which would make the update of
    unrelated clients fail. This helper keeps only valid, known, and unique IDs
    in their normalized GUID form.

    .PARAMETER PermissionIds
    Permission IDs currently stored on a preauthorized application.

    .PARAMETER ValidPermissionIds
    IDs of all delegated scopes and application roles defined by the API.

    .OUTPUTS
    String array of accepted permission IDs.
    #>
    param(
        [AllowNull()]
        [object[]] $PermissionIds,

        [Parameter(Mandatory)]
        [string[]] $ValidPermissionIds
    )

    # Initialize a hash set to store valid permission IDs for quick lookup.
    $validIds = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    # Populate the hash set with all valid permission IDs.
    foreach ($validPermissionId in $ValidPermissionIds) {
        # Attempt to parse each valid permission ID as a GUID before adding it to the hash set.
        $parsedId = [guid]::Empty
        # Skip empty or null permission IDs.
        if ([string]::IsNullOrWhiteSpace($validPermissionId)) {
            continue
        }
        if ([guid]::TryParse($validPermissionId, [ref] $parsedId)) {
            [void] $validIds.Add($parsedId.ToString())
        }
    }
    # Initialize a list to store the filtered and validated permission IDs.
    $result = [Collections.Generic.List[string]]::new()
    # Filter the provided permission IDs, keeping only those that are valid and unique.
    foreach ($permissionId in @($PermissionIds)) {
        # Skip empty or null permission IDs before attempting to parse them.
        $parsedId = [guid]::Empty
        # Attempt to parse the permission ID as a GUID.
        if ([guid]::TryParse([string] $permissionId, [ref] $parsedId) -and
            $validIds.Contains($parsedId.ToString()) -and
            -not $result.Contains($parsedId.ToString())) {
            $result.Add($parsedId.ToString())
        }
    }
    return $result.ToArray()
}

# Use delegated Graph permissions so the administrator performing installation
# consents to the application changes made below.
$connectParameters = @{
    TenantId  = $TenantId
    Scopes    = @('Application.ReadWrite.All', 'User.Read')
    NoWelcome = $true
}
# Connect to Microsoft Graph using delegated permissions for the current administrator.
if ($ForceGraphSignIn) {
    Disconnect-MgGraph -SignOutFromBroker -ErrorAction SilentlyContinue | Out-Null
    $connectParameters.UseDeviceCode = $true
}
# Establish the connection to Microsoft Graph with the specified parameters.
Connect-MgGraph @connectParameters

# Prefer a stable Client ID when supplied. Display-name discovery supports the
# first installation, but rejects duplicates rather than updating an arbitrary
# app registration.
if ($ClientId -ne [guid]::Empty) {
    $filter = [uri]::EscapeDataString("appId eq '$ClientId'")
}
else {
    # Use display name to discover the application if a specific Client ID is not provided.
    $escapedName = $DisplayName.Replace("'", "''")
    $filter = [uri]::EscapeDataString("displayName eq '$escapedName'")
}
# Retrieve the application from Microsoft Graph based on the constructed filter.
$response = Invoke-MgGraphRequest `
    -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=$filter&`$select=id,appId,displayName,signInAudience,spa,requiredResourceAccess"
# Parse the response to extract the list of applications.
$applications = @(Get-GraphItems -Response $response)
if ($applications.Count -gt 1) {
    throw "More than one Entra application named '$DisplayName' exists. Pass -WebClientId explicitly."
}
$application = $applications | Select-Object -First 1
# Select the first application from the list, if any.
if (-not $application) {
    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'Create Entra web application')) {
        return
    }
    # Create a new application registration if it does not exist.
    $application = Invoke-MgGraphRequest `
        -Method POST `
        -Uri 'https://graph.microsoft.com/v1.0/applications' `
        -Body @{
            displayName    = $DisplayName
            signInAudience = 'AzureADMyOrg'
        }
}
# Determine the existing redirect URIs for the SPA platform, if any.
# A new registration has no spa property at all, so treat a missing or empty
# platform configuration as an empty redirect URI list.
$existingRedirectUris = if ($application.PSObject.Properties['spa'] -and
    $application.spa) {
    @($application.spa.redirectUris | ForEach-Object { [string] $_ })
}
else {
    @()
}
# Merge the existing redirect URIs with the primary and additional redirect URIs.
$redirectUris = @(Merge-WebRedirectUri `
    -ExistingRedirectUri $existingRedirectUris `
    -PrimaryRedirectUri $RedirectUri `
    -AdditionalRedirectUri $AdditionalRedirectUri)
# The resulting $redirectUris array contains all redirect URIs that should be configured for the SPA platform.
$requiredResourceAccess = if ($application.PSObject.Properties['requiredResourceAccess']) {
        @($application.requiredResourceAccess)
    }
    else {
        # Initialize the required resource access list as empty if it does not exist.
        @()
    }
# Microsoft Graph replaces nested collections during PATCH operations. Retain
# every API permission that targets a resource other than the import API.
$armResourceAppId = '797f4846-ba00-4fd7-ba43-dac1f8f63013'
$armScopeId = '41094075-9dad-400e-a0bd-54e686782033'
# Define the resource and scope IDs for the ARM API.
$otherResourceAccess = @($requiredResourceAccess | Where-Object {
    [string] $_.resourceAppId -notin @($ApiClientId.ToString(), $armResourceAppId)
} | ForEach-Object {
    $_ | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
})
# Retain all existing API permissions that do not target the import API.
$existingApiResourceAccess = @($requiredResourceAccess | Where-Object {
    [string] $_.resourceAppId -eq $ApiClientId.ToString()
} | Select-Object -First 1)
# Extract the existing API permissions for the import API, if any.
$existingApiAccess = if ($existingApiResourceAccess.Count -gt 0) {
    @($existingApiResourceAccess[0].resourceAccess)
}
else {
    @()
}
# Rebuild the import API entry so that the DeviceHash.Import scope is requested
# exactly once while other permissions on the same API are preserved.
$apiResourceAccess = @($existingApiAccess | Where-Object {
    [string] $_.id -ne $ApiScopeId.ToString()
} | ForEach-Object {
    @{ id = [string] $_.id; type = [string] $_.type }
}) + @(@{ id = $ApiScopeId.ToString(); type = 'Scope' })
# Rebuild the ARM API entry so that the DeviceHash.Import scope is requested
# exactly once while other permissions on the same API are preserved.
$armResourceAccess = @($requiredResourceAccess | Where-Object {
    [string] $_.resourceAppId -eq $armResourceAppId
} | ForEach-Object { $_.resourceAccess } | Where-Object {
    [string] $_.id -ne $armScopeId
} | ForEach-Object {
    @{ id = [string] $_.id; type = [string] $_.type }
}) + @(@{ id = $armScopeId; type = 'Scope' })

# Registering the URIs under spa selects the authorization code flow with PKCE,
# which allows the browser client to operate without a client secret.
$updateBody = @{
    spa = @{
        redirectUris = $redirectUris
    }
    requiredResourceAccess = @($otherResourceAccess) + @(
        @{
            resourceAppId  = $ApiClientId.ToString()
            resourceAccess = $apiResourceAccess
        }
        @{
            resourceAppId = $armResourceAppId
            resourceAccess = $armResourceAccess
        }
    )
} | ConvertTo-Json -Depth 20 -Compress
# Update the SPA application's redirect URIs and required API permissions.
if ($PSCmdlet.ShouldProcess($application.displayName, 'Configure SPA redirect and API permission')) {
    Invoke-MgGraphRequest `
        -Method PATCH `
        -Uri "https://graph.microsoft.com/v1.0/applications/$($application.id)" `
        -Body $updateBody `
        -ContentType 'application/json' | Out-Null
}

# The app registration defines the SPA. Its tenant-local service principal is
# the enterprise application required for sign-in and permission grants.
$servicePrincipalFilter = [uri]::EscapeDataString("appId eq '$($application.appId)'")
$servicePrincipalResponse = Invoke-MgGraphRequest `
    -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$servicePrincipalFilter&`$select=id,appId"
$servicePrincipal = @(Get-GraphItems -Response $servicePrincipalResponse) |
    Select-Object -First 1
# If the service principal does not exist, create it to represent the SPA in the tenant.
if (-not $servicePrincipal -and
    $PSCmdlet.ShouldProcess($application.displayName, 'Create enterprise application')) {
    $servicePrincipal = Invoke-MgGraphRequest `
        -Method POST `
        -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals' `
        -Body @{ appId = [string] $application.appId }
}

# Preauthorization is stored on the API application, not on the SPA. Read the
# current API state and verify the scope before modifying it.
$apiApplication = Invoke-MgGraphRequest `
    -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/applications/${ApiApplicationObjectId}?`$select=id,api,appRoles"
$apiScopeIdString = $ApiScopeId.ToString()
$apiScope = @($apiApplication.api.oauth2PermissionScopes | Where-Object {
    [string] $_.id -eq $apiScopeIdString -and $_.isEnabled
} | Select-Object -First 1)
# Verify that the requested delegated permission scope exists and is enabled on the API application.
if ($apiScope.Count -eq 0) {
    throw "Delegated permission scope '$apiScopeIdString' is not enabled on API application '$ApiApplicationObjectId'."
}
# Graph accepts only permission IDs that the API currently defines. Collect the
# valid scope and role IDs used to sanitize existing preauthorization entries.
$validPermissionIds = @(
    $apiApplication.api.oauth2PermissionScopes |
        ForEach-Object { [string] $_.id }
    $apiApplication.appRoles |
        ForEach-Object { [string] $_.id }
)
# Preserve preauthorization for other clients, such as Azure PowerShell, and
# drop entries that would be rejected because they reference removed permissions.
$otherPreAuthorizedApplications = @($apiApplication.api.preAuthorizedApplications |
    Where-Object { [string] $_.appId -ne [string] $application.appId } |
    ForEach-Object {
        $permissionIds = @(ConvertTo-ValidPermissionIds `
            -PermissionIds $_.delegatedPermissionIds `
            -ValidPermissionIds $validPermissionIds)
        if ($permissionIds.Count -gt 0) {
            @{
                appId                  = [string] $_.appId
                delegatedPermissionIds = $permissionIds
            }
        }
    })
# The target SPA must always receive the enabled scope selected above. Do not
# derive this entry from existing preauthorization data, which can be empty.
$delegatedPermissionIds = @([string] $apiScope[0].id)
$preAuthorizationBody = @{
    api = @{
        # Resend the existing scope definitions and token version unchanged,
        # because PATCH replaces the complete api object.
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
# Send the PATCH request to update the API application's preauthorized clients with the SPA's delegated permissions.
if ($PSCmdlet.ShouldProcess($apiApplication.id, 'Preauthorize web application for API scope')) {
    Invoke-MgGraphRequest `
        -Method PATCH `
        -Uri "https://graph.microsoft.com/v1.0/applications/$($apiApplication.id)" `
        -Body $preAuthorizationBody `
        -ContentType 'application/json' | Out-Null
}
# Return a summary object containing key details about the SPA and its API scope.
[pscustomobject]@{
    DisplayName              = [string] $application.displayName
    ClientId                 = [string] $application.appId
    ApplicationObjectId      = [string] $application.id
    ServicePrincipalObjectId = if ($servicePrincipal) { [string] $servicePrincipal.id } else { $null }
    RedirectUri              = $RedirectUri
    RedirectUris             = $redirectUris
    ApiScopeId               = $ApiScopeId.ToString()
}
