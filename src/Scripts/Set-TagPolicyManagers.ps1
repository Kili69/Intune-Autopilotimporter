#Requires -Version 7.2
# Project-Version: 1.3.20261002.3
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
.SYNOPSIS
Compatibility wrapper for Update-AutoPilotTagPolicyManager.

.DESCRIPTION
Adds and removes explicit users or groups from the Group Tag manager policy of
an Autopilot Import Function App. The script loads AutopilotImport.Client from
the installation or source tree and forwards the supplied parameters to
Update-AutoPilotTagPolicyManager.

The command verifies that the caller is an Owner or Contributor of the Function
App before updating its MANAGER_AUTHORIZATION_POLICY application setting. The
installing user remains protected from removal. Values omitted on the command
line are resolved from the client configuration file.

.PARAMETER SubscriptionId
Azure subscription containing the Autopilot Import Function App. When omitted,
the value is read from the client configuration.

.PARAMETER TenantId
Microsoft Entra tenant used for Azure authentication. When omitted, the value
is read from the client configuration.

.PARAMETER ResourceGroupName
Name of the Azure resource group containing the Function App. When omitted,
the value is read from the client configuration.

.PARAMETER FunctionAppName
Name of the Autopilot Import Function App whose manager policy is updated. When
omitted, the value is read from the client configuration.

.PARAMETER AddPrincipalId
Object IDs of Microsoft Entra users or groups to add as explicit Group Tag
managers.

.PARAMETER RemovePrincipalId
Object IDs of Microsoft Entra users or groups to remove from the explicit Group
Tag managers. The identity that installed the solution cannot be removed.

.PARAMETER ConfigPath
Path to the client.settings.json file used to resolve values not supplied as
parameters.

.OUTPUTS
PSCustomObject containing FunctionAppName and the resulting ManagerPolicy.

.EXAMPLE
.\Set-TagPolicyManagers.ps1 `
    -AddPrincipalId '11111111-1111-1111-1111-111111111111' `
    -RemovePrincipalId '22222222-2222-2222-2222-222222222222' `
    -ConfigPath '.\client.settings.json'

Adds one principal and removes another by using the Azure deployment values
from client.settings.json.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [guid] $SubscriptionId,

    [guid] $TenantId,

    [string] $ResourceGroupName,

    [string] $FunctionAppName,

    [guid[]] $AddPrincipalId,

    [guid[]] $RemovePrincipalId,

    [string] $ConfigPath
)

$moduleManifest = @(
    Get-ChildItem `
        -Path (Join-Path $PSScriptRoot '..\Modules\AutopilotImport.Client\*\AutopilotImport.Client.psd1') `
        -ErrorAction SilentlyContinue |
        Sort-Object { [version] $_.Directory.Name } -Descending
    Get-Item `
        -LiteralPath (Join-Path $PSScriptRoot '..\AutopilotImport.Client\AutopilotImport.Client.psd1') `
        -ErrorAction SilentlyContinue
    Get-Item `
        -LiteralPath (Join-Path $PSScriptRoot '..\src\AutopilotImport.Client\AutopilotImport.Client.psd1') `
        -ErrorAction SilentlyContinue
) | Select-Object -First 1
if (-not $moduleManifest) {
    throw 'AutopilotImport.Client is not installed beside this script.'
}
Import-Module $moduleManifest.FullName -Force

$parameters = @{}
foreach ($name in $PSBoundParameters.Keys) {
    $parameters[$name] = $PSBoundParameters[$name]
}
if ($WhatIfPreference) {
    $parameters.WhatIf = $true
}
AutopilotImport.Client\Update-AutoPilotTagPolicyManager @parameters
