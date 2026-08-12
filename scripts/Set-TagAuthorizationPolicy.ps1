#Requires -Version 7.2
#Requires -Modules Az.Accounts
# Project-Version: 1.0.20260812.2
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
.SYNOPSIS
Reads or updates Group Tag authorization through the protected Function API.

.DESCRIPTION
Authenticates the current user to the Autopilot import API. Configured manager
users and groups, the installing user, and Intune Role Administrators may read
or replace the complete group-to-tag policy. Azure resource permissions are not
required.

.PARAMETER List
Returns the current policy without changing it.

.PARAMETER TagAuthorizationRule
Complete desired group-to-tag configuration in the form
<Entra-group-object-ID>=<tag1>,<tag2>. Omit an existing rule to remove it.

.PARAMETER ManagementUrl
Management endpoint URL. By default it is loaded from client.settings.json.

.PARAMETER ApiApplicationIdUri
Application ID URI accepted by the Function API.

.PARAMETER TenantId
Microsoft Entra tenant GUID used for interactive authentication.

.PARAMETER ConfigPath
Path to client.settings.json written by the installer.

.EXAMPLE
.\scripts\Set-TagAuthorizationPolicy.ps1 -List

Returns the current group-to-tag policy.

.EXAMPLE
.\scripts\Set-TagAuthorizationPolicy.ps1 `
    -TagAuthorizationRule `
        '11111111-1111-1111-1111-111111111111=Standard,Kiosk', `
        '22222222-2222-2222-2222-222222222222=Privileged' `
    -WhatIf

Previews replacement of the complete policy. Remove -WhatIf to apply it.
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

    [string] $ConfigPath = (Join-Path $PSScriptRoot '..\client.settings.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    try {
        $clientSettings = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Client configuration '$ConfigPath' is not valid JSON: $($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace($ManagementUrl)) {
        $ManagementUrl = [string] $clientSettings.managementUrl
    }
    if ([string]::IsNullOrWhiteSpace($ApiApplicationIdUri)) {
        $ApiApplicationIdUri = [string] $clientSettings.apiApplicationIdUri
    }
    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        $TenantId = [string] $clientSettings.tenantId
    }
}

if ($ManagementUrl -notmatch '^https://') {
    throw 'ManagementUrl is missing or invalid. Run the installer or pass it explicitly.'
}
if ($ApiApplicationIdUri -notmatch '^api://') {
    throw 'ApiApplicationIdUri is missing or invalid. Run the installer or pass it explicitly.'
}
$parsedTenantId = [guid]::Empty
if (-not [guid]::TryParse($TenantId, [ref] $parsedTenantId)) {
    throw 'TenantId is missing or invalid.'
}

$currentContext = Get-AzContext -ErrorAction SilentlyContinue
if (-not $currentContext -or [string] $currentContext.Tenant.Id -ne [string] $parsedTenantId) {
    Connect-AzAccount -Tenant $parsedTenantId | Out-Null
}

$tokenResult = Get-AzAccessToken -ResourceUrl $ApiApplicationIdUri
$accessToken = if ($tokenResult.Token -is [Security.SecureString]) {
    ConvertFrom-SecureString -SecureString $tokenResult.Token -AsPlainText
}
else {
    [string] $tokenResult.Token
}
$secureToken = ConvertTo-SecureString $accessToken -AsPlainText -Force

if ($List) {
    Invoke-RestMethod `
        -Method Get `
        -Uri $ManagementUrl.TrimEnd('/') `
        -Authentication Bearer `
        -Token $secureToken
    return
}

$modulePath = Join-Path $PSScriptRoot '..\src\AutopilotImport\AutopilotImport.psm1'
Import-Module $modulePath -Force
$normalizedPolicy = @(ConvertTo-TagAuthorizationPolicy -Rules $TagAuthorizationRule)

if (-not $PSCmdlet.ShouldProcess(
        $ManagementUrl,
        "Replace tag authorization policy with $($normalizedPolicy.Count) group rule(s)"
    )) {
    return
}

$requestBody = @{ rules = @($TagAuthorizationRule) } | ConvertTo-Json -Depth 4 -Compress
Invoke-RestMethod `
    -Method Put `
    -Uri $ManagementUrl.TrimEnd('/') `
    -Authentication Bearer `
    -Token $secureToken `
    -ContentType 'application/json' `
    -Body $requestBody
