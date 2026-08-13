#Requires -Version 7.2
# Project-Version: 1.0.20260813.1
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
.SYNOPSIS
Compatibility wrapper for AutopilotImport.Client tag policy commands.
#>

[CmdletBinding(DefaultParameterSetName = 'Set', SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Get')]
    [switch] $List,

    [Parameter(Mandatory, ParameterSetName = 'Set')]
    [string[]] $TagAuthorizationRule,

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
    if ($WhatIfPreference) {
        $parameters.WhatIf = $true
    }
    AutopilotImport.Client\Set-AutopilotTagPolicy @parameters
}
