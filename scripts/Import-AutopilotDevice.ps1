#Requires -Version 7.2
# Project-Version: 1.0.20260902.1
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
.SYNOPSIS
Compatibility wrapper for Import-AutopilotDevice in AutopilotImport.Client.

.DESCRIPTION
Validates and imports Windows Autopilot devices from a CSV file through the
secured Autopilot Import Function. The script loads AutopilotImport.Client from
the installation or source tree and forwards the supplied parameters to its
Import-AutopilotDevice command.

The CSV must contain the columns Device Serial Number and Hardware Hash. Each
hardware hash is checked for valid Base64 encoding before any device is sent.
Values omitted on the command line are resolved from the client configuration
file. The requested Group Tag is authorized by the Function for the signed-in
user before Intune accepts the import.

.PARAMETER CsvPath
Path to the Windows Autopilot CSV file. The file must contain Device Serial
Number and Hardware Hash columns and at least one device row.

.PARAMETER FunctionUrl
HTTPS URL of the Autopilot Import Function endpoint. When omitted, the value is
read from the client configuration.

.PARAMETER ApiApplicationIdUri
Application ID URI used as the OAuth audience for the Autopilot Import API.
When omitted, the value is read from the client configuration.

.PARAMETER GroupTag
Autopilot Group Tag requested for every device in the CSV. The signed-in user
must be authorized to use this tag.

.PARAMETER TenantId
Microsoft Entra tenant used for authentication. When omitted, the value is
read from the client configuration.

.PARAMETER ConfigPath
Path to the client.settings.json file used to resolve values not supplied as
parameters.

.PARAMETER ValidateOnly
Validates the CSV and resolved configuration without authenticating or sending
requests to the Function.

.OUTPUTS
PSCustomObject. ValidateOnly returns a validation summary containing the CSV
path, device count, Group Tag, resolved configuration, and IsValid. A normal
import returns an enriched API response for each device in the CSV.

.EXAMPLE
.\Import-AutopilotDevice.ps1 `
    -CsvPath '.\devices.csv' `
    -GroupTag 'PAW' `
    -ConfigPath '.\client.settings.json' `
    -ValidateOnly

Validates the CSV and configuration without authenticating or importing any
devices.

.EXAMPLE
.\Import-AutopilotDevice.ps1 `
    -CsvPath '.\devices.csv' `
    -GroupTag 'PAW' `
    -ConfigPath '.\client.settings.json'

Imports every valid CSV row by using the endpoint and authentication settings
from client.settings.json.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
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
