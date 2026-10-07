#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication
# Project-Version: 1.3.20261007.1
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

    [switch] $ForceGraphSignIn
)

$graphApplicationId = '00000003-0000-0000-c000-000000000000'
$permissionNames = @(
    'AdministrativeUnit.ReadWrite.All'
    'DeviceManagementServiceConfig.ReadWrite.All'
    'DeviceManagementRBAC.Read.All'
    'Device.ReadWrite.All'
    'GroupMember.Read.All'
    'User.ReadBasic.All'
)

if ($ForceGraphSignIn) {
    Disconnect-MgGraph -SignOutFromBroker -ErrorAction SilentlyContinue | Out-Null
}

$connectParameters = @{
    Scopes    = @('Application.Read.All', 'AppRoleAssignment.ReadWrite.All')
    NoWelcome = $true
}
if ($TenantId -ne [guid]::Empty) {
    $connectParameters.TenantId = $TenantId
}
if ($ForceGraphSignIn) {
    $connectParameters.UseDeviceCode = $true
    Write-Host "Sign in with the Entra administrator for tenant '$TenantId'."
}
Connect-MgGraph @connectParameters

$graphContext = Get-MgContext
Write-Host "Microsoft Graph account: $($graphContext.Account)"

$filter = [uri]::EscapeDataString("appId eq '$graphApplicationId'")
$graphResponse = Invoke-MgGraphRequest `
    -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$filter&`$select=id,appRoles"
$graphServicePrincipal = @($graphResponse['value']) | Select-Object -First 1
$assignmentResponse = Invoke-MgGraphRequest `
    -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$ManagedIdentityObjectId/appRoleAssignments?`$select=resourceId,appRoleId"
$existingAssignments = @($assignmentResponse['value']) | Where-Object {
        [string] $_.resourceId -eq [string] $graphServicePrincipal.id
    }

foreach ($permissionName in $permissionNames) {
    $permission = $graphServicePrincipal.appRoles | Where-Object {
        $_.value -eq $permissionName -and $_.allowedMemberTypes -contains 'Application'
    } | Select-Object -First 1

    if (-not $permission) {
        throw "Microsoft Graph application permission '$permissionName' was not found."
    }

    $existingAssignment = @($existingAssignments | Where-Object {
        [string] $_.appRoleId -eq [string] $permission.id
    }) | Select-Object -First 1
    if ($existingAssignment) {
        Write-Output "Permission '$permissionName' is already assigned."
        continue
    }

    try {
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