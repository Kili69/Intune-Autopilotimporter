#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication
# Project-Version: 1.4.20261019.4
# Author: andreas.lucas@outlook.com (aka Kili)

# Copyright 2026 Andreas Lucas
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the project root for license information.

<#
.SYNOPSIS
Grants the managed identity an Entra role scoped to restricted administrative units.

.DESCRIPTION
Devices in a restricted management administrative unit (RMAU) can only be
modified by principals with a role scoped to that unit. Tenant-wide Graph
application permissions such as Device.ReadWrite.All are not sufficient, so
re-tagging a device that is already an RMAU member fails with HTTP 403.

None of the built-in roles that can be scoped to an administrative unit can
update device extension attributes; Cloud Device Administrator, for example,
can only enable, disable and delete devices. The script therefore creates or
updates the custom role 'Autopilot Import Device Attribute Writer', which only
reads devices and updates extension attribute sets 1 to 3 (extensionAttribute1
to extensionAttribute15). Custom roles require Microsoft Entra ID P1, which is
also required for restricted administrative units.

It then resolves each named administrative unit and assigns the role to the
Function managed identity with the restricted unit as directory scope. Regular
administrative units need no additional role and are skipped. Existing
assignments are detected, making the script safe to run repeatedly.

.PARAMETER ManagedIdentityObjectId
Object ID of the Function App's system-assigned managed identity service
principal.

.PARAMETER AdministrativeUnitName
Display names of administrative units referenced by Group Tag rules. Each name
must identify exactly one administrative unit.

.PARAMETER TenantId
Optional Entra tenant GUID used for the Microsoft Graph connection.

.PARAMETER RoleDisplayName
Display name of the custom role that is created or updated and assigned.

.PARAMETER ForceGraphSignIn
Signs out the cached Microsoft Graph account and uses device-code
authentication to select an account explicitly.

.EXAMPLE
.\scripts\Grant-ManagedIdentityAdministrativeUnitRole.ps1 `
    -ManagedIdentityObjectId '22222222-2222-2222-2222-222222222222' `
    -AdministrativeUnitName 'PAW' `
    -TenantId '11111111-1111-1111-1111-111111111111'

Assigns the custom device attribute role scoped to the restricted unit PAW.

.OUTPUTS
String describing the role and each assigned, existing or skipped
administrative unit.

.NOTES
Requires delegated Microsoft Graph permissions AdministrativeUnit.Read.All and
RoleManagement.ReadWrite.Directory and an account with the Privileged Role
Administrator role. Earlier versions assigned Cloud Device Administrator,
which cannot update extension attributes; such assignments are not used and
can be removed. New role assignments can take up to 24 hours to appear in
tokens that the managed identity has already cached.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [guid] $ManagedIdentityObjectId,

    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [string[]] $AdministrativeUnitName,

    [guid] $TenantId,

    [ValidateNotNullOrEmpty()]
    [string] $RoleDisplayName = 'Autopilot Import Device Attribute Writer',

    [switch] $ForceGraphSignIn
)

$ErrorActionPreference = 'Stop'

$names = @($AdministrativeUnitName |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_.Trim() } |
    Sort-Object -Unique)
if ($names.Count -eq 0) {
    Write-Output 'No administrative units are referenced; no scoped role is required.'
    return
}

if ($ForceGraphSignIn) {
    Disconnect-MgGraph -SignOutFromBroker -ErrorAction SilentlyContinue | Out-Null
}
$connectParameters = @{
    Scopes    = @('AdministrativeUnit.Read.All', 'RoleManagement.ReadWrite.Directory')
    NoWelcome = $true
}
if ($TenantId -ne [guid]::Empty) {
    $connectParameters.TenantId = $TenantId
}
if ($ForceGraphSignIn) {
    $connectParameters.UseDeviceCode = $true
    Write-Host "Sign in with a Privileged Role Administrator for tenant '$TenantId'."
}
Connect-MgGraph @connectParameters
$graphContext = Get-MgContext

function Invoke-RoleManagementRequest {
    param([string] $Method, [string] $Uri, [hashtable] $Body)

    $parameters = @{ Method = $Method; Uri = $Uri }
    if ($Body) {
        $parameters.Body = $Body | ConvertTo-Json -Depth 5 -Compress
        $parameters.ContentType = 'application/json'
    }
    try {
        Invoke-MgGraphRequest @parameters
    }
    catch {
        if ($_.Exception.Message -match '403|Authorization_RequestDenied|Insufficient privileges') {
            throw "Microsoft Graph account '$($graphContext.Account)' cannot manage directory roles. Sign in with a Privileged Role Administrator and run again with -ForceGraphSignIn. Original error: $($_.Exception.Message)"
        }
        throw
    }
}

$requiredActions = @(
    'microsoft.directory/devices/standard/read'
    'microsoft.directory/devices/extensionAttributeSet1/update'
    'microsoft.directory/devices/extensionAttributeSet2/update'
    'microsoft.directory/devices/extensionAttributeSet3/update'
)
$roleDefinition = @{
    displayName     = $RoleDisplayName
    description     = 'Allows the Autopilot Import Function managed identity to update device extension attributes in restricted management administrative units.'
    isEnabled       = $true
    rolePermissions = @(@{ allowedResourceActions = $requiredActions })
}
$roleFilter = [uri]::EscapeDataString("displayName eq '$($RoleDisplayName.Replace("'", "''"))'")
$roles = @((Invoke-RoleManagementRequest `
            -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?`$filter=$roleFilter")['value'] |
        Where-Object { -not $_.isBuiltIn })
if ($roles.Count -gt 1) {
    throw "Custom role name '$RoleDisplayName' is not unique."
}
if ($roles.Count -eq 0) {
    if (-not $PSCmdlet.ShouldProcess($RoleDisplayName, 'Create custom Entra role for device extension attributes')) {
        return
    }
    $role = Invoke-RoleManagementRequest `
        -Method POST `
        -Uri 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions' `
        -Body $roleDefinition
    Write-Output "Created custom role '$RoleDisplayName'."
}
else {
    $role = $roles[0]
    $currentActions = @($role.rolePermissions | ForEach-Object { $_.allowedResourceActions } | Sort-Object -Unique)
    if (Compare-Object $currentActions ($requiredActions | Sort-Object -Unique)) {
        if ($PSCmdlet.ShouldProcess($RoleDisplayName, 'Update custom Entra role permissions')) {
            Invoke-RoleManagementRequest `
                -Method PATCH `
                -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions/$($role.id)" `
                -Body @{ rolePermissions = $roleDefinition.rolePermissions; isEnabled = $true } | Out-Null
            Write-Output "Updated custom role '$RoleDisplayName'."
        }
    }
}
$RoleDefinitionId = [string] $role.id

$assignmentFilter = [uri]::EscapeDataString(
    "principalId eq '$ManagedIdentityObjectId' and roleDefinitionId eq '$RoleDefinitionId'")
$existingScopes = @((Invoke-RoleManagementRequest `
            -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=$assignmentFilter&`$select=id,directoryScopeId")['value'] |
        ForEach-Object { [string] $_.directoryScopeId })

foreach ($name in $names) {
    $unitFilter = [uri]::EscapeDataString("displayName eq '$($name.Replace("'", "''"))'")
    $units = @((Invoke-MgGraphRequest `
                -Method GET `
                -Uri "https://graph.microsoft.com/v1.0/directory/administrativeUnits?`$filter=$unitFilter&`$select=id,displayName,isMemberManagementRestricted")['value'] |
            Where-Object { [string]::Equals([string] $_.displayName, $name, [StringComparison]::OrdinalIgnoreCase) })
    if ($units.Count -eq 0) {
        Write-Warning "Administrative unit '$name' was not found; no scoped role was assigned."
        continue
    }
    if ($units.Count -gt 1) {
        Write-Warning "Administrative unit name '$name' is not unique; no scoped role was assigned."
        continue
    }
    $unit = $units[0]
    if (-not $unit.isMemberManagementRestricted) {
        Write-Output "Administrative unit '$name' is not restricted; no scoped role is required."
        continue
    }
    $scope = "/administrativeUnits/$($unit.id)"
    if ($existingScopes -contains $scope) {
        Write-Output "Scoped role for restricted administrative unit '$name' is already assigned."
        continue
    }
    if (-not $PSCmdlet.ShouldProcess($name, "Assign '$RoleDisplayName' scoped to restricted administrative unit")) {
        continue
    }
    Invoke-RoleManagementRequest `
        -Method POST `
        -Uri 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments' `
        -Body @{
            principalId      = [string] $ManagedIdentityObjectId
            roleDefinitionId = $RoleDefinitionId
            directoryScopeId = $scope
        } | Out-Null
    Write-Output "Assigned the scoped role for restricted administrative unit '$name'."
}
