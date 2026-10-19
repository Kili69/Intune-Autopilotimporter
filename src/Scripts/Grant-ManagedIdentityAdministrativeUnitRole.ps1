#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication
# Project-Version: 1.4.20261019.2
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

The script resolves each named administrative unit. For restricted units it
assigns the Cloud Device Administrator role to the Function managed identity
with the administrative unit as directory scope. Regular administrative units
need no additional role and are skipped. Existing assignments are detected,
making the script safe to run repeatedly.

.PARAMETER ManagedIdentityObjectId
Object ID of the Function App's system-assigned managed identity service
principal.

.PARAMETER AdministrativeUnitName
Display names of administrative units referenced by Group Tag rules. Each name
must identify exactly one administrative unit.

.PARAMETER TenantId
Optional Entra tenant GUID used for the Microsoft Graph connection.

.PARAMETER RoleDefinitionId
Entra role template ID to assign. Defaults to Cloud Device Administrator
(7698a772-787b-4ac8-901f-60d6b08affd2), which can update device extension
attributes inside the scoped administrative unit.

.PARAMETER ForceGraphSignIn
Signs out the cached Microsoft Graph account and uses device-code
authentication to select an account explicitly.

.EXAMPLE
.\scripts\Grant-ManagedIdentityAdministrativeUnitRole.ps1 `
    -ManagedIdentityObjectId '22222222-2222-2222-2222-222222222222' `
    -AdministrativeUnitName 'PAW' `
    -TenantId '11111111-1111-1111-1111-111111111111'

Assigns Cloud Device Administrator scoped to the restricted unit PAW.

.OUTPUTS
String describing each assigned, existing or skipped administrative unit.

.NOTES
Requires delegated Microsoft Graph permissions AdministrativeUnit.Read.All and
RoleManagement.ReadWrite.Directory and an account with the Privileged Role
Administrator role. New role assignments can take up to 24 hours to appear in
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

    [guid] $RoleDefinitionId = '7698a772-787b-4ac8-901f-60d6b08affd2',

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

$assignmentFilter = [uri]::EscapeDataString(
    "principalId eq '$ManagedIdentityObjectId' and roleDefinitionId eq '$RoleDefinitionId'")
$existingScopes = @((Invoke-MgGraphRequest `
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
    if (-not $PSCmdlet.ShouldProcess($name, 'Assign Cloud Device Administrator scoped to restricted administrative unit')) {
        continue
    }
    try {
        Invoke-MgGraphRequest `
            -Method POST `
            -Uri 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments' `
            -Body (@{
                principalId      = [string] $ManagedIdentityObjectId
                roleDefinitionId = [string] $RoleDefinitionId
                directoryScopeId = $scope
            } | ConvertTo-Json -Compress) `
            -ContentType 'application/json' | Out-Null
    }
    catch {
        if ($_.Exception.Message -match '403|Authorization_RequestDenied|Insufficient privileges') {
            throw "Microsoft Graph account '$($graphContext.Account)' cannot assign directory roles. Sign in with a Privileged Role Administrator and run again with -ForceGraphSignIn. Original error: $($_.Exception.Message)"
        }
        throw
    }
    Write-Output "Assigned the scoped role for restricted administrative unit '$name'."
}
