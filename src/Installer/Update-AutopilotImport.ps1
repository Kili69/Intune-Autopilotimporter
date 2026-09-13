#Requires -Version 7.2
# Project-Version: 1.1.20260913.6
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
.SYNOPSIS
Updates an existing Autopilot Import deployment from the current source tree.

.DESCRIPTION
Discovers the installed client configuration, reads the current Group Tag
policy through the Function management API, preserves configured policy
managers and optional RMAU, and reads the deployed extension attribute and
region from Azure. It then invokes Install-AutopilotImport.ps1 with the
existing resource names. When this changes Application Insights from a
previously linked Log Analytics workspace to the integrated workspace in the
Function resource group, the script identifies the old workspace that can be
deleted after its remaining use and historical telemetry have been reviewed.

.PARAMETER ConfigPath
Path to the installed client.settings.json. When omitted, the newest version
from the portable client package, PSModulePath, or a standard per-user or
system-wide PowerShell module directory is selected. When no configuration is
installed, deployment values are resolved from parameters or interactive
prompts.

.PARAMETER SubscriptionId
Azure subscription GUID containing the existing Function App. The installed
configuration or current Az context is offered as the interactive default.

.PARAMETER TenantId
Microsoft Entra tenant GUID owning the existing deployment. The installed
configuration or current Az context is offered as the interactive default.

.PARAMETER ResourceGroupName
Name of the resource group containing the existing Function App.

.PARAMETER FunctionAppName
Name of the existing Azure Function App.

.PARAMETER FunctionUrl
HTTPS URL of the existing Azure Function App, including an optional API path.
The script derives the Function App name from an azurewebsites.net hostname and
searches the subscriptions available to the signed-in Azure account to resolve
the subscription, tenant, and resource group. Values discovered from this URL
take precedence over an automatically selected client configuration.

.PARAMETER ApiAudience
Optional API audience override. When omitted, it is read from the installed
configuration or the Function App's API_AUDIENCE setting.

.PARAMETER ManagementUrl
Optional Group Tag management endpoint override. When omitted, it is read
from the installed configuration or derived from the Function App hostname.

.PARAMETER ClientToolsPath
Client package destination. By default, it is derived from ConfigPath. When no
configuration is installed, the script prompts with the current user's
PowerShell script directory as the default.

.PARAMETER InstallMissingModules
Allows the installer to install missing PowerShell and Bicep prerequisites.

.PARAMETER Force
Runs the Azure update without prompting for execution confirmation. WhatIf
still takes precedence and does not perform the update.

.PARAMETER ForceGraphSignIn
Forces a fresh Microsoft Graph device-code sign-in. Use this after assigning
new Microsoft Entra roles or when interactive browser authentication is hidden.

.PARAMETER WebClientId
Client ID of the existing Entra web application. Overrides WEB_CLIENT_ID from
the deployed Function App settings when supplied.

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
.\Update-AutopilotImport.ps1 -Force

Updates the deployment without prompting for execution confirmation.

.EXAMPLE
.\Update-AutopilotImport.ps1 `
    -FunctionUrl 'https://func-autopilot-contoso.azurewebsites.net/api/ui/index.html' `
    -InstallMissingModules

Discovers the deployment from its Function URL and updates it. The signed-in
Azure account must be able to read the Function App and its subscription.

.EXAMPLE
.\Update-AutopilotImport.ps1 `
    -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -TenantId '11111111-1111-1111-1111-111111111111' `
    -ResourceGroupName 'rg-autopilot-import' `
    -FunctionAppName 'func-autopilot-contoso' `
    -InstallMissingModules

Updates an existing deployment when no client module or configuration is
installed on the current computer.

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

    [string] $SubscriptionId,

    [string] $TenantId,

    [string] $ResourceGroupName,

    [string] $FunctionAppName,

    [string] $FunctionUrl,

    [ValidatePattern('^api://')]
    [string] $ApiAudience,

    [ValidatePattern('^https://')]
    [string] $ManagementUrl,

    [string] $ClientToolsPath,

    [switch] $InstallMissingModules,

    [switch] $Force,

    [switch] $ForceGraphSignIn,

    [guid] $WebClientId,

    [switch] $SkipEntraAppConfiguration,

    [switch] $SkipGraphPermission,

    [switch] $SkipPublish,

    [switch] $SkipSmokeTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$setupLogPath = Join-Path ([IO.Path]::GetTempPath()) `
    "Intune-Autopilotimport-update-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N')).log"
Start-Transcript `
    -LiteralPath $setupLogPath `
    -IncludeInvocationHeader `
    -WhatIf:$false `
    -Force | Out-Null
$setupTranscriptActive = $true
Write-Host "Setup log: $setupLogPath"

try {
#region Update discovery helpers

function Resolve-AutopilotUpdateConfigPath {
    <#
    .SYNOPSIS
    Resolves the client configuration used to identify a deployment.

    .DESCRIPTION
    Returns an explicitly supplied client.settings.json path. When no path is
    supplied, searches the portable client package, PSModulePath, and standard
    per-user and system-wide PowerShell module directories. The configuration
    from the highest versioned directory is selected.

    .PARAMETER Path
    Optional path to a specific client.settings.json file.

    .PARAMETER AllowMissing
    Returns no path instead of throwing when no installed configuration is
    found. This enables parameter-based and interactive update discovery.

    .OUTPUTS
    System.String. The absolute path to client.settings.json.
    #>
    param(
        [string] $Path,
        [switch] $AllowMissing
    )

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        return (Resolve-Path -LiteralPath $Path).Path
    }

    $documentsPath = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($documentsPath)) {
        $documentsPath = $HOME
    }
    $moduleRoots = [Collections.Generic.List[string]]::new()
    $moduleRoots.Add((Join-Path $documentsPath `
        'AutopilotImport\Modules\AutopilotImport.Client'))
    $moduleRoots.Add((Join-Path $documentsPath `
        'PowerShell\Scripts\AutopilotImport\Modules\AutopilotImport.Client'))
    $moduleRoots.Add((Join-Path $documentsPath `
        'PowerShell\Modules\AutopilotImport.Client'))
    $moduleRoots.Add((Join-Path $documentsPath `
        'WindowsPowerShell\Modules\AutopilotImport.Client'))

    foreach ($powerShellModuleRoot in @(
            $env:PSModulePath -split [IO.Path]::PathSeparator
        )) {
        if (-not [string]::IsNullOrWhiteSpace($powerShellModuleRoot)) {
            $moduleRoots.Add((Join-Path $powerShellModuleRoot `
                'AutopilotImport.Client'))
        }
    }

    $programFilesPath = [Environment]::GetFolderPath('ProgramFiles')
    if (-not [string]::IsNullOrWhiteSpace($programFilesPath)) {
        $moduleRoots.Add((Join-Path $programFilesPath `
            'PowerShell\Modules\AutopilotImport.Client'))
        $moduleRoots.Add((Join-Path $programFilesPath `
            'WindowsPowerShell\Modules\AutopilotImport.Client'))
    }

    $searchedModuleRoots = @($moduleRoots | Select-Object -Unique)
    $candidates = @($searchedModuleRoots | ForEach-Object {
        $moduleRoot = $_
        if (-not (Test-Path -LiteralPath $moduleRoot -PathType Container)) {
            return
        }

        $unversionedSettingsPath = Join-Path $moduleRoot `
            'client.settings.json'
        if (Test-Path -LiteralPath $unversionedSettingsPath -PathType Leaf) {
            Get-Item -LiteralPath $unversionedSettingsPath
        }
        Get-ChildItem -LiteralPath $moduleRoot -Directory |
            ForEach-Object {
                $versionedSettingsPath = Join-Path $_.FullName `
                    'client.settings.json'
                if (Test-Path `
                    -LiteralPath $versionedSettingsPath `
                    -PathType Leaf) {
                    Get-Item -LiteralPath $versionedSettingsPath
                }
            }
    })
    if ($candidates.Count -eq 0) {
        if ($AllowMissing) {
            return $null
        }
        throw "No installed client.settings.json was found in the portable or PowerShell module directories: $($searchedModuleRoots -join ', '). Use -ConfigPath."
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

function Read-AutopilotUpdateValue {
    <#
    .SYNOPSIS
    Resolves an update value from a parameter, configuration, or prompt.

    .DESCRIPTION
    Returns CurrentValue when supplied. Otherwise, prompts interactively and
    offers DefaultValue when available. Empty required values terminate before
    any deployment changes are made.
    #>
    param(
        [string] $CurrentValue,
        [Parameter(Mandatory)]
        [string] $Prompt,
        [string] $DefaultValue
    )

    if (-not [string]::IsNullOrWhiteSpace($CurrentValue)) {
        return $CurrentValue.Trim()
    }

    $promptText = if ([string]::IsNullOrWhiteSpace($DefaultValue)) {
        $Prompt
    }
    else {
        "$Prompt [$DefaultValue]"
    }
    $enteredValue = Read-Host $promptText
    if ([string]::IsNullOrWhiteSpace($enteredValue)) {
        $enteredValue = $DefaultValue
    }
    if ([string]::IsNullOrWhiteSpace($enteredValue)) {
        throw "A value for '$Prompt' is required."
    }
    return $enteredValue.Trim()
}

function Get-AutopilotUpdateConfigurationValue {
    <#
    .SYNOPSIS
    Reads an optional value from an installed client configuration.
    #>
    param(
        [AllowNull()]
        [object] $Configuration,
        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($null -ne $Configuration -and
        $null -ne $Configuration.PSObject.Properties[$Name]) {
        return [string] $Configuration.$Name
    }
    return $null
}

function Resolve-AutopilotFunctionAppFromUrl {
    <#
    .SYNOPSIS
    Resolves an Azure Function App resource from its public URL.

    .DESCRIPTION
    Derives the Function App name from an azurewebsites.net hostname and
    searches either one requested subscription or every subscription available
    to the signed-in Azure account. Exactly one matching Function App is
    required.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Url,

        [string] $SubscriptionId
    )

    $parsedUrl = $null
    if (-not [uri]::TryCreate(
            $Url.Trim(),
            [UriKind]::Absolute,
            [ref] $parsedUrl
        ) -or $parsedUrl.Scheme -ne 'https') {
        throw "FunctionUrl must be an absolute HTTPS URL. Received '$Url'."
    }
    if ($parsedUrl.Host -notmatch `
        '^(?<name>[a-z0-9](?:[a-z0-9-]{0,58}[a-z0-9])?)\.azurewebsites\.net$') {
        throw "FunctionUrl must use the Function App's azurewebsites.net hostname. Received '$($parsedUrl.Host)'."
    }
    $functionAppName = $Matches.name

    $subscriptions = if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
        @(Get-AzSubscription -ErrorAction Stop)
    }
    else {
        @(Get-AzSubscription `
            -SubscriptionId $SubscriptionId `
            -ErrorAction Stop)
    }
    if ($subscriptions.Count -eq 0) {
        throw 'No accessible Azure subscriptions were found for Function URL discovery.'
    }

    $matches = [Collections.Generic.List[object]]::new()
    foreach ($subscription in $subscriptions) {
        try {
            Set-AzContext `
                -Subscription $subscription.Id `
                -Tenant $subscription.TenantId `
                -WhatIf:$false `
                -ErrorAction Stop | Out-Null
            $filter = [uri]::EscapeDataString(
                "resourceType eq 'Microsoft.Web/sites' and name eq '$functionAppName'"
            )
            $response = Invoke-AzRestMethod `
                -Method GET `
                -Path "/subscriptions/$($subscription.Id)/resources?api-version=2021-04-01&`$filter=$filter" `
                -ErrorAction Stop
            if ($response.StatusCode -ge 400) {
                Write-Verbose "Function URL discovery returned HTTP $($response.StatusCode) for subscription '$($subscription.Id)'."
                continue
            }
            foreach ($resource in @(($response.Content | ConvertFrom-Json).value)) {
                if ([string] $resource.type -ine 'Microsoft.Web/sites' -or
                    [string] $resource.name -ine $functionAppName) {
                    continue
                }
                $resourceIdMatch = [regex]::Match(
                    [string] $resource.id,
                    '^/subscriptions/(?<subscription>[^/]+)/resourceGroups/(?<resourceGroup>[^/]+)/providers/Microsoft\.Web/sites/(?<name>[^/]+)$',
                    [Text.RegularExpressions.RegexOptions]::IgnoreCase
                )
                if ($resourceIdMatch.Success) {
                    $matches.Add([pscustomobject]@{
                            SubscriptionId   = $resourceIdMatch.Groups['subscription'].Value
                            TenantId         = [string] $subscription.TenantId
                            ResourceGroupName = $resourceIdMatch.Groups['resourceGroup'].Value
                            FunctionAppName  = $resourceIdMatch.Groups['name'].Value
                            FunctionUrl      = "https://$($parsedUrl.Host)"
                        })
                }
            }
        }
        catch {
            Write-Verbose "Function URL discovery could not search subscription '$($subscription.Id)': $($_.Exception.Message)"
        }
    }

    if ($matches.Count -eq 0) {
        $scopeDescription = if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
            'the accessible Azure subscriptions'
        }
        else {
            "subscription '$SubscriptionId'"
        }
        throw "Function App '$functionAppName' was not found in $scopeDescription. Verify the URL and Azure access."
    }
    if ($matches.Count -gt 1) {
        $locations = $matches | ForEach-Object {
            "$($_.SubscriptionId)/$($_.ResourceGroupName)"
        }
        throw "Function URL '$Url' matched more than one accessible Function App: $($locations -join ', '). Use -SubscriptionId to select one deployment."
    }
    return $matches[0]
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
    Converts the deployed Group Tag policy into installer rule objects.

    .DESCRIPTION
    Validates every policy entry and preserves its optional restricted
    management administrative unit. Invalid or empty policies terminate the
    update before deployment changes are made.

    .PARAMETER Policy
    Group Tag policy objects returned by Get-AutopilotTagPolicy.

    .OUTPUTS
    System.Object[]. Installer-compatible Group Tag authorization rules.
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
        $rule = [ordered]@{
            groupId = ([guid] $_.groupId).ToString()
            tags = $tags
        }
        if ($_.PSObject.Properties[
                'restrictedManagementAdministrativeUnitName'] -and
            -not [string]::IsNullOrWhiteSpace(
                [string] $_.restrictedManagementAdministrativeUnitName)) {
            $rule.restrictedManagementAdministrativeUnitName =
                ([string] $_.restrictedManagementAdministrativeUnitName).Trim()
        }
        [pscustomobject] $rule
    })
    if ($rules.Count -eq 0) {
        throw 'The current Group Tag policy is empty.'
    }
    return $rules
}

function Assert-AutopilotAppSettingsResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Response
    )

    if ($Response.StatusCode -lt 400) {
        return
    }

    $responseError = $Response.Content | ConvertFrom-Json
    Write-Verbose "Function App settings lookup failed: $($responseError.error.message)"
    throw 'Unable to read the Function App settings. Grant the updating account the Microsoft.Web/sites/config/list/action permission and try again. Run with -Verbose for details.'
}

function Get-UpdateWebClientId {
    <#
    .SYNOPSIS
    Reads the optional web client ID from deployed Function App settings.

    .DESCRIPTION
    Returns an empty GUID when an older deployment has no WEB_CLIENT_ID so
    the installer can create or discover the Entra web application. When
    Entra application configuration is skipped, a valid existing ID is
    required.
    #>
    [OutputType([guid])]
    param(
        [Parameter(Mandatory)]
        [object] $Properties,

        [switch] $SkipEntraAppConfiguration
    )

    $webClientId = [guid]::Empty
    $webClientIdProperty = $Properties.PSObject.Properties['WEB_CLIENT_ID']
    $hasValidWebClientId = $null -ne $webClientIdProperty -and
        [guid]::TryParse([string] $webClientIdProperty.Value, [ref] $webClientId)
    if (-not $hasValidWebClientId -and $SkipEntraAppConfiguration) {
        throw 'The deployed Function does not contain a valid WEB_CLIENT_ID. Run the update without -SkipEntraAppConfiguration once.'
    }
    return $webClientId
}

function Get-UpdateApplicationInsightsWorkspaceResourceId {
    <#
    .SYNOPSIS
    Reads the workspace linked to the existing Application Insights resource.

    .DESCRIPTION
    Returns no value when Application Insights or its workspace linkage cannot
    be read. Workspace migration detection is informational and must not block
    an otherwise valid update.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [string] $FunctionAppName
    )

    $applicationInsightsResourceId = `
        "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/components/$FunctionAppName-insights"
    try {
        $response = Invoke-AzRestMethod `
            -Method GET `
            -Path "${applicationInsightsResourceId}?api-version=2020-02-02"
        if ($response.StatusCode -ge 400) {
            Write-Verbose "Application Insights workspace lookup returned HTTP $($response.StatusCode)."
            return $null
        }

        $applicationInsights = $response.Content | ConvertFrom-Json
        return [string] $applicationInsights.properties.WorkspaceResourceId
    }
    catch {
        Write-Verbose "Application Insights workspace lookup failed: $($_.Exception.Message)"
        return $null
    }
}

function Write-UpdateLogAnalyticsWorkspaceMigrationNotice {
    <#
    .SYNOPSIS
    Reports an old workspace after Application Insights was migrated.
    #>
    param(
        [string] $PreviousWorkspaceResourceId,

        [Parameter(Mandatory)]
        [string] $IntegratedWorkspaceResourceId
    )

    if ([string]::IsNullOrWhiteSpace($PreviousWorkspaceResourceId) -or
        $PreviousWorkspaceResourceId.TrimEnd('/').Equals(
            $IntegratedWorkspaceResourceId.TrimEnd('/'),
            [StringComparison]::OrdinalIgnoreCase)) {
        return
    }

    Write-Warning @"
Application Insights now uses the integrated Log Analytics workspace '$IntegratedWorkspaceResourceId'. The previously linked workspace '$PreviousWorkspaceResourceId' can be deleted if no other resource uses it and its historical telemetry is no longer required.
"@
}

function Test-AzurePermissionPattern {
    param(
        [Parameter(Mandatory)]
        [string] $Action,

        [Parameter(Mandatory)]
        [string] $Pattern
    )

    $expression = '^' + [regex]::Escape($Pattern).Replace('\*', '.*') + '$'
    return $Action -match $expression
}

function Assert-AzureUpdatePermissions {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName
    )

    $scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
    $requiredActions = @(
        'Microsoft.Resources/deployments/write'
        'Microsoft.Storage/storageAccounts/write'
        'Microsoft.Storage/storageAccounts/blobServices/write'
        'Microsoft.Storage/storageAccounts/blobServices/containers/write'
        'Microsoft.OperationalInsights/workspaces/write'
        'Microsoft.Insights/components/write'
        'Microsoft.Web/serverfarms/write'
        'Microsoft.Web/sites/write'
        'Microsoft.Web/sites/config/write'
        'Microsoft.Authorization/roleAssignments/write'
    )
    $permissionsResponse = try {
        Invoke-AzRestMethod `
            -Method GET `
            -Path "$scope/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
    }
    catch {
        Write-Verbose "Azure permission lookup failed: $($_ | Format-List * -Force | Out-String)"
        throw 'Azure update permissions could not be verified. Ensure the account has Owner, or Contributor together with Role Based Access Control Administrator, at the target scope.'
    }
    if ($permissionsResponse.StatusCode -ge 400) {
        Write-Verbose "Azure permission lookup failed: $($permissionsResponse.Content)"
        throw 'Azure update permissions could not be verified. Ensure the account has Owner, or Contributor together with Role Based Access Control Administrator, at the target scope.'
    }

    $permissionSets = @(($permissionsResponse.Content | ConvertFrom-Json).value)
    $missingActions = @($requiredActions | Where-Object {
        $requiredAction = $_
        -not ($permissionSets | Where-Object {
            $permission = $_
            $isAllowed = @($permission.actions | Where-Object {
                Test-AzurePermissionPattern `
                    -Action $requiredAction `
                    -Pattern ([string] $_)
            }).Count -gt 0
            $isExcluded = @($permission.notActions | Where-Object {
                Test-AzurePermissionPattern `
                    -Action $requiredAction `
                    -Pattern ([string] $_)
            }).Count -gt 0
            $isAllowed -and -not $isExcluded
        } | Select-Object -First 1)
    })
    if ($missingActions.Count -gt 0) {
        $missingCapabilities = @($missingActions | ForEach-Object {
            switch ($_) {
                'Microsoft.Resources/deployments/write' { 'ARM deployments' }
                'Microsoft.Storage/storageAccounts/write' { 'Storage accounts' }
                'Microsoft.Storage/storageAccounts/blobServices/write' { 'Blob services' }
                'Microsoft.Storage/storageAccounts/blobServices/containers/write' { 'Blob containers' }
                'Microsoft.OperationalInsights/workspaces/write' { 'Log Analytics workspaces' }
                'Microsoft.Insights/components/write' { 'Application Insights' }
                'Microsoft.Web/serverfarms/write' { 'App Service plans' }
                'Microsoft.Web/sites/write' { 'Function Apps' }
                'Microsoft.Web/sites/config/write' { 'Function App configuration' }
                'Microsoft.Authorization/roleAssignments/write' { 'Azure role assignments' }
            }
        } | Select-Object -Unique)
        $roleAssignmentMissing = $missingActions -contains `
            'Microsoft.Authorization/roleAssignments/write'
        $requiredRoles = if ($roleAssignmentMissing) {
            'Owner, or Contributor plus Role Based Access Control Administrator or User Access Administrator'
        }
        else {
            'Contributor or Owner'
        }
        $permissionDetails = "Azure update stopped before deployment. Target scope: $scope. Missing Azure actions: $($missingActions -join ', '). Assign $requiredRoles at this resource group or its subscription. After the assignment becomes effective, run Connect-AzAccount again and rerun the update."
        Write-Verbose $permissionDetails
        $permissionException = [UnauthorizedAccessException]::new(
            "Missing Azure permissions for: $($missingCapabilities -join ', ')."
        )
        $permissionException.Data['AutopilotUpdatePermissionError'] = $true
        $permissionException.Data['PermissionDetails'] = $permissionDetails
        throw $permissionException
    }
}

#endregion Update discovery helpers

#region Resolve installed deployment

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$projectRoot = if (Test-Path -LiteralPath (Join-Path $repositoryRoot 'VERSION')) {
    $repositoryRoot
}
else {
    $PSScriptRoot
}
$installerPath = if ($projectRoot -eq $PSScriptRoot) {
    Join-Path $projectRoot 'Install-AutopilotImport.ps1'
}
else {
    Join-Path $projectRoot 'src\Installer\Install-AutopilotImport.ps1'
}
$clientModulePath = Join-Path $projectRoot `
    'src\AutopilotImport.Client\AutopilotImport.Client.psd1'
if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    throw "Installer not found: $installerPath"
}

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

if (-not (Get-Command Get-AzContext -ErrorAction SilentlyContinue) -or
    -not (Get-Command Invoke-AzRestMethod -ErrorAction SilentlyContinue)) {
    throw 'Az.Accounts did not provide the required Azure commands.'
}
$currentContext = Get-AzContext -ErrorAction SilentlyContinue
$resolvedConfigPath = Resolve-AutopilotUpdateConfigPath `
    -Path $ConfigPath `
    -AllowMissing
$settings = if ($resolvedConfigPath) {
    Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json
}
else {
    $null
}

$configuredSubscriptionId = Get-AutopilotUpdateConfigurationValue `
    -Configuration $settings `
    -Name 'subscriptionId'
$configuredTenantId = Get-AutopilotUpdateConfigurationValue `
    -Configuration $settings `
    -Name 'tenantId'
$configuredResourceGroupName = Get-AutopilotUpdateConfigurationValue `
    -Configuration $settings `
    -Name 'resourceGroupName'
$configuredFunctionAppName = Get-AutopilotUpdateConfigurationValue `
    -Configuration $settings `
    -Name 'functionAppName'

$hasFunctionUrl = $PSBoundParameters.ContainsKey('FunctionUrl')
$discoveredFunctionApp = $null
if ($hasFunctionUrl) {
    if (-not $currentContext) {
        Connect-AzAccount | Out-Null
        $currentContext = Get-AzContext -ErrorAction Stop
    }
    $discoveryParameters = @{ Url = $FunctionUrl }
    if ($PSBoundParameters.ContainsKey('SubscriptionId')) {
        $discoveryParameters.SubscriptionId = $SubscriptionId
    }
    $discoveredFunctionApp = Resolve-AutopilotFunctionAppFromUrl `
        @discoveryParameters

    foreach ($identityParameter in @{
            TenantId         = $discoveredFunctionApp.TenantId
            ResourceGroupName = $discoveredFunctionApp.ResourceGroupName
            FunctionAppName  = $discoveredFunctionApp.FunctionAppName
        }.GetEnumerator()) {
        if ($PSBoundParameters.ContainsKey($identityParameter.Key) -and
            [string] $PSBoundParameters[$identityParameter.Key] -ine
                [string] $identityParameter.Value) {
            throw "FunctionUrl resolves $($identityParameter.Key) to '$($identityParameter.Value)', which conflicts with the supplied value '$($PSBoundParameters[$identityParameter.Key])'."
        }
    }
    Write-Host "Function URL resolved to '$($discoveredFunctionApp.FunctionAppName)' in resource group '$($discoveredFunctionApp.ResourceGroupName)' and subscription '$($discoveredFunctionApp.SubscriptionId)'."
}

$SubscriptionId = Read-AutopilotUpdateValue `
    -CurrentValue $(if ($discoveredFunctionApp) {
        $discoveredFunctionApp.SubscriptionId
    } elseif ($PSBoundParameters.ContainsKey('SubscriptionId')) {
        $SubscriptionId
    } else { $configuredSubscriptionId }) `
    -Prompt 'Azure Subscription ID' `
    -DefaultValue $(if ($currentContext) {
        [string] $currentContext.Subscription.Id
    })
$TenantId = Read-AutopilotUpdateValue `
    -CurrentValue $(if ($discoveredFunctionApp) {
        $discoveredFunctionApp.TenantId
    } elseif ($PSBoundParameters.ContainsKey('TenantId')) {
        $TenantId
    } else { $configuredTenantId }) `
    -Prompt 'Entra Tenant ID' `
    -DefaultValue $(if ($currentContext) {
        [string] $currentContext.Tenant.Id
    })
$parsedGuid = [guid]::Empty
if (-not [guid]::TryParse($SubscriptionId, [ref] $parsedGuid)) {
    throw 'Azure Subscription ID must be a GUID.'
}
$parsedGuid = [guid]::Empty
if (-not [guid]::TryParse($TenantId, [ref] $parsedGuid)) {
    throw 'Entra Tenant ID must be a GUID.'
}
$ResourceGroupName = Read-AutopilotUpdateValue `
    -CurrentValue $(if ($discoveredFunctionApp) {
        $discoveredFunctionApp.ResourceGroupName
    } elseif ($PSBoundParameters.ContainsKey('ResourceGroupName')) {
        $ResourceGroupName
    } else { $configuredResourceGroupName }) `
    -Prompt 'Azure Resource Group' `
    -DefaultValue 'rg-autopilot-import'
$defaultFunctionName = "func-autopilot-$($TenantId.Replace('-', '').Substring(0, 8))"
$FunctionAppName = Read-AutopilotUpdateValue `
    -CurrentValue $(if ($discoveredFunctionApp) {
        $discoveredFunctionApp.FunctionAppName
    } elseif ($PSBoundParameters.ContainsKey('FunctionAppName')) {
        $FunctionAppName
    } else { $configuredFunctionAppName }) `
    -Prompt 'Azure Function App name' `
    -DefaultValue $defaultFunctionName

if ($resolvedConfigPath) {
    $resolvedClientToolsPath = Get-AutopilotClientToolsPath `
        -SettingsPath $resolvedConfigPath `
        -OverridePath $ClientToolsPath
}
else {
    $documentsPath = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($documentsPath)) {
        $documentsPath = $HOME
    }
    $resolvedClientToolsPath = Read-AutopilotUpdateValue `
        -CurrentValue $ClientToolsPath `
        -Prompt 'Operational PowerShell scripts directory' `
        -DefaultValue (Join-Path $documentsPath 'AutopilotImport')
}

#endregion Resolve installed deployment

#region Read current deployment configuration

if (-not $currentContext -or
    [string] $currentContext.Subscription.Id -ne $SubscriptionId -or
    [string] $currentContext.Tenant.Id -ne $TenantId) {
    Connect-AzAccount `
        -Tenant $TenantId `
        -Subscription $SubscriptionId | Out-Null
}
Set-AzContext `
    -Tenant $TenantId `
    -Subscription $SubscriptionId `
    -WhatIf:$false | Out-Null

Write-Host 'Validating Azure update permissions...'
Assert-AzureUpdatePermissions `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName

$resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName"
$siteResponse = Invoke-AzRestMethod `
    -Method GET `
    -Path "${resourceId}?api-version=2023-12-01"
if ($siteResponse.StatusCode -ge 400) {
    $siteError = $siteResponse.Content | ConvertFrom-Json
    throw "Function App lookup failed: $($siteError.error.message)"
}
$site = $siteResponse.Content | ConvertFrom-Json
if (-not $site.id) {
    throw "Function App '$FunctionAppName' was not found."
}
$previousApplicationInsightsWorkspaceResourceId = `
    Get-UpdateApplicationInsightsWorkspaceResourceId `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -FunctionAppName $FunctionAppName
$integratedLogAnalyticsWorkspaceResourceId = `
    "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$FunctionAppName-la"
$appSettingsResponse = Invoke-AzRestMethod `
    -Method POST `
    -Path "$resourceId/config/appsettings/list?api-version=2023-12-01" `
    -WhatIf:$false
Assert-AutopilotAppSettingsResponse -Response $appSettingsResponse
$appSettings = $appSettingsResponse.Content | ConvertFrom-Json
$configuredApiAudience = Get-AutopilotUpdateConfigurationValue `
    -Configuration $settings `
    -Name 'apiApplicationIdUri'
$resolvedApiAudience = if ($PSBoundParameters.ContainsKey('ApiAudience')) {
    $ApiAudience
}
elseif (-not $hasFunctionUrl -and
    -not [string]::IsNullOrWhiteSpace($configuredApiAudience)) {
    $configuredApiAudience
}
else {
    [string] $appSettings.properties.API_AUDIENCE
}
if ([string]::IsNullOrWhiteSpace($resolvedApiAudience)) {
    throw "Function App '$FunctionAppName' does not define API_AUDIENCE. Use -ApiAudience."
}
$entraClientIdText = $resolvedApiAudience -replace '^api://', ''
$entraClientId = [guid]::Empty
if ($resolvedApiAudience -notmatch '^api://' -or
    -not [guid]::TryParse($entraClientIdText, [ref] $entraClientId)) {
    throw "API audience '$resolvedApiAudience' does not contain a valid Entra Client ID."
}

$configuredManagementUrl = Get-AutopilotUpdateConfigurationValue `
    -Configuration $settings `
    -Name 'managementUrl'
$defaultHostName = [string] $site.properties.defaultHostName
if ([string]::IsNullOrWhiteSpace($defaultHostName)) {
    $defaultHostName = "$FunctionAppName.azurewebsites.net"
}
$resolvedManagementUrl = if ($PSBoundParameters.ContainsKey('ManagementUrl')) {
    $ManagementUrl
}
elseif (-not $hasFunctionUrl -and
    -not [string]::IsNullOrWhiteSpace($configuredManagementUrl)) {
    $configuredManagementUrl
}
else {
    "https://$defaultHostName/api/management/tag-policy"
}

Import-Module $clientModulePath -Force
$policyResponse = Get-AutopilotTagPolicy `
    -ManagementUrl $resolvedManagementUrl `
    -ApiApplicationIdUri $resolvedApiAudience `
    -TenantId $TenantId `
    -Raw
if ($null -eq $policyResponse -or
    $null -eq $policyResponse.PSObject.Properties['policy']) {
    throw "The management endpoint '$resolvedManagementUrl' did not return a Group Tag policy. Verify the Function App, API audience, and management URL."
}
$tagAuthorizationRules = @(
    ConvertTo-UpdateTagAuthorizationRules `
        -Policy @($policyResponse.policy)
)
$restrictedManagementAdministrativeUnitName = ''

$extensionAttribute = [string] `
    $appSettings.properties.DEVICE_TAG_EXTENSION_ATTRIBUTE
if ([string]::IsNullOrWhiteSpace($extensionAttribute)) {
    $extensionAttribute = 'extensionAttribute1'
}
$managerPolicy = $appSettings.properties.MANAGER_AUTHORIZATION_POLICY |
    ConvertFrom-Json
$webClientId = if ($PSBoundParameters.ContainsKey('WebClientId') -and
    $WebClientId -ne [guid]::Empty) {
    $WebClientId
}
else {
    Get-UpdateWebClientId `
        -Properties $appSettings.properties `
        -SkipEntraAppConfiguration:$SkipEntraAppConfiguration
}
$installerPrincipalId = [guid]::Empty
if ($managerPolicy.PSObject.Properties['installerPrincipalId']) {
    [guid]::TryParse(
        [string] $managerPolicy.installerPrincipalId,
        [ref] $installerPrincipalId) | Out-Null
}
$managerPrincipalIds = @(
    @($managerPolicy.additionalPrincipalIds) |
    Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) } |
    Select-Object -Unique
)

#endregion Read current deployment configuration

#region Invoke idempotent installer

Write-Host "`nResolved update" -ForegroundColor Cyan
Write-Host "  Configuration : $(if ($resolvedConfigPath) { $resolvedConfigPath } else { '[not installed]' })"
Write-Host "  Subscription  : $SubscriptionId"
Write-Host "  Tenant        : $TenantId"
Write-Host "  Resource group: $ResourceGroupName"
Write-Host "  Function      : $FunctionAppName"
Write-Host "  Region        : $($site.location)"
Write-Host "  Client tools  : $resolvedClientToolsPath"
Write-Host "  Device Tag attribute: $extensionAttribute"
Write-Host '  Restricted management AU: preserved per policy rule'
Write-Host "  Preserved Group Tag rules: $($tagAuthorizationRules.Count)"
Write-Host "  Preserved manager principals: $($managerPrincipalIds.Count)"

$installerParameters = @{
    SubscriptionId              = $SubscriptionId
    TenantId                    = $TenantId
    ResourceGroupName           = $ResourceGroupName
    Location                    = [string] $site.location
    FunctionAppName             = $FunctionAppName
    EntraClientId               = $entraClientId.ToString()
    WebClientId                 = $webClientId
    InstallerPrincipalId        = $installerPrincipalId
    ApiAudience                 = $resolvedApiAudience
    TagAuthorizationRule        = $tagAuthorizationRules
    RestrictedManagementAdministrativeUnitName = `
        [string] $restrictedManagementAdministrativeUnitName
    DeviceTagExtensionAttribute = $extensionAttribute
    TagManagerPrincipalId       = @($managerPrincipalIds)
    ClientToolsPath             = $resolvedClientToolsPath
    InstallMissingModules       = $InstallMissingModules
    ForceGraphSignIn            = $ForceGraphSignIn
    SkipEntraAppConfiguration   = $SkipEntraAppConfiguration
    SkipGraphPermission         = $SkipGraphPermission
    SkipPublish                 = $SkipPublish
    SkipSmokeTest               = $SkipSmokeTest
}

$target = "$FunctionAppName in $ResourceGroupName"
if ($WhatIfPreference) {
    & $installerPath @installerParameters -WhatIf
    return
}
if (-not $Force -and
    -not $PSCmdlet.ShouldProcess($target, 'Update Autopilot Import deployment')) {
    return
}

$deploymentResult = & $installerPath @installerParameters -Confirm:$false
Write-UpdateLogAnalyticsWorkspaceMigrationNotice `
    -PreviousWorkspaceResourceId `
        $previousApplicationInsightsWorkspaceResourceId `
    -IntegratedWorkspaceResourceId $integratedLogAnalyticsWorkspaceResourceId
$deploymentResult

#endregion Invoke idempotent installer
}
catch {
    $isUpdatePermissionError = `
        $_.Exception.Data['AutopilotUpdatePermissionError'] -eq $true
    $isMicrosoftGraphPermissionError = `
        $_.Exception.Data['AutopilotGraphPermissionError'] -eq $true
    $errorDetails = @(
        "Timestamp: $(Get-Date -Format 'o')"
        "Script: $PSCommandPath"
        "Message: $($_.Exception.Message)"
        if ($isUpdatePermissionError) {
            "Permission details: $($_.Exception.Data['PermissionDetails'])"
        }
        if ($isMicrosoftGraphPermissionError) {
            "Permission details: $($_.Exception.Data['PermissionDetails'])"
            "Installer log: $($_.Exception.Data['InstallerLogPath'])"
        }
        'Error record:'
        ($_ | Format-List * -Force | Out-String)
        'Exception:'
        ($_.Exception | Format-List * -Force | Out-String)
        'Script stack trace:'
        $_.ScriptStackTrace
    ) -join [Environment]::NewLine
    if ($setupTranscriptActive) {
        Stop-Transcript -WhatIf:$false | Out-Null
        $setupTranscriptActive = $false
    }
    Add-Content `
        -LiteralPath $setupLogPath `
        -Value $errorDetails `
        -WhatIf:$false `
        -Encoding utf8
    if ($isUpdatePermissionError) {
        Write-Error $_.Exception.Message -ErrorAction Continue
        return
    }
    if ($isMicrosoftGraphPermissionError) {
        Write-Host
        Write-Host 'Update stopped: Microsoft Entra permission required' `
            -ForegroundColor Red
        Write-Host (
            "The Microsoft Graph account '$($_.Exception.Data['GraphAccount'])' " +
            'cannot update the Autopilot Import app registrations.'
        )
        Write-Host
        Write-Host 'Next steps:' -ForegroundColor Yellow
        Write-Host '  1. Assign or activate Application Administrator or Cloud Application Administrator for this account.'
        Write-Host '  2. Wait until the role assignment is active.'
        Write-Host '  3. Rerun this update with -ForceGraphSignIn and sign in with the authorized account.'
        Write-Host
        Write-Host 'Azure Owner or Contributor permissions are not sufficient for this Microsoft Entra change.'
        Write-Host
        Write-Host "Detailed logs:" -ForegroundColor DarkGray
        Write-Host "  Installer: $($_.Exception.Data['InstallerLogPath'])" `
            -ForegroundColor DarkGray
        Write-Host "  Update:    $setupLogPath" -ForegroundColor DarkGray
        return
    }
    Write-Error "Update failed. Detailed error information was written to '$setupLogPath'." `
        -ErrorAction Continue
    throw
}
finally {
    if ($setupTranscriptActive) {
        Stop-Transcript -WhatIf:$false | Out-Null
        $setupTranscriptActive = $false
    }
}