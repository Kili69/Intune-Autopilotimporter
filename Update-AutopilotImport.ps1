#Requires -Version 7.2
# Project-Version: 1.0.20260826.1
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
.SYNOPSIS
Updates an existing Autopilot Import deployment from the current source tree.

.DESCRIPTION
Discovers the installed client configuration, reads the current Group Tag
policy through the Function management API, preserves configured policy
managers and optional RMAU, and reads the deployed extension attribute and
region from Azure. It then invokes Install-AutopilotImport.ps1 with the
existing resource names.

.PARAMETER ConfigPath
Path to the installed client.settings.json. When omitted, the newest version
under Documents\PowerShell\Scripts\AutopilotImport is selected.

.PARAMETER ClientToolsPath
Client package destination. By default, it is derived from ConfigPath.

.PARAMETER InstallMissingModules
Allows the installer to install missing PowerShell and Bicep prerequisites.

.PARAMETER SkipEntraAppConfiguration
Skips Entra application configuration during the update.

.PARAMETER SkipGraphPermission
Skips managed identity Microsoft Graph permission assignment.

.PARAMETER SkipPublish
Skips publishing Function source code.

.PARAMETER SkipSmokeTest
Skips the Easy Auth smoke test.

.EXAMPLE
.\Update-AutopilotImport.ps1

Updates the deployment referenced by the newest installed client package.

.EXAMPLE
.\Update-AutopilotImport.ps1 -WhatIf

Displays the resolved deployment and installer plan without changing it.

.EXAMPLE
.\Update-AutopilotImport.ps1 `
    -ConfigPath 'C:\Tools\AutopilotImport\Modules\AutopilotImport.Client\1.0.20260826.1\client.settings.json' `
    -InstallMissingModules

Updates the deployment selected by an explicit client configuration and
installs missing local prerequisites when necessary.

.OUTPUTS
System.Management.Automation.PSCustomObject. The deployment result returned by
Install-AutopilotImport.ps1.

.NOTES
The updating account needs permission to read the Function App configuration,
update its Azure resources, and read the current Group Tag policy through the
Function management API.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string] $ConfigPath,

    [string] $ClientToolsPath,

    [switch] $InstallMissingModules,

    [switch] $SkipEntraAppConfiguration,

    [switch] $SkipGraphPermission,

    [switch] $SkipPublish,

    [switch] $SkipSmokeTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Update discovery helpers

function Resolve-AutopilotUpdateConfigPath {
    <#
    .SYNOPSIS
    Resolves the client configuration used to identify a deployment.

    .DESCRIPTION
    Returns an explicitly supplied client.settings.json path. When no path is
    supplied, searches the default AutopilotImport client module directory and
    selects the configuration from the highest versioned directory.

    .PARAMETER Path
    Optional path to a specific client.settings.json file.

    .OUTPUTS
    System.String. The absolute path to client.settings.json.
    #>
    param([string] $Path)

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        return (Resolve-Path -LiteralPath $Path).Path
    }

    $documentsPath = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($documentsPath)) {
        $documentsPath = $HOME
    }
    $moduleRoot = Join-Path $documentsPath `
        'PowerShell\Scripts\AutopilotImport\Modules\AutopilotImport.Client'
    $candidates = @(Get-ChildItem `
        -Path (Join-Path $moduleRoot '*\client.settings.json') `
        -File `
        -ErrorAction SilentlyContinue)
    if ($candidates.Count -eq 0) {
        throw "No installed client.settings.json was found under '$moduleRoot'. Use -ConfigPath."
    }

    return ($candidates | Sort-Object {
        $parsedVersion = [version]::new()
        if ([version]::TryParse($_.Directory.Name, [ref] $parsedVersion)) {
            $parsedVersion
        }
        else {
            [version]'0.0'
        }
    } -Descending | Select-Object -First 1).FullName
}

function Get-AutopilotClientToolsPath {
    <#
    .SYNOPSIS
    Resolves the destination of the updated portable client package.

    .DESCRIPTION
    Returns OverridePath when supplied. Otherwise, derives the package root
    from the expected Modules\AutopilotImport.Client\<version> layout of the
    selected client settings file.

    .PARAMETER SettingsPath
    Absolute path to a versioned client.settings.json file.

    .PARAMETER OverridePath
    Optional client package destination that takes precedence over the path
    derived from SettingsPath.

    .OUTPUTS
    System.String. The absolute client tools directory.
    #>
    param(
        [Parameter(Mandatory)][string] $SettingsPath,
        [string] $OverridePath
    )

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        return [IO.Path]::GetFullPath($OverridePath)
    }

    $versionDirectory = Split-Path $SettingsPath -Parent
    $moduleDirectory = Split-Path $versionDirectory -Parent
    $modulesDirectory = Split-Path $moduleDirectory -Parent
    if ((Split-Path $modulesDirectory -Leaf) -ne 'Modules') {
        throw "ClientToolsPath cannot be derived from '$SettingsPath'. Use -ClientToolsPath."
    }
    return Split-Path $modulesDirectory -Parent
}

function ConvertTo-UpdateTagAuthorizationRules {
    <#
    .SYNOPSIS
    Converts the deployed Group Tag policy into installer rule strings.

    .DESCRIPTION
    Validates every policy entry and converts it to the
    <group-object-id>=<tag1>,<tag2> format accepted by
    Install-AutopilotImport.ps1. Invalid or empty policies terminate the
    update before deployment changes are made.

    .PARAMETER Policy
    Group Tag policy objects returned by Get-AutopilotTagPolicy.

    .OUTPUTS
    System.String[]. Installer-compatible Group Tag authorization rules.
    #>
    param([Parameter(Mandatory)][object[]] $Policy)

    $rules = @($Policy | ForEach-Object {
        $tags = @($_.tags | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string] $_)
        })
        if ([string]::IsNullOrWhiteSpace([string] $_.groupId) -or
            $tags.Count -eq 0) {
            throw 'The current Group Tag policy contains an invalid rule.'
        }
        "$($_.groupId)=$($tags -join ',')"
    })
    if ($rules.Count -eq 0) {
        throw 'The current Group Tag policy is empty.'
    }
    return $rules
}

function Get-UpdateRestrictedManagementAdministrativeUnitName {
    <#
    .SYNOPSIS
    Reads the administrative unit preserved by the current policy.

    .DESCRIPTION
    Returns the single non-empty restricted management administrative unit
    name stored in the policy. The update stops when policy entries disagree,
    because choosing one value could silently change deployment behavior.

    .PARAMETER Policy
    Current Group Tag policy objects. Older policies may omit the
    restrictedManagementAdministrativeUnitName property.

    .OUTPUTS
    System.String. The configured administrative unit name, or no output when
    the existing policy does not configure one.
    #>
    param([object[]] $Policy = @())

    $names = @($Policy | Where-Object {
        $_.PSObject.Properties[
            'restrictedManagementAdministrativeUnitName'
        ] -and -not [string]::IsNullOrWhiteSpace(
            [string] $_.restrictedManagementAdministrativeUnitName)
    } | ForEach-Object {
        ([string] $_.restrictedManagementAdministrativeUnitName).Trim()
    } | Select-Object -Unique)
    if ($names.Count -gt 1) {
        throw 'The current Group Tag policy contains multiple restricted management administrative units.'
    }
    return $names | Select-Object -First 1
}

#endregion Update discovery helpers

#region Resolve installed deployment

$projectRoot = $PSScriptRoot
$installerPath = Join-Path $projectRoot 'Install-AutopilotImport.ps1'
$clientModulePath = Join-Path $projectRoot `
    'src\AutopilotImport.Client\AutopilotImport.Client.psd1'
if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    throw "Installer not found: $installerPath"
}

$resolvedConfigPath = Resolve-AutopilotUpdateConfigPath -Path $ConfigPath
$settings = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json
$requiredSettings = @(
    'managementUrl',
    'apiApplicationIdUri',
    'tenantId',
    'subscriptionId',
    'resourceGroupName',
    'functionAppName'
)
foreach ($settingName in $requiredSettings) {
    if ($null -eq $settings.PSObject.Properties[$settingName] -or
        [string]::IsNullOrWhiteSpace([string] $settings.$settingName)) {
        throw "Client configuration '$resolvedConfigPath' is missing '$settingName'."
    }
}
$apiAudience = [string] $settings.apiApplicationIdUri
$entraClientIdText = $apiAudience -replace '^api://', ''
$entraClientId = [guid]::Empty
if (-not [guid]::TryParse($entraClientIdText, [ref] $entraClientId)) {
    throw "API audience '$apiAudience' does not contain a valid Entra Client ID."
}
$resolvedClientToolsPath = Get-AutopilotClientToolsPath `
    -SettingsPath $resolvedConfigPath `
    -OverridePath $ClientToolsPath

#endregion Resolve installed deployment

#region Read current deployment configuration

if (-not (Get-Module -ListAvailable -Name 'Az.Accounts')) {
    if (-not $InstallMissingModules) {
        throw 'Az.Accounts is required. Run again with -InstallMissingModules.'
    }
    Install-Module `
        -Name 'Az.Accounts' `
        -Scope CurrentUser `
        -Force `
        -AllowClobber
}
Import-Module 'Az.Accounts' -ErrorAction Stop

Import-Module $clientModulePath -Force
$policyResponse = Get-AutopilotTagPolicy -ConfigPath $resolvedConfigPath
$tagAuthorizationRules = ConvertTo-UpdateTagAuthorizationRules `
    -Policy @($policyResponse.policy)
$restrictedManagementAdministrativeUnitName = `
    Get-UpdateRestrictedManagementAdministrativeUnitName `
        -Policy @($policyResponse.policy)

if (-not (Get-Command Get-AzContext -ErrorAction SilentlyContinue) -or
    -not (Get-Command Invoke-AzRestMethod -ErrorAction SilentlyContinue)) {
    throw 'Az.Accounts did not provide the required Azure commands.'
}
$currentContext = Get-AzContext -ErrorAction SilentlyContinue
if (-not $currentContext -or
    [string] $currentContext.Subscription.Id -ne [string] $settings.subscriptionId -or
    [string] $currentContext.Tenant.Id -ne [string] $settings.tenantId) {
    Connect-AzAccount `
        -Tenant $settings.tenantId `
        -Subscription $settings.subscriptionId | Out-Null
}
Set-AzContext `
    -Tenant $settings.tenantId `
    -Subscription $settings.subscriptionId `
    -WhatIf:$false | Out-Null

$resourceId = "/subscriptions/$($settings.subscriptionId)/resourceGroups/$($settings.resourceGroupName)/providers/Microsoft.Web/sites/$($settings.functionAppName)"
$siteResponse = Invoke-AzRestMethod `
    -Method GET `
    -Path "${resourceId}?api-version=2023-12-01"
if ($siteResponse.StatusCode -ge 400) {
    $siteError = $siteResponse.Content | ConvertFrom-Json
    throw "Function App lookup failed: $($siteError.error.message)"
}
$site = $siteResponse.Content | ConvertFrom-Json
if (-not $site.id) {
    throw "Function App '$($settings.functionAppName)' was not found."
}
$appSettingsResponse = Invoke-AzRestMethod `
    -Method POST `
    -Path "$resourceId/config/appsettings/list?api-version=2023-12-01" `
    -WhatIf:$false
if ($appSettingsResponse.StatusCode -ge 400) {
    $appSettingsError = $appSettingsResponse.Content | ConvertFrom-Json
    throw "Function App settings lookup failed. Updating while preserving manager configuration requires Microsoft.Web/sites/config/list/action. $($appSettingsError.error.message)"
}
$appSettings = $appSettingsResponse.Content | ConvertFrom-Json
$extensionAttribute = [string] `
    $appSettings.properties.DEVICE_TAG_EXTENSION_ATTRIBUTE
if ([string]::IsNullOrWhiteSpace($extensionAttribute)) {
    $extensionAttribute = 'extensionAttribute1'
}
$managerPolicy = $appSettings.properties.MANAGER_AUTHORIZATION_POLICY |
    ConvertFrom-Json
$managerPrincipalIds = @(
    @($managerPolicy.installerPrincipalId) +
    @($managerPolicy.additionalPrincipalIds) |
    Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) } |
    Select-Object -Unique
)

#endregion Read current deployment configuration

#region Invoke idempotent installer

Write-Host "`nResolved update" -ForegroundColor Cyan
Write-Host "  Configuration : $resolvedConfigPath"
Write-Host "  Subscription  : $($settings.subscriptionId)"
Write-Host "  Tenant        : $($settings.tenantId)"
Write-Host "  Resource group: $($settings.resourceGroupName)"
Write-Host "  Function      : $($settings.functionAppName)"
Write-Host "  Region        : $($site.location)"
Write-Host "  Client tools  : $resolvedClientToolsPath"
Write-Host "  Device Tag attribute: $extensionAttribute"
Write-Host "  Restricted management AU: $restrictedManagementAdministrativeUnitName"
Write-Host "  Preserved Group Tag rules: $($tagAuthorizationRules.Count)"
Write-Host "  Preserved manager principals: $($managerPrincipalIds.Count)"

$installerParameters = @{
    SubscriptionId              = [string] $settings.subscriptionId
    TenantId                    = [string] $settings.tenantId
    ResourceGroupName           = [string] $settings.resourceGroupName
    Location                    = [string] $site.location
    FunctionAppName             = [string] $settings.functionAppName
    EntraClientId               = $entraClientId.ToString()
    ApiAudience                 = $apiAudience
    TagAuthorizationRule        = $tagAuthorizationRules
    RestrictedManagementAdministrativeUnitName = `
        [string] $restrictedManagementAdministrativeUnitName
    DeviceTagExtensionAttribute = $extensionAttribute
    TagManagerPrincipalId       = @($managerPrincipalIds)
    ClientToolsPath             = $resolvedClientToolsPath
    InstallMissingModules       = $InstallMissingModules
    SkipEntraAppConfiguration   = $SkipEntraAppConfiguration
    SkipGraphPermission         = $SkipGraphPermission
    SkipPublish                 = $SkipPublish
    SkipSmokeTest               = $SkipSmokeTest
}

$target = "$($settings.functionAppName) in $($settings.resourceGroupName)"
if ($WhatIfPreference) {
    & $installerPath @installerParameters -WhatIf
    return
}
if (-not $PSCmdlet.ShouldProcess($target, 'Update Autopilot Import deployment')) {
    return
}

& $installerPath @installerParameters -Confirm:$false

#endregion Invoke idempotent installer