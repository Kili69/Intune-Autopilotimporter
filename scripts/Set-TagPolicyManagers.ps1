#Requires -Version 7.2
# Project-Version: 1.0.20260826.1
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
.SYNOPSIS
Compatibility wrapper for Update-AutopilotTagPolicyManager.
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
AutopilotImport.Client\Update-AutopilotTagPolicyManager @parameters
