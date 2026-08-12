#Requires -Version 7.2
#Requires -Modules Az.Accounts
# Project-Version: 1.0.20260811.2
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
DISCLAIMER:
This sample script is not supported under any Microsoft standard support program or service.
The sample script is provided AS IS without warranty of any kind. Microsoft further disclaims
all implied warranties including, without limitation, any implied warranties of merchantability
or of fitness for a particular purpose. The entire risk arising out of the use or performance of
the sample scripts and documentation remains with you. In no event shall Microsoft, its authors,
or anyone else involved in the creation, production, or delivery of the scripts be liable for any
damages whatsoever (including, without limitation, damages for loss of business profits, business
interruption, loss of business information, or other pecuniary loss) arising out of the use of or
inability to use the sample scripts or documentation, even if Microsoft has been advised of the
possibility of such damages.
#>

<#
.SYNOPSIS
Imports Windows Autopilot devices from a CSV file through the secured Function.

.DESCRIPTION
Validates a Microsoft Autopilot CSV, obtains a user token for the Function API,
and submits each serial number and hardware hash with the requested Group Tag.
The Function validates the caller's Entra group membership before
its managed identity performs the Microsoft Graph import.

FunctionUrl, ApiApplicationIdUri, and TenantId default to values in
client.settings.json written by Install-AutopilotImport.ps1. Explicit
parameters override the configuration file.

.PARAMETER CsvPath
Path to a CSV containing Device Serial Number and Hardware Hash columns. The
file can contain one or more devices.

.PARAMETER FunctionUrl
HTTPS endpoint of the import Function, including /api/devices/import.

.PARAMETER ApiApplicationIdUri
Application ID URI used as the access-token resource, such as
api://00000000-0000-0000-0000-000000000000.

.PARAMETER GroupTag
Device Group Tag requested for every device in the CSV. The server permits it
only when a configured rule authorizes the caller's Entra group.

.PARAMETER TenantId
Entra tenant GUID used for user authentication.

.PARAMETER ConfigPath
Path to the client settings JSON file. The default is client.settings.json in
the repository root.

.PARAMETER ValidateOnly
Validates CSV structure, required values, and Base64 hardware hashes without
signing in or calling the Function API.

.EXAMPLE
.\scripts\Import-AutopilotDevice.ps1 `
    -CsvPath '.\devices.csv' `
    -GroupTag 'PAW' `
    -ValidateOnly

Validates all rows and displays the resolved client settings.

.EXAMPLE
.\scripts\Import-AutopilotDevice.ps1 `
    -CsvPath '.\devices.csv' `
    -GroupTag 'PAW'

Imports all CSV rows using defaults from client.settings.json.

.EXAMPLE
.\scripts\Import-AutopilotDevice.ps1 `
    -CsvPath '.\devices.csv' `
    -GroupTag 'PAW' `
    -ConfigPath 'C:\Config\autopilot-client.json'

Imports devices using an alternate client configuration file.

.OUTPUTS
With ValidateOnly, returns a validation summary. During import, returns the
Function response for each CSV row, including import ID, serial number, Group
Tag, status, and correlation ID.

.NOTES
The signed-in user needs access only to the Function API through the configured
Entra group-to-tag policy. The user does not require Intune permissions.
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

    [string] $ConfigPath = (Join-Path $PSScriptRoot '..\client.settings.json'),

    [switch] $ValidateOnly
)

if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    try {
        $clientSettings = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Client configuration '$ConfigPath' is not valid JSON: $($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace($FunctionUrl)) {
        $FunctionUrl = [string] $clientSettings.functionUrl
    }
    if ([string]::IsNullOrWhiteSpace($ApiApplicationIdUri)) {
        $ApiApplicationIdUri = [string] $clientSettings.apiApplicationIdUri
    }
    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        $TenantId = [string] $clientSettings.tenantId
    }
}

$rows = @(Import-Csv -LiteralPath $CsvPath)
if ($rows.Count -eq 0) {
    throw 'The Autopilot CSV does not contain any devices.'
}

$requiredColumns = @('Device Serial Number', 'Hardware Hash')
$headers = @($rows[0].PSObject.Properties.Name)
$missingColumns = @($requiredColumns | Where-Object { $_ -notin $headers })
if ($missingColumns.Count -gt 0) {
    throw "The Autopilot CSV is missing required columns: $($missingColumns -join ', ')."
}

$devices = for ($rowIndex = 0; $rowIndex -lt $rows.Count; $rowIndex++) {
    $serialNumber = [string] $rows[$rowIndex].'Device Serial Number'
    $hardwareIdentifier = [string] $rows[$rowIndex].'Hardware Hash'

    if ([string]::IsNullOrWhiteSpace($serialNumber)) {
        throw "CSV row $($rowIndex + 2) does not contain a Device Serial Number."
    }
    if ([string]::IsNullOrWhiteSpace($hardwareIdentifier)) {
        throw "CSV row $($rowIndex + 2) does not contain a Hardware Hash."
    }
    try {
        $hashBytes = [Convert]::FromBase64String($hardwareIdentifier)
    }
    catch {
        throw "CSV row $($rowIndex + 2) contains an invalid Base64 Hardware Hash."
    }
    if ($hashBytes.Length -eq 0) {
        throw "CSV row $($rowIndex + 2) contains an empty Hardware Hash."
    }

    [pscustomobject]@{
        serialNumber       = $serialNumber.Trim()
        hardwareIdentifier = $hardwareIdentifier
    }
}

if ($ValidateOnly) {
    [pscustomobject]@{
        CsvPath                = (Resolve-Path -LiteralPath $CsvPath).Path
        DeviceCount            = $devices.Count
        GroupTag               = $GroupTag
        FunctionUrl            = $FunctionUrl
        ApiApplicationIdUri    = $ApiApplicationIdUri
        TenantId               = $TenantId
        ClientSettingsPath     = if (Test-Path -LiteralPath $ConfigPath) {
            (Resolve-Path -LiteralPath $ConfigPath).Path
        }
        else {
            $null
        }
        IsValid                = $true
    }
    return
}

if ($FunctionUrl -notmatch '^https://') {
    throw "FunctionUrl is missing or invalid. Run the installer or pass -FunctionUrl explicitly."
}
if ($ApiApplicationIdUri -notmatch '^api://') {
    throw "ApiApplicationIdUri is missing or invalid. Run the installer or pass -ApiApplicationIdUri explicitly."
}
if ([string]::IsNullOrWhiteSpace($TenantId)) {
    throw "TenantId is missing. Run the installer or pass -TenantId explicitly."
}
$parsedTenantId = [guid]::Empty
if (-not [guid]::TryParse($TenantId, [ref] $parsedTenantId)) {
    throw 'TenantId must be a GUID.'
}

$context = Get-AzContext
if (-not $context -or ($TenantId -and $context.Tenant.Id -ne $TenantId)) {
    $connectParameters = @{}
    if ($TenantId) {
        $connectParameters.Tenant = $TenantId
    }

    Connect-AzAccount @connectParameters | Out-Null
}

$tokenResult = Get-AzAccessToken -ResourceUrl $ApiApplicationIdUri
$accessToken = if ($tokenResult.Token -is [Security.SecureString]) {
    ConvertFrom-SecureString -SecureString $tokenResult.Token -AsPlainText
}
else {
    [string] $tokenResult.Token
}

foreach ($device in $devices) {
    $requestBody = @{
        serialNumber       = $device.serialNumber
        hardwareIdentifier = $device.hardwareIdentifier
        groupTag            = $GroupTag
    } | ConvertTo-Json -Compress

    Invoke-RestMethod `
        -Method Post `
        -Uri $FunctionUrl.TrimEnd('/') `
        -Authentication Bearer `
        -Token (ConvertTo-SecureString $accessToken -AsPlainText -Force) `
        -ContentType 'application/json' `
        -Body $requestBody
}