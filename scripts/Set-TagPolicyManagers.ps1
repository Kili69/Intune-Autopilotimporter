#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Resources, Az.Websites
# Project-Version: 1.0.20260811.2
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
.SYNOPSIS
Adds or removes users and groups allowed to manage Group Tags.

.DESCRIPTION
Updates the Function App's manager authorization policy. The current Azure
principal must have an effective Owner or Contributor role at the Function App
scope or an ancestor scope. Other write-capable roles are intentionally not
accepted. The installing user and Intune Role Administrator authorization are
preserved.

.PARAMETER SubscriptionId
Azure subscription GUID containing the Function App.

.PARAMETER TenantId
Microsoft Entra tenant GUID containing the manager users and groups.

.PARAMETER ResourceGroupName
Resource group containing the Function App.

.PARAMETER FunctionAppName
Name of the installed Function App.

.PARAMETER AddPrincipalId
Entra user or group object IDs to add as explicit Group Tag managers.

.PARAMETER RemovePrincipalId
Entra user or group object IDs to remove from the explicit manager list.

.EXAMPLE
.\scripts\Set-TagPolicyManagers.ps1 `
    -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -TenantId '11111111-1111-1111-1111-111111111111' `
    -ResourceGroupName 'rg-autopilot-import' `
    -FunctionAppName 'func-autopilot-contoso' `
    -AddPrincipalId '22222222-2222-2222-2222-222222222222' `
    -WhatIf

Previews adding a user or group to the explicit manager list.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [guid] $SubscriptionId,

    [Parameter(Mandatory)]
    [guid] $TenantId,

    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [string] $FunctionAppName,

    [guid[]] $AddPrincipalId,

    [guid[]] $RemovePrincipalId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (@($AddPrincipalId).Count -eq 0 -and @($RemovePrincipalId).Count -eq 0) {
    throw 'Specify at least one AddPrincipalId or RemovePrincipalId.'
}

$modulePath = Join-Path $PSScriptRoot '..\src\AutopilotImport\AutopilotImport.psm1'
Import-Module $modulePath -Force

$currentContext = Get-AzContext -ErrorAction SilentlyContinue
$contextMatches = $currentContext -and
    [string] $currentContext.Subscription.Id -eq [string] $SubscriptionId -and
    [string] $currentContext.Tenant.Id -eq [string] $TenantId
if (-not $contextMatches) {
    Connect-AzAccount -Tenant $TenantId -Subscription $SubscriptionId | Out-Null
}
Set-AzContext -Tenant $TenantId -Subscription $SubscriptionId -WhatIf:$false | Out-Null

$functionApp = Get-AzWebApp `
    -ResourceGroupName $ResourceGroupName `
    -Name $FunctionAppName
if (-not $functionApp) {
    throw "Function App '$FunctionAppName' was not found in resource group '$ResourceGroupName'."
}

$tokenResult = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'
$accessToken = if ($tokenResult.Token -is [Security.SecureString]) {
    ConvertFrom-SecureString -SecureString $tokenResult.Token -AsPlainText
}
else {
    [string] $tokenResult.Token
}
$tokenParts = $accessToken.Split('.')
if ($tokenParts.Count -lt 2) {
    throw 'The Azure access token does not contain a valid principal identity.'
}
$payload = $tokenParts[1].Replace('-', '+').Replace('_', '/')
$payload = $payload.PadRight($payload.Length + ((4 - $payload.Length % 4) % 4), '=')
$tokenClaims = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String($payload)
) | ConvertFrom-Json
$currentPrincipalId = [guid] $tokenClaims.oid

$roleAssignments = @(Get-AzRoleAssignment `
    -ObjectId $currentPrincipalId `
    -Scope $functionApp.Id `
    -ExpandPrincipalGroups)
if (-not (Test-TagManagerPolicyAdministratorRole `
        -RoleAssignment $roleAssignments `
        -FunctionResourceId $functionApp.Id
    )) {
    throw "Only an Owner or Contributor of Function App '$FunctionAppName' may change its Group Tag managers."
}

$appSettings = @{}
foreach ($setting in @($functionApp.SiteConfig.AppSettings)) {
    $appSettings[[string] $setting.Name] = [string] $setting.Value
}
if (-not $appSettings.ContainsKey('MANAGER_AUTHORIZATION_POLICY')) {
    throw "Function App '$FunctionAppName' does not contain MANAGER_AUTHORIZATION_POLICY."
}

try {
    $currentPolicy = $appSettings.MANAGER_AUTHORIZATION_POLICY | ConvertFrom-Json
    $installerPrincipalId = ([guid] $currentPolicy.installerPrincipalId).ToString()
    $additionalPrincipalIds = @($currentPolicy.additionalPrincipalIds | ForEach-Object {
        ([guid] $_).ToString()
    })
}
catch {
    throw "The existing MANAGER_AUTHORIZATION_POLICY is invalid: $($_.Exception.Message)"
}

$removePrincipalIds = @($RemovePrincipalId | ForEach-Object { $_.ToString() })
if ($installerPrincipalId -in $removePrincipalIds) {
    throw 'The installing user cannot be removed from the manager policy.'
}
$updatedAdditionalPrincipalIds = @(
    @($additionalPrincipalIds) + @($AddPrincipalId | ForEach-Object { $_.ToString() }) |
        Where-Object { $_ -notin $removePrincipalIds -and $_ -ne $installerPrincipalId } |
        Sort-Object -Unique
)
$updatedPolicy = [ordered]@{
    installerPrincipalId          = $installerPrincipalId
    additionalPrincipalIds        = $updatedAdditionalPrincipalIds
    allowIntuneRoleAdministrators = $true
}

if ($PSCmdlet.ShouldProcess(
        "$ResourceGroupName/$FunctionAppName",
        'Update Group Tag manager users and groups'
    )) {
    $appSettings.MANAGER_AUTHORIZATION_POLICY = $updatedPolicy |
        ConvertTo-Json -Depth 4 -Compress
    Set-AzWebApp `
        -ResourceGroupName $ResourceGroupName `
        -Name $FunctionAppName `
        -AppSettings $appSettings | Out-Null
}

[pscustomobject]@{
    FunctionAppName = $FunctionAppName
    ManagerPolicy   = $updatedPolicy
}
