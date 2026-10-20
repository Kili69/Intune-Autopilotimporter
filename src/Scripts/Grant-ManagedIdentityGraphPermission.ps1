#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication
# Project-Version: 1.4.20261020.15
# Author: andreas.lucas@outlook.com (aka Kili)

# Copyright 2026 Andreas Lucas
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the project root for license information.

<#
.SYNOPSIS
Grants the required Graph permissions to a managed identity.

.DESCRIPTION
Connects to Microsoft Graph, resolves the required Autopilot import, Entra
device update, group membership read, restricted management administrative
unit, and Intune RBAC read application roles, and assigns them to the specified
managed identity service principal. Existing assignments are detected, making
the script safe to run repeatedly.

.PARAMETER ManagedIdentityObjectId
Object ID of the Function App's system-assigned managed identity service
principal. This is not the managed identity application/client ID.

.PARAMETER TenantId
Optional Entra tenant GUID. Supplying it ensures that Microsoft Graph connects
to the tenant that owns the managed identity.

.PARAMETER ForceGraphSignIn
Signs out the cached Microsoft Graph account and uses device-code
authentication to select an account explicitly before assigning permissions.
Use this when the cached account lacks the required Entra administrative role.

.EXAMPLE
.\scripts\Grant-ManagedIdentityGraphPermission.ps1 `
    -ManagedIdentityObjectId '22222222-2222-2222-2222-222222222222' `
    -TenantId '11111111-1111-1111-1111-111111111111' `
    -ForceGraphSignIn

Grants the required Microsoft Graph application permission, or reports that it
is already assigned.

.OUTPUTS
String describing whether the permission was assigned or already present.

.NOTES
Requires Microsoft.Graph.Authentication and delegated permissions
Application.Read.All and AppRoleAssignment.ReadWrite.All. Granting this
application permission is a privileged tenant operation.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [guid] $ManagedIdentityObjectId,

    [guid] $TenantId,

    [switch] $ForceGraphSignIn,

    [securestring] $GraphAccessToken
)

if ($ForceGraphSignIn -and $GraphAccessToken) {
    throw 'Specify either -ForceGraphSignIn or -GraphAccessToken, not both.'
}

$graphApplicationId = '00000003-0000-0000-c000-000000000000'
# Application permissions required by the Function App at runtime. The managed
# identity runs without a signed-in user, so every Graph call relies on these
# application roles:
# - AdministrativeUnit.ReadWrite.All resolves the optional administrative unit
#   and adds the imported device as a member.
# - DeviceManagementServiceConfig.ReadWrite.All imports the Autopilot device
#   identity into Intune.
# - DeviceManagementRBAC.Read.All checks Intune role assignments.
# - GroupMember.ReadWrite.All synchronizes static security-group memberships.
# - Device.ReadWrite.All writes the authorized Group Tag to the configured
#   Entra device extension attribute.
# - GroupMember.Read.All and User.ReadBasic.All evaluate the calling user's
#   group membership against the Group Tag policy.
$permissionNames = @(
    'AdministrativeUnit.ReadWrite.All'
    'DeviceManagementServiceConfig.ReadWrite.All'
    'DeviceManagementRBAC.Read.All'
    'GroupMember.ReadWrite.All'
    'Device.ReadWrite.All'
    'GroupMember.Read.All'
    'User.ReadBasic.All'
)
# Connect to Microsoft Graph with the appropriate authentication method.
if ($ForceGraphSignIn) {
    Disconnect-MgGraph -SignOutFromBroker -ErrorAction SilentlyContinue | Out-Null
}
# Prepare the connection parameters for Microsoft Graph.
$connectParameters = @{ NoWelcome = $true }
# This hashtable will store the parameters used to connect to Microsoft Graph.
if ($GraphAccessToken) {
    $connectParameters.AccessToken = $GraphAccessToken
}
else {
    # Use device code authentication if no access token is provided and force sign-in is not requested.
    $connectParameters.Scopes = @('Application.Read.All', 'AppRoleAssignment.ReadWrite.All')
    # Specify the scopes required for device code authentication.
    if ($TenantId -ne [guid]::Empty) {
        $connectParameters.TenantId = $TenantId
    }
    # If a tenant ID is specified, include it in the connection parameters.
    if ($ForceGraphSignIn) {
        $connectParameters.UseDeviceCode = $true
        Write-Host "Sign in with the Entra administrator for tenant '$TenantId'."
    }
}
Connect-MgGraph @connectParameters
# Retrieve the current Microsoft Graph context to verify the tenant and account.
$graphContext = Get-MgContext
# Verify that the tenant ID of the current context matches the expected tenant ID.
if ($TenantId -ne [guid]::Empty -and [string] $graphContext.TenantId -ne $TenantId.ToString()) {
    throw "The Microsoft Graph token belongs to a different tenant than '$TenantId'."
}
Write-Host "Microsoft Graph account: $($graphContext.Account)"

# Microsoft Graph exposes its application permissions as app roles on its own
# service principal. Read them to translate permission names into role IDs.
$filter = [uri]::EscapeDataString("appId eq '$graphApplicationId'")
# Retrieve the service principal for Microsoft Graph to translate permission names into role IDs.
$graphResponse = Invoke-MgGraphRequest `
    -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$filter&`$select=id,appRoles"
$graphServicePrincipal = @($graphResponse['value']) | Select-Object -First 1
# Read the assignments once, so each permission can be checked without an
# additional request and the script stays safe to run repeatedly.
$assignmentResponse = Invoke-MgGraphRequest `
    -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$ManagedIdentityObjectId/appRoleAssignments?`$select=resourceId,appRoleId"
# Filter the existing assignments to include only those for the Microsoft Graph service principal.
$existingAssignments = @($assignmentResponse['value']) | Where-Object {
        [string] $_.resourceId -eq [string] $graphServicePrincipal.id
    }
# Iterate over the requested permission names and assign them if not already assigned.
foreach ($permissionName in $permissionNames) {
    # Restrict the lookup to application roles. Graph publishes delegated
    # permissions under the same name, but those cannot be assigned to a
    # managed identity.
    $permission = $graphServicePrincipal.appRoles | Where-Object {
        $_.value -eq $permissionName -and $_.allowedMemberTypes -contains 'Application'
    } | Select-Object -First 1
    # Throw an error if the requested permission is not found among the application roles.
    if (-not $permission) {
        throw "Microsoft Graph application permission '$permissionName' was not found."
    }
    # Check if the permission is already assigned to avoid duplicate assignments.
    $existingAssignment = @($existingAssignments | Where-Object {
        [string] $_.appRoleId -eq [string] $permission.id
    }) | Select-Object -First 1
    # If an existing assignment is found, skip to the next permission.
    if ($existingAssignment) {
        Write-Output "Permission '$permissionName' is already assigned."
        continue
    }

    try {
        # principalId is the managed identity, resourceId is Microsoft Graph,
        # and appRoleId is the granted application permission.
        # Attempt to assign the application permission to the managed identity.
        Invoke-MgGraphRequest `
            -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$ManagedIdentityObjectId/appRoleAssignments" `
            -Body (@{
                principalId = [string] $ManagedIdentityObjectId
                resourceId  = [string] $graphServicePrincipal.id
                appRoleId   = [string] $permission.id
            } | ConvertTo-Json -Compress) `
            -ContentType 'application/json' | Out-Null
    }
    catch {
        if ($_.Exception.Message -match '403|Authorization_RequestDenied|Insufficient privileges') {
            throw "Microsoft Graph account '$($graphContext.Account)' cannot assign application permissions. Sign in with an account that has Application Administrator, Cloud Application Administrator, or Privileged Role Administrator, then run again with -ForceGraphSignIn. Original error: $($_.Exception.Message)"
        }
        throw
    }

    Write-Output "Assigned Microsoft Graph permission '$permissionName'."
}