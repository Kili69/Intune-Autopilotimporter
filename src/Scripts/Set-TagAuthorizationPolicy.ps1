#Requires -Version 7.2
# Project-Version: 1.1.20260912.1
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
.SYNOPSIS
Compatibility wrapper for AutopilotImport.Client tag policy commands.

.DESCRIPTION
Lists or replaces the Group Tag authorization policy used by the Autopilot
Import API. The script loads AutopilotImport.Client from the installation or
source tree and invokes Get-AutopilotTagPolicy when List is specified;
otherwise, it invokes Set-AutopilotTagPolicy.

Each policy rule maps a Microsoft Entra group object ID to one or more allowed
Autopilot Group Tags. Values omitted on the command line are resolved from the
client configuration file. Replacing the policy supports WhatIf and requires
confirmation because the complete existing policy is overwritten.

.PARAMETER List
Returns the currently configured Group Tag authorization policy with Entra
group display names without changing it.

.PARAMETER TagAuthorizationRule
Complete set of authorization rules in the form
<group-object-id>=<tag1>,<tag2>. This parameter replaces the existing policy
and is required unless List is specified.

.PARAMETER RestrictedManagementAdministrativeUnitName
Optional display name of the restricted management administrative unit to
associate with every policy rule. Imported devices using a matching Group Tag
are added to this unit after their Entra device becomes available.

.PARAMETER ManagementUrl
HTTPS URL of the Function App tag-policy management endpoint. When omitted,
the value is read from the client configuration.

.PARAMETER ApiApplicationIdUri
Application ID URI used as the OAuth audience for the Autopilot Import API.
When omitted, the value is read from the client configuration.

.PARAMETER TenantId
Microsoft Entra tenant used for authentication. When omitted, the value is
read from the client configuration.

.PARAMETER ConfigPath
Path to the client.settings.json file used to resolve values not supplied as
parameters.

.OUTPUTS
Policy rule objects containing GroupName, Tags, and GroupId when List is
specified. GroupId remains available for pipeline use but is omitted from the
default console view. The Set parameter set returns no output when WhatIf
prevents the update.

.EXAMPLE
.\Set-TagAuthorizationPolicy.ps1 -List `
    -ConfigPath '.\client.settings.json'

Returns the current Group Tag authorization policy with Entra group names.

.EXAMPLE
.\Set-TagAuthorizationPolicy.ps1 `
    -TagAuthorizationRule @(
        '11111111-1111-1111-1111-111111111111=Sales,Shared'
        '22222222-2222-2222-2222-222222222222=Engineering'
    ) `
    -RestrictedManagementAdministrativeUnitName 'Autopilot Devices' `
    -ConfigPath '.\client.settings.json'

Replaces the complete policy and associates its Group Tags with the named
restricted management administrative unit.
#>

[CmdletBinding(DefaultParameterSetName = 'Set', SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Get')]
    [switch] $List,

    [Parameter(Mandatory, ParameterSetName = 'Set')]
    [string[]] $TagAuthorizationRule,

    [Parameter(ParameterSetName = 'Set')]
    [string] $RestrictedManagementAdministrativeUnitName,

    [string] $ManagementUrl,

    [string] $ApiApplicationIdUri,

    [string] $TenantId,

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
foreach ($name in @('ManagementUrl', 'ApiApplicationIdUri', 'TenantId', 'ConfigPath')) {
    if ($PSBoundParameters.ContainsKey($name)) {
        $parameters[$name] = $PSBoundParameters[$name]
    }
}
if ($List) {
    AutopilotImport.Client\Get-AutopilotTagPolicy @parameters
}
else {
    $parameters.TagAuthorizationRule = $TagAuthorizationRule
    if ($PSBoundParameters.ContainsKey(
            'RestrictedManagementAdministrativeUnitName')) {
        $parameters.RestrictedManagementAdministrativeUnitName = `
            $RestrictedManagementAdministrativeUnitName
    }
    if ($WhatIfPreference) {
        $parameters.WhatIf = $true
    }
    AutopilotImport.Client\Set-AutopilotTagPolicy @parameters
}
