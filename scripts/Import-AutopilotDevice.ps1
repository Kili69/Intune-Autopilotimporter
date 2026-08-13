#Requires -Version 7.2
# Project-Version: 1.0.20260813.1
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
.SYNOPSIS
Compatibility wrapper for Import-AutopilotDevice in AutopilotImport.Client.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string] $CsvPath,

    [ValidatePattern('^https://')]
    [string] $FunctionUrl,

    [ValidatePattern('^api://')]
    [string] $ApiApplicationIdUri,

    [Parameter(Mandatory)]
    [ValidateLength(1, 128)]
    [string] $GroupTag,

    [string] $TenantId,

    [string] $ConfigPath,

    [switch] $ValidateOnly
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
AutopilotImport.Client\Import-AutopilotDevice @parameters
