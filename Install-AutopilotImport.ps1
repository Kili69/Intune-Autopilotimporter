#Requires -Version 7.2
# Project-Version: 1.0.20260828.1
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
Deploys the Autopilot import Azure Function and publishes its code.

.DESCRIPTION
Prompts for missing deployment values, selects the Azure subscription, creates
or updates the resource group and Entra application, deploys infra/main.bicep,
grants the managed identity its Microsoft Graph application permission,
publishes the Function package, and verifies that Easy Auth rejects anonymous
requests.

The installer also installs AutopilotImport.Client with client.settings.json.
The Function and management URLs, API Application ID URI, tenant, subscription,
resource group, and Function App name are then available as command defaults.

.PARAMETER SubscriptionId
Azure subscription GUID that will contain the Function resources. The current
Az context is offered as the interactive default.

.PARAMETER TenantId
Microsoft Entra tenant GUID that owns the API app registration and groups.

.PARAMETER ResourceGroupName
Name of the Azure resource group to create or update.

.PARAMETER ResourceGroupTags
Optional tags to merge into the Azure resource group. Existing tags with other
names are preserved. Supply a PowerShell hashtable such as
@{ Environment = 'Production'; Owner = 'Endpoint Team' }.

.PARAMETER Location
Azure region for the resource group and Function resources, such as westus2.

.PARAMETER FunctionAppName
Globally unique Azure Function App name. It must contain 2-60 letters, digits,
or hyphens and must start and end with a letter or digit. When omitted, the
installer proposes a name derived from the Tenant ID.

.PARAMETER EntraClientId
Optional Application (client) ID of an existing Entra API app registration.
When omitted, the installer searches by EntraApplicationName and creates the
application if it does not exist.

.PARAMETER EntraApplicationName
Display name used to find or create the Entra API app registration. The default
is Autopilot Import API.

.PARAMETER InstallerPrincipalId
Entra object ID of the user or group that remains a permanent Group Tag
manager. This parameter is required with SkipEntraAppConfiguration so that
non-interactive deployments do not need a delegated Microsoft Graph login.

.PARAMETER ApiAudience
Optional token audience accepted by Easy Auth. The default is api:// followed
by the Entra application Client ID.

.PARAMETER TagAuthorizationRule
One or more group-to-tag rules in the form
<Entra-group-object-ID>=<tag1>,<tag2>. Missing rules are requested interactively.

.PARAMETER RestrictedManagementAdministrativeUnitName
Optional display name of a restricted management administrative unit. Imported
devices are added to this unit after Intune creates their Entra device. Leave
empty to keep the current behavior.

.PARAMETER DeviceTagExtensionAttribute
Entra device extension attribute that receives the authorized Group Tag.
Supported values are extensionAttribute1 through extensionAttribute15. The
interactive default is extensionAttribute1.

.PARAMETER TagManagerPrincipalId
Optional Entra user or group object IDs that may manage Group Tags in addition
to the installing user and Intune Role Administrators.

.PARAMETER ClientToolsPath
Destination directory for the versioned client module, compatibility scripts,
local module dependency, and client.settings.json. When omitted, the installer
asks for a path and suggests the current user's PowerShell script directory.

.PARAMETER InstallMissingModules
Installs missing Az modules, Microsoft.Graph.Authentication, and the Bicep CLI
for the current user where applicable.

.PARAMETER ForceGraphSignIn
Signs out the cached Microsoft Graph account before Entra configuration and
uses device-code authentication to select an account explicitly. The Azure
PowerShell account is not changed.

.PARAMETER SkipEntraAppConfiguration
Skips app registration and API scope management.
EntraClientId must be supplied when this switch is used.

.PARAMETER SkipGraphPermission
Skips assignment of DeviceManagementServiceConfig.ReadWrite.All to the
Function managed identity.
.PARAMETER SkipPublish
Deploys infrastructure without publishing the Function source package.

.PARAMETER SkipSmokeTest
Skips the final anonymous HTTP request that expects an HTTP 401 response.

.EXAMPLE
pwsh .\Install-AutopilotImport.ps1 -InstallMissingModules

Runs an interactive installation and installs missing local prerequisites.

.EXAMPLE
pwsh .\Install-AutopilotImport.ps1 `
    -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -TenantId '11111111-1111-1111-1111-111111111111' `
    -ResourceGroupName 'rg-autopilot-import' `
    -ResourceGroupTags @{ Environment = 'Production'; Owner = 'Endpoint Team' } `
    -Location 'westus2' `
    -FunctionAppName 'func-autopilot-contoso' `
    -TagAuthorizationRule `
        '22222222-2222-2222-2222-222222222222=Standard,Kiosk' `
    -InstallMissingModules `
    -Confirm:$false

Runs a non-interactive deployment with one authorized Entra group.

.EXAMPLE
pwsh .\Install-AutopilotImport.ps1 `
    -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -TenantId '11111111-1111-1111-1111-111111111111' `
    -ResourceGroupName 'rg-autopilot-import' `
    -Location 'westus2' `
    -FunctionAppName 'func-autopilot-contoso' `
    -TagAuthorizationRule `
        '22222222-2222-2222-2222-222222222222=Standard' `
    -WhatIf

Displays the requested configuration without changing Azure or Entra.

.OUTPUTS
PSCustomObject containing the subscription, tenant, resource group, Function
URL, API audience, managed identity object ID, authorization policy, and local
and installed client settings paths and client tools directory.

.NOTES
The installing administrator requires Azure resource deployment permissions
and delegated Graph permissions for application management. End
users receive no Intune or Microsoft Graph permissions from this installer.
#>

#region Parameters

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $SubscriptionId,

    [string] $TenantId,

    [string] $ResourceGroupName,

    [hashtable] $ResourceGroupTags,

    [string] $Location,

    [string] $FunctionAppName,

    [string] $EntraClientId,

    [string] $EntraApplicationName = 'Autopilot Import API',

    [guid] $InstallerPrincipalId,

    [string] $ApiAudience,

    [string[]] $TagAuthorizationRule,

    [string] $RestrictedManagementAdministrativeUnitName,

    [ValidatePattern('^extensionAttribute(?:[1-9]|1[0-5])$')]
    [string] $DeviceTagExtensionAttribute,

    [guid[]] $TagManagerPrincipalId,

    [string] $ClientToolsPath,

    [switch] $InstallMissingModules,

    [switch] $ForceGraphSignIn,

    [switch] $SkipEntraAppConfiguration,

    [switch] $SkipGraphPermission,

    [switch] $SkipPublish,

    [switch] $SkipSmokeTest
)

#endregion Parameters

#region Initialization

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$setupLogPath = Join-Path ([IO.Path]::GetTempPath()) `
    "Intune-Autopilotimport-install-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N')).log"
Start-Transcript `
    -LiteralPath $setupLogPath `
    -IncludeInvocationHeader `
    -WhatIf:$false `
    -Force | Out-Null
$setupTranscriptActive = $true
Write-Host "Setup log: $setupLogPath"

try {
$projectRoot = $PSScriptRoot
$templatePath = Join-Path $projectRoot 'infra\main.bicep'
$grantScriptPath = Join-Path $projectRoot 'scripts\Grant-ManagedIdentityGraphPermission.ps1'
$ensureEntraAppScriptPath = Join-Path $projectRoot 'scripts\Ensure-EntraApiApplication.ps1'
$autopilotImportModulePath = Join-Path $projectRoot 'src\AutopilotImport\AutopilotImport.psm1'
Import-Module $autopilotImportModulePath -Force

#endregion Initialization

#region Helper functions

function Read-DeploymentValue {
    <#
    .SYNOPSIS
    Resolves a required deployment value from a parameter or interactive input.

    .DESCRIPTION
    Returns CurrentValue without prompting when it contains a non-whitespace
    value. Otherwise, prompts the user and displays DefaultValue as the
    suggested value when one is available. Pressing Enter accepts DefaultValue.
    The function throws a terminating error when no parameter value, entered
    value, or default value is available.

    .PARAMETER CurrentValue
    Optional value already supplied through an installer parameter.

    .PARAMETER Prompt
    Label displayed by Read-Host when interactive input is required.

    .PARAMETER DefaultValue
    Optional suggested value used when the user submits an empty response.

    .OUTPUTS
    System.String. The resolved value with leading and trailing whitespace
    removed.
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

function Test-FunctionAppName {
    <#
    .SYNOPSIS
    Tests whether a name satisfies the Azure Function App naming rules.

    .DESCRIPTION
    Accepts the ASCII subset used by this installer for Microsoft.Web/sites:
    2-60 letters, digits, or hyphens, starting and ending with a letter or
    digit. Global name availability is evaluated by Azure during deployment.

    .PARAMETER Name
    Function App name to validate.

    .OUTPUTS
    System.Boolean. True when Name satisfies the supported naming rules.

    .LINK
    https://learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules#microsoftweb
    #>
    param(
        [AllowEmptyString()]
        [string] $Name
    )

    return -not [string]::IsNullOrWhiteSpace($Name) -and
        $Name.Length -ge 2 -and
        $Name.Length -le 60 -and
        $Name -match '^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$'
}

function Read-FunctionAppName {
    <#
    .SYNOPSIS
    Resolves and validates the Function App name used by the deployment.

    .DESCRIPTION
    Returns CurrentValue when it was supplied and valid. Otherwise, prompts
    interactively and offers DefaultValue as the generated suggestion. Invalid
    parameter values cause a terminating error; invalid interactive entries
    display a warning and are requested again.

    .PARAMETER CurrentValue
    Optional name supplied through the FunctionAppName installer parameter.

    .PARAMETER DefaultValue
    Generated name shown as the default in the interactive prompt.

    .OUTPUTS
    System.String. The trimmed, validated Function App name.
    #>
    param(
        [string] $CurrentValue,
        [Parameter(Mandatory)]
        [string] $DefaultValue
    )

    $parameterWasSupplied = -not [string]::IsNullOrWhiteSpace($CurrentValue)
    while ($true) {
        $candidate = Read-DeploymentValue `
            -CurrentValue $CurrentValue `
            -Prompt 'Globally unique Function App name' `
            -DefaultValue $DefaultValue

        if (Test-FunctionAppName -Name $candidate) {
            return $candidate
        }

        $message = 'Function App name must contain 2-60 letters, digits, or hyphens and must start and end with a letter or digit.'
        if ($parameterWasSupplied) {
            throw $message
        }

        Write-Warning $message
        $CurrentValue = $null
    }
}

function ConvertTo-TagAuthorizationPolicy {
    <#
    .SYNOPSIS
    Resolves and validates the group-to-tag authorization policy.

    .DESCRIPTION
    Uses the supplied Rules when at least one non-whitespace rule is present.
    Otherwise, interactively requests Entra group object IDs and their allowed
    Device Tags until the user finishes the input. At least one rule is
    required. Parsing, consolidation, and validation are delegated to the
    AutopilotImport module.

    .PARAMETER Rules
    Optional authorization rules in the format
    <Entra-group-object-ID>=<tag1>,<tag2>. Multiple entries for the same group
    are consolidated by the AutopilotImport module.

    .OUTPUTS
    System.Object[]. Authorization policy entries containing a groupId and the
    corresponding collection of allowed tags.
    #>
    param(
        [string[]] $Rules,

        [string] $RestrictedManagementAdministrativeUnitName
    )

    $enteredRules = @($Rules | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($enteredRules.Count -eq 0) {
        Write-Host "`nConfigure which Entra groups may assign which Device Tags." -ForegroundColor Cyan
        Write-Host 'Use the Entra group Object ID, not its display name.'

        while ($true) {
            $groupId = Read-Host 'Entra group Object ID (leave empty when finished)'
            if ([string]::IsNullOrWhiteSpace($groupId)) {
                if ($enteredRules.Count -eq 0) {
                    Write-Warning 'At least one group and tag rule is required.'
                    continue
                }
                break
            }

            $tags = Read-Host 'Allowed Device Tags for this group (comma-separated)'
            $enteredRules += "$groupId=$tags"
        }
    }

    return ,(AutopilotImport\ConvertTo-TagAuthorizationPolicy `
        -Rules $enteredRules `
        -RestrictedManagementAdministrativeUnitName `
            $RestrictedManagementAdministrativeUnitName)
}

function ConvertTo-AdditionalManagerPrincipalIds {
    <#
    .SYNOPSIS
    Normalizes the optional additional tag manager principal IDs.

    .DESCRIPTION
    Converts the supplied Entra user or group object IDs to their canonical
    string representation, removes duplicate entries, and excludes the
    installing user because that user is added separately to the manager
    authorization policy. A missing principal ID collection produces an empty
    result.

    .PARAMETER PrincipalIds
    Optional Entra user or group object IDs to add as tag policy managers.

    .PARAMETER InstallingUserObjectId
    Object ID of the installing user, which is excluded from the result.

    .OUTPUTS
    System.String[]. Unique additional manager principal IDs.
    #>
    param(
        [AllowNull()]
        [guid[]] $PrincipalIds,

        [guid] $InstallingUserObjectId
    )

    return @($PrincipalIds |
        Where-Object { $null -ne $_ } |
        ForEach-Object { $_.ToString() } |
        Where-Object { $_ -ne $InstallingUserObjectId.ToString() } |
        Select-Object -Unique)
}

function Install-AutopilotClientTools {
    <#
    .SYNOPSIS
    Installs the client module, compatibility scripts, and local dependencies.

    .PARAMETER DestinationPath
    Root directory for the portable client package.

    .PARAMETER ProjectRoot
    Root directory of the Autopilot importer source project.

    .PARAMETER ClientSettingsJson
    Installation-derived client configuration written beside the client module.

    .PARAMETER PackageDestinationPath
    Directory in which the portable PowerShell module ZIP is created.

    .OUTPUTS
    System.String. Full path to the installed client.settings.json file.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $DestinationPath,

        [Parameter(Mandatory)]
        [string] $ProjectRoot,

        [Parameter(Mandatory)]
        [string] $ClientSettingsJson,

        [Parameter(Mandatory)]
        [string] $PackageDestinationPath
    )

    $destinationRoot = [IO.Path]::GetFullPath($DestinationPath)
    $scriptDestination = Join-Path $destinationRoot 'scripts'
    $clientModuleSource = Join-Path $ProjectRoot 'src\AutopilotImport.Client'
    $clientModuleManifest = Import-PowerShellDataFile `
        -LiteralPath (Join-Path $clientModuleSource 'AutopilotImport.Client.psd1')
    $moduleDestination = Join-Path $destinationRoot `
        "Modules\AutopilotImport.Client\$($clientModuleManifest.ModuleVersion)"
    [void] (New-Item -Path $scriptDestination -ItemType Directory -Force)
    [void] (New-Item -Path $moduleDestination -ItemType Directory -Force)

    foreach ($scriptName in @(
            'Import-AutopilotDevice.ps1',
            'Set-TagAuthorizationPolicy.ps1',
            'Set-TagPolicyManagers.ps1'
        )) {
        Copy-Item `
            -LiteralPath (Join-Path $ProjectRoot "scripts\$scriptName") `
            -Destination (Join-Path $scriptDestination $scriptName) `
            -Force
    }
    foreach ($moduleFileName in @(
            'AutopilotImport.Client.psm1',
            'AutopilotImport.Client.psd1'
        )) {
        Copy-Item `
            -LiteralPath (Join-Path $clientModuleSource $moduleFileName) `
            -Destination (Join-Path $moduleDestination $moduleFileName) `
            -Force
    }
    Copy-Item `
        -LiteralPath (Join-Path $ProjectRoot 'src\AutopilotImport\AutopilotImport.psm1') `
        -Destination (Join-Path $moduleDestination 'AutopilotImport.psm1') `
        -Force

    $settingsPath = Join-Path $moduleDestination 'client.settings.json'
    $settingsTemporaryPath = "$settingsPath.tmp"
    Set-Content `
        -LiteralPath $settingsTemporaryPath `
        -Value $ClientSettingsJson `
        -Encoding utf8NoBOM
    Move-Item `
        -LiteralPath $settingsTemporaryPath `
        -Destination $settingsPath `
        -Force

    $clientModuleRoot = Split-Path $moduleDestination -Parent
    $normalizedModuleDestination = [IO.Path]::GetFullPath($moduleDestination).TrimEnd('\')
    Get-ChildItem -LiteralPath $clientModuleRoot -Directory |
        Where-Object {
            [IO.Path]::GetFullPath($_.FullName).TrimEnd('\') -ne `
                $normalizedModuleDestination
        } |
        Remove-Item -Recurse -Force

    $packageDestinationRoot = [IO.Path]::GetFullPath($PackageDestinationPath)
    [void] (New-Item `
        -Path $packageDestinationRoot `
        -ItemType Directory `
        -Force)
    $modulePackagePath = Join-Path $packageDestinationRoot `
        "Intune-Autopilotimport-psmodule-$($clientModuleManifest.ModuleVersion).zip"
    Compress-Archive `
        -LiteralPath $clientModuleRoot `
        -DestinationPath $modulePackagePath `
        -CompressionLevel Optimal `
        -Force

    return $settingsPath
}

function Import-DeploymentModule {
    <#
    .SYNOPSIS
    Ensures that a required PowerShell module is available and imports it.

    .DESCRIPTION
    Checks whether Name is installed locally. When the module is missing and
    the installer was started with InstallMissingModules, installs it from the
    PowerShell Gallery for the current user. Otherwise, throws a terminating
    error that instructs the user to enable dependency installation. The
    resolved module is imported with terminating error handling.

    .PARAMETER Name
    Name of the PowerShell module to locate, optionally install, and import.

    .OUTPUTS
    None.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        if (-not $InstallMissingModules) {
            throw "PowerShell module '$Name' is missing. Run again with -InstallMissingModules."
        }

        Write-Host "Installing PowerShell module '$Name'..."
        Install-Module -Name $Name -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
    }

    Import-Module $Name -ErrorAction Stop
}

function Initialize-BicepCli {
    <#
    .SYNOPSIS
    Ensures that the Bicep CLI is available to the installer.

    .DESCRIPTION
    Returns immediately when bicep can already be resolved as a command.
    Otherwise, searches the standard per-user and system-wide installation
    paths. When Bicep is missing and the installer was started with
    InstallMissingModules, installs the Microsoft.Bicep winget package and
    checks the known paths again. The resolved installation directory is added
    to PATH for the current process. A terminating error is thrown when Bicep
    or winget is unavailable, or when the winget installation fails.

    .OUTPUTS
    None.

    .LINK
    https://learn.microsoft.com/azure/azure-resource-manager/bicep/install
    #>
    $bicepCommand = Get-Command bicep -ErrorAction SilentlyContinue
    if ($bicepCommand) {
        return
    }

    $knownPaths = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Bicep CLI\bicep.exe'),
        (Join-Path $env:ProgramFiles 'Bicep CLI\bicep.exe')
    )
    $bicepPath = $knownPaths | Where-Object { Test-Path $_ -PathType Leaf } |
        Select-Object -First 1

    if (-not $bicepPath -and $InstallMissingModules) {
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if (-not $winget) {
            throw 'Bicep is missing and winget is not available. Install Bicep from https://aka.ms/bicep-install.'
        }

        Write-Host 'Installing Bicep CLI...'
        & $winget.Source install `
            --id Microsoft.Bicep `
            --exact `
            --source winget `
            --accept-package-agreements `
            --accept-source-agreements `
            --silent
        if ($LASTEXITCODE -ne 0) {
            throw "Bicep installation failed with exit code $LASTEXITCODE."
        }

        $bicepPath = $knownPaths | Where-Object { Test-Path $_ -PathType Leaf } |
            Select-Object -First 1
    }

    if (-not $bicepPath) {
        throw 'Bicep is missing. Run again with -InstallMissingModules or install it from https://aka.ms/bicep-install.'
    }

    $env:Path = "$(Split-Path $bicepPath -Parent);$env:Path"
}

function Format-AzureDeploymentError {
    <#
    .SYNOPSIS
    Formats nested Azure deployment errors without losing policy details.

    .DESCRIPTION
    Converts an Azure PowerShell error record or validation result to JSON.
    This preserves nested Details and InnerError values such as the rejected
    resource, policy assignment, and policy definition.

    .PARAMETER ErrorObject
    Azure deployment error record, exception, or validation result.

    .OUTPUTS
    System.String. A readable representation of the complete Azure error.
    #>
    param(
        [Parameter(Mandatory)]
        [object] $ErrorObject
    )

    $candidate = if ($ErrorObject -is [Management.Automation.ErrorRecord]) {
        $ErrorObject.Exception
    }
    else {
        $ErrorObject
    }

    if ($candidate.PSObject.Properties['Body'] -and $candidate.Body) {
        $candidate = $candidate.Body
    }

    try {
        return $candidate | ConvertTo-Json -Depth 20
    }
    catch {
        return $ErrorObject | Format-List * -Force | Out-String
    }
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

function Assert-AzureDeploymentPermissions {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [switch] $ResourceGroupExists
    )

    $scope = if ($ResourceGroupExists) {
        "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
    }
    else {
        "/subscriptions/$SubscriptionId"
    }
    $requiredActions = @(
        'Microsoft.Resources/deployments/write'
        'Microsoft.Storage/storageAccounts/write'
        'Microsoft.Storage/storageAccounts/blobServices/write'
        'Microsoft.Storage/storageAccounts/blobServices/containers/write'
        'Microsoft.Insights/components/write'
        'Microsoft.Web/serverfarms/write'
        'Microsoft.Web/sites/write'
        'Microsoft.Web/sites/config/write'
        'Microsoft.Authorization/roleAssignments/write'
    )
    if (-not $ResourceGroupExists) {
        $requiredActions += 'Microsoft.Resources/subscriptions/resourceGroups/write'
    }

    $permissionsResponse = try {
        Invoke-AzRestMethod `
            -Method GET `
            -Path "$scope/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
    }
    catch {
        Write-Verbose "Azure permission lookup failed: $($_ | Format-List * -Force | Out-String)"
        throw 'Azure deployment permissions could not be verified. Ensure the account has Owner, or Contributor together with Role Based Access Control Administrator, at the target scope.'
    }
    if ($permissionsResponse.StatusCode -ge 400) {
        Write-Verbose "Azure permission lookup failed: $($permissionsResponse.Content)"
        throw 'Azure deployment permissions could not be verified. Ensure the account has Owner, or Contributor together with Role Based Access Control Administrator, at the target scope.'
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
        Write-Verbose "Missing Azure deployment actions at '$scope': $($missingActions -join ', ')"
        throw 'Azure deployment permissions are insufficient. Assign Owner, or Contributor together with Role Based Access Control Administrator, at the target resource group or subscription scope.'
    }
}

function Register-AzureResourceProvider {
    <#
    .SYNOPSIS
    Ensures that an Azure resource provider is registered.

    .DESCRIPTION
    Returns immediately when ProviderNamespace is registered in the current
    subscription. Otherwise, starts registration and waits up to five minutes
    for Azure to report the Registered state.

    .PARAMETER ProviderNamespace
    Azure resource provider namespace, such as Microsoft.OperationalInsights.

    .OUTPUTS
    None.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $ProviderNamespace
    )

    $provider = Get-AzResourceProvider `
        -ProviderNamespace $ProviderNamespace `
        -ErrorAction Stop
    if ($provider.RegistrationState -eq 'Registered') {
        return
    }

    Write-Host "Registering Azure resource provider '$ProviderNamespace'..."
    $provider = Register-AzResourceProvider `
        -ProviderNamespace $ProviderNamespace `
        -ErrorAction Stop
    if ($provider.RegistrationState -eq 'Registered') {
        return
    }

    $registrationDeadline = [DateTime]::UtcNow.AddMinutes(5)
    do {
        Start-Sleep -Seconds 5
        $provider = Get-AzResourceProvider `
            -ProviderNamespace $ProviderNamespace `
            -ErrorAction Stop
    } while (
        $provider.RegistrationState -ne 'Registered' -and
        [DateTime]::UtcNow -lt $registrationDeadline
    )

    if ($provider.RegistrationState -ne 'Registered') {
        throw "Azure resource provider '$ProviderNamespace' did not reach the Registered state within five minutes."
    }
}

function Set-ResourceGroupTags {
    <#
    .SYNOPSIS
    Merges tags into an Azure resource group.

    .DESCRIPTION
    Applies the requested tags with Azure's Merge operation so tags not
    supplied by this installer remain unchanged. An empty tag collection is a
    no-op.

    .PARAMETER ResourceId
    Azure resource ID of the resource group.

    .PARAMETER Tags
    Tag names and values to merge into the resource group.

    .OUTPUTS
    None.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $ResourceId,

        [hashtable] $Tags
    )

    if (-not $Tags -or $Tags.Count -eq 0) {
        return
    }

    $normalizedTags = @{}
    foreach ($tagName in $Tags.Keys) {
        $normalizedTagName = [string] $tagName
        if ([string]::IsNullOrWhiteSpace($normalizedTagName)) {
            throw 'Resource group tag names must not be empty.'
        }

        $normalizedTags[$normalizedTagName] = [string] $Tags[$tagName]
    }

    Update-AzTag `
        -ResourceId $ResourceId `
        -Tag $normalizedTags `
        -Operation Merge `
        -ErrorAction Stop | Out-Null
}

function Initialize-AzureResourceGroup {
    <#
    .SYNOPSIS
    Creates an Azure resource group or updates its tags.

    .DESCRIPTION
    Supplies tags during creation so Azure Policies that require resource group
    tags can evaluate the initial request successfully. For an existing group,
    requested tags are merged without removing unrelated tags.

    .PARAMETER Name
    Name of the Azure resource group.

    .PARAMETER Location
    Azure region for a new resource group.

    .PARAMETER Tags
    Optional resource group tags.

    .OUTPUTS
    The Azure resource group.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [string] $Location,

        [hashtable] $Tags
    )

    $resourceGroup = Get-AzResourceGroup `
        -Name $Name `
        -ErrorAction SilentlyContinue
    if ($resourceGroup) {
        Set-ResourceGroupTags `
            -ResourceId $resourceGroup.ResourceId `
            -Tags $Tags
        return $resourceGroup
    }

    $newResourceGroupParameters = @{
        Name        = $Name
        Location    = $Location
        ErrorAction = 'Stop'
    }
    if ($Tags -and $Tags.Count -gt 0) {
        $newResourceGroupParameters.Tag = $Tags
    }

    return New-AzResourceGroup @newResourceGroupParameters
}

#endregion Helper functions

#region Prerequisites

if (-not (Test-Path $templatePath -PathType Leaf)) {
    throw "Bicep template not found: $templatePath"
}

Import-DeploymentModule -Name 'Az.Accounts'
Import-DeploymentModule -Name 'Az.Resources'
Import-DeploymentModule -Name 'Az.Storage'
Import-DeploymentModule -Name 'Az.Websites'
Initialize-BicepCli

#endregion Prerequisites

#region Deployment input and validation

$currentContext = Get-AzContext -ErrorAction SilentlyContinue
$defaultSubscriptionId = if ($currentContext) { $currentContext.Subscription.Id } else { $null }
$defaultTenantId = if ($currentContext) { $currentContext.Tenant.Id } else { $null }
$SubscriptionId = Read-DeploymentValue `
    -CurrentValue $SubscriptionId `
    -Prompt 'Azure Subscription ID' `
    -DefaultValue $defaultSubscriptionId
$TenantId = Read-DeploymentValue `
    -CurrentValue $TenantId `
    -Prompt 'Entra Tenant ID' `
    -DefaultValue $defaultTenantId
$parsedGuid = [guid]::Empty
if (-not [guid]::TryParse($SubscriptionId, [ref] $parsedGuid)) {
    throw 'Azure Subscription ID must be a GUID.'
}
$parsedGuid = [guid]::Empty
if (-not [guid]::TryParse($TenantId, [ref] $parsedGuid)) {
    throw 'Entra Tenant ID must be a GUID.'
}
$ResourceGroupName = Read-DeploymentValue `
    -CurrentValue $ResourceGroupName `
    -Prompt 'Azure Resource Group' `
    -DefaultValue 'rg-autopilot-import'
$Location = Read-DeploymentValue `
    -CurrentValue $Location `
    -Prompt 'Azure Region' `
    -DefaultValue 'westeurope'

$defaultFunctionName = "func-autopilot-$($TenantId.Replace('-', '').Substring(0, 8))"
$FunctionAppName = Read-FunctionAppName `
    -CurrentValue $FunctionAppName `
    -DefaultValue $defaultFunctionName
$documentsPath = [Environment]::GetFolderPath('MyDocuments')
if ([string]::IsNullOrWhiteSpace($documentsPath)) {
    $documentsPath = $HOME
}
$defaultClientToolsPath = Join-Path $documentsPath 'PowerShell\Scripts\AutopilotImport'
$ClientToolsPath = Read-DeploymentValue `
    -CurrentValue $ClientToolsPath `
    -Prompt 'Operational PowerShell scripts directory' `
    -DefaultValue $defaultClientToolsPath
$DeviceTagExtensionAttribute = Read-DeploymentValue `
    -CurrentValue $DeviceTagExtensionAttribute `
    -Prompt 'Entra Device Tag extension attribute' `
    -DefaultValue 'extensionAttribute1'
if ($DeviceTagExtensionAttribute -notmatch '^extensionAttribute(?:[1-9]|1[0-5])$') {
    throw 'DeviceTagExtensionAttribute must be extensionAttribute1 through extensionAttribute15.'
}
if (-not $PSBoundParameters.ContainsKey(
        'RestrictedManagementAdministrativeUnitName')) {
    $RestrictedManagementAdministrativeUnitName = Read-Host `
        'Restricted management administrative unit display name (optional)'
}
$RestrictedManagementAdministrativeUnitName = if (
    [string]::IsNullOrWhiteSpace(
        $RestrictedManagementAdministrativeUnitName)) {
    ''
}
else {
    $RestrictedManagementAdministrativeUnitName.Trim()
}
$tagAuthorizationPolicy = ConvertTo-TagAuthorizationPolicy `
    -Rules $TagAuthorizationRule `
    -RestrictedManagementAdministrativeUnitName `
        $RestrictedManagementAdministrativeUnitName
$tagAuthorizationPolicyJson = $tagAuthorizationPolicy | ConvertTo-Json -Depth 4 -Compress

$parsedGuid = [guid]::Empty
if ($EntraClientId -and -not [guid]::TryParse($EntraClientId, [ref] $parsedGuid)) {
    throw 'Entra API application Client ID must be a GUID.'
}

#endregion Deployment input and validation

#region Azure context and confirmation

$contextMatches = $currentContext -and
    $currentContext.Subscription.Id -eq $SubscriptionId -and
    $currentContext.Tenant.Id -eq $TenantId
if (-not $contextMatches) {
    Connect-AzAccount -Tenant $TenantId -Subscription $SubscriptionId | Out-Null
}

try {
    Set-AzContext `
        -Tenant $TenantId `
        -Subscription $SubscriptionId `
        -WhatIf:$false | Out-Null
    $subscription = Get-AzSubscription `
        -SubscriptionId $SubscriptionId `
        -TenantId $TenantId
}
catch {
    Write-Host 'The stored Azure session is unavailable or expired. Sign in again.'
    Connect-AzAccount -Tenant $TenantId -Subscription $SubscriptionId | Out-Null
    Set-AzContext `
        -Tenant $TenantId `
        -Subscription $SubscriptionId `
        -WhatIf:$false | Out-Null
    $subscription = Get-AzSubscription `
        -SubscriptionId $SubscriptionId `
        -TenantId $TenantId
}

Write-Host 'Validating Azure deployment permissions...'
$existingResourceGroup = Get-AzResourceGroup `
    -Name $ResourceGroupName `
    -ErrorAction SilentlyContinue
Assert-AzureDeploymentPermissions `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -ResourceGroupExists:($null -ne $existingResourceGroup)

Write-Host "`nRequested installation" -ForegroundColor Cyan
Write-Host "  Subscription : $($subscription.Name) ($SubscriptionId)"
Write-Host "  Tenant       : $TenantId"
Write-Host "  Resource group: $ResourceGroupName"
if ($ResourceGroupTags -and $ResourceGroupTags.Count -gt 0) {
    Write-Host "  Resource group tags: $(
        @($ResourceGroupTags.Keys | Sort-Object | ForEach-Object {
            "$_=$($ResourceGroupTags[$_])"
        }) -join ', '
    )"
}
Write-Host "  Region       : $Location"
Write-Host "  Function     : $FunctionAppName"
Write-Host "  Entra app    : $EntraApplicationName"
Write-Host "  Client tools : $ClientToolsPath"
Write-Host "  Device Tag attribute: $DeviceTagExtensionAttribute"
Write-Host "  Restricted management AU: $RestrictedManagementAdministrativeUnitName"
Write-Host '  Group to Device Tag rules:'
foreach ($rule in $tagAuthorizationPolicy) {
    Write-Host "    $($rule.groupId) -> $($rule.tags -join ', ')"
}
Write-Host

if (-not $PSCmdlet.ShouldProcess(
        "$ResourceGroupName and Entra application '$EntraApplicationName'",
        'Configure Entra and deploy Autopilot import Azure Function'
    )) {
    return
}

Register-AzureResourceProvider -ProviderNamespace 'Microsoft.OperationalInsights'

#endregion Azure context and confirmation

#region Resource group and Entra application

$resourceGroup = Initialize-AzureResourceGroup `
    -Name $ResourceGroupName `
    -Location $Location `
    -Tags $ResourceGroupTags

if (-not $SkipEntraAppConfiguration) {
    Import-DeploymentModule -Name 'Microsoft.Graph.Authentication'
    $entraApplication = & $ensureEntraAppScriptPath `
        -TenantId $TenantId `
        -ClientId $EntraClientId `
        -DisplayName $EntraApplicationName `
        -ForceGraphSignIn:$ForceGraphSignIn `
        -Confirm:$false
    $EntraClientId = $entraApplication.ClientId
    $ApiAudience = $entraApplication.ApplicationIdUri
    $installingUserObjectId = [guid] $entraApplication.InstallingUserObjectId
    Write-Host "Microsoft Graph account: $($entraApplication.InstallingUserPrincipalName)"
}
elseif ([string]::IsNullOrWhiteSpace($EntraClientId)) {
    throw 'EntraClientId is required when SkipEntraAppConfiguration is used.'
}
elseif ($InstallerPrincipalId -eq [guid]::Empty) {
    throw 'InstallerPrincipalId is required when SkipEntraAppConfiguration is used.'
}
else {
    Import-DeploymentModule -Name 'Microsoft.Graph.Authentication'
    $graphConnectParameters = @{
        TenantId  = $TenantId
        Scopes    = @('User.Read')
        NoWelcome = $true
    }
    if ($ForceGraphSignIn) {
        Disconnect-MgGraph -SignOutFromBroker -ErrorAction SilentlyContinue | Out-Null
        $graphConnectParameters.UseDeviceCode = $true
        Write-Host "Sign in with the Entra administrator for tenant '$TenantId'."
    }
    Connect-MgGraph @graphConnectParameters
    $installingUser = Invoke-MgGraphRequest `
        -Method GET `
        -Uri 'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName'
    $installingUserObjectId = [guid] $installingUser.id
    Write-Host "Microsoft Graph account: $($installingUser.userPrincipalName)"
}

if ([string]::IsNullOrWhiteSpace($ApiAudience)) {
    $ApiAudience = "api://$EntraClientId"
}

#endregion Resource group and Entra application

#region Infrastructure deployment

Write-Host "`nDeployment configuration" -ForegroundColor Cyan
Write-Host "  Subscription : $($subscription.Name) ($SubscriptionId)"
Write-Host "  Tenant       : $TenantId"
Write-Host "  Resource group: $ResourceGroupName"
Write-Host "  Region       : $Location"
Write-Host "  Function     : $FunctionAppName"
Write-Host "  API audience : $ApiAudience"
Write-Host "  Device Tag attribute: $DeviceTagExtensionAttribute"
Write-Host "  Restricted management AU: $RestrictedManagementAdministrativeUnitName"
Write-Host "  Allowed Tags : $(@($tagAuthorizationPolicy.tags) -join ', ')"
$additionalManagerPrincipalIds = ConvertTo-AdditionalManagerPrincipalIds `
    -PrincipalIds $TagManagerPrincipalId `
    -InstallingUserObjectId $installingUserObjectId
$managerAuthorizationPolicy = [ordered]@{
    installerPrincipalId          = $installingUserObjectId.ToString()
    additionalPrincipalIds        = $additionalManagerPrincipalIds
    allowIntuneRoleAdministrators = $true
}
$managerAuthorizationPolicyJson = $managerAuthorizationPolicy |
    ConvertTo-Json -Depth 4 -Compress
Write-Host "  Installing manager: $installingUserObjectId"
Write-Host "  Additional managers: $($additionalManagerPrincipalIds -join ', ')"
Write-Host '  Intune Role Administrators: allowed'

$deploymentParameters = @{
    ResourceGroupName = $ResourceGroupName
    TemplateFile      = $templatePath
    functionAppName   = $FunctionAppName
    location          = $Location
    entraClientId     = $EntraClientId
    apiAudience       = $ApiAudience
    tagAuthorizationPolicy = $tagAuthorizationPolicyJson
    managerAuthorizationPolicy = $managerAuthorizationPolicyJson
    deviceTagExtensionAttribute = $DeviceTagExtensionAttribute
    installerPrincipalId = $installingUserObjectId.ToString()
}

Write-Host 'Validating Bicep deployment...'
$validationErrors = try {
    Test-AzResourceGroupDeployment @deploymentParameters
}
catch {
    Write-Error (Format-AzureDeploymentError -ErrorObject $_)
    throw 'Bicep deployment validation failed. Review the Azure error details above.'
}
if ($validationErrors) {
    Write-Error (Format-AzureDeploymentError -ErrorObject $validationErrors)
    throw 'Bicep deployment validation failed. Review the Azure error details above.'
}

Write-Host 'Deploying Azure resources...'
$deployment = New-AzResourceGroupDeployment `
    @deploymentParameters `
    -Name "autopilot-import-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
if ($deployment.ProvisioningState -ne 'Succeeded') {
    throw "Azure deployment ended with state '$($deployment.ProvisioningState)'."
}

#endregion Infrastructure deployment

#region Client configuration

$functionUrl = [string] $deployment.Outputs.functionUrl.Value
$managementUrl = [string] $deployment.Outputs.managementUrl.Value
$managedIdentityObjectId = [guid] $deployment.Outputs.managedIdentityObjectId.Value
$storageAccountName = [string] $deployment.Outputs.storageAccountName.Value
$clientSettings = [ordered]@{
    functionUrl            = $functionUrl
    managementUrl          = $managementUrl
    apiApplicationIdUri    = $ApiAudience
    tenantId               = $TenantId
    subscriptionId         = $SubscriptionId
    resourceGroupName      = $ResourceGroupName
    functionAppName        = $FunctionAppName
} | ConvertTo-Json
$clientSettingsPath = Join-Path $projectRoot 'client.settings.json'
Set-Content `
    -LiteralPath $clientSettingsPath `
    -Value $clientSettings `
    -Encoding utf8NoBOM
$installedClientSettingsPath = Install-AutopilotClientTools `
    -DestinationPath $ClientToolsPath `
    -ProjectRoot $projectRoot `
    -ClientSettingsJson $clientSettings `
    -PackageDestinationPath $documentsPath
$installedClientModuleVersion = Split-Path $installedClientSettingsPath -Parent |
    Split-Path -Leaf
$clientModulePackagePath = Join-Path ([IO.Path]::GetFullPath($documentsPath)) `
    "Intune-Autopilotimport-psmodule-$installedClientModuleVersion.zip"
Write-Host "Installed AutopilotImport.Client, compatibility scripts, and defaults in '$ClientToolsPath'."
Write-Host "Created portable PowerShell module package '$clientModulePackagePath'."
Write-Host 'Extract the archive into a directory listed in $env:PSModulePath to use its commands through module autoloading.'

$storageAccount = Get-AzStorageAccount `
    -ResourceGroupName $ResourceGroupName `
    -Name $storageAccountName
if ($storageAccount.PublicNetworkAccess -ne 'Enabled') {
    throw @"
Storage Account '$storageAccountName' has PublicNetworkAccess='$($storageAccount.PublicNetworkAccess)'.
The deployed Azure Functions Consumption architecture requires access to the Storage data endpoint. Azure Policy appears to disable public network access after deployment.
Request a policy exemption that permits public network access for this Storage Account while shared-key access remains disabled, or deploy a VNet-integrated hosting plan with Private Endpoints and private DNS.
"@
}
$storageContext = New-AzStorageContext `
    -StorageAccountName $storageAccountName `
    -UseConnectedAccount
$policyTemporaryPath = Join-Path ([IO.Path]::GetTempPath()) "tag-policy-$([guid]::NewGuid()).json"
try {
    Set-Content `
        -LiteralPath $policyTemporaryPath `
        -Value $tagAuthorizationPolicyJson `
        -Encoding utf8NoBOM
    $maximumUploadAttempts = 12
    for ($uploadAttempt = 1; $uploadAttempt -le $maximumUploadAttempts; $uploadAttempt++) {
        try {
            Set-AzStorageBlobContent `
                -Context $storageContext `
                -Container 'configuration' `
                -File $policyTemporaryPath `
                -Blob 'tag-authorization-policy.json' `
                -Force | Out-Null
            break
        }
        catch {
            $isAuthorizationDelay = $_.Exception.Message -match `
                '403|AuthorizationPermissionMismatch|not authorized'
            if (-not $isAuthorizationDelay -or $uploadAttempt -eq $maximumUploadAttempts) {
                throw
            }

            Write-Warning "Storage RBAC is not active yet. Retrying policy upload in 10 seconds ($uploadAttempt/$maximumUploadAttempts)."
            Start-Sleep -Seconds 10
        }
    }
}
finally {
    Remove-Item $policyTemporaryPath -Force -ErrorAction SilentlyContinue
}

#endregion Client configuration

#region Permissions and Function publishing

if (-not $SkipGraphPermission) {
    Import-DeploymentModule -Name 'Microsoft.Graph.Authentication'
    & $grantScriptPath `
        -ManagedIdentityObjectId $managedIdentityObjectId `
        -TenantId $TenantId
}

if (-not $SkipPublish) {
    $packagePath = Join-Path ([IO.Path]::GetTempPath()) "autopilot-import-$([guid]::NewGuid()).zip"
    try {
        Compress-Archive `
            -Path @(
                (Join-Path $projectRoot 'host.json'),
                (Join-Path $projectRoot 'requirements.psd1'),
                (Join-Path $projectRoot 'profile.ps1'),
                (Join-Path $projectRoot 'ImportDevice'),
                (Join-Path $projectRoot 'ProcessDeviceAttribute'),
                (Join-Path $projectRoot 'ManageTagPolicy'),
                (Join-Path $projectRoot 'src')
            ) `
            -DestinationPath $packagePath `
            -CompressionLevel Optimal `
            -Force

        Write-Host 'Publishing Function code...'
        Publish-AzWebApp `
            -ResourceGroupName $ResourceGroupName `
            -Name $FunctionAppName `
            -ArchivePath $packagePath `
            -Force | Out-Null
    }
    finally {
        Remove-Item $packagePath -Force -ErrorAction SilentlyContinue
    }
}

#endregion Permissions and Function publishing

#region Smoke test

if (-not $SkipSmokeTest -and -not $SkipPublish) {
    Write-Host 'Running Easy Auth smoke test...'
    $smokeResponse = Invoke-WebRequest `
        -Method Post `
        -Uri $functionUrl `
        -ContentType 'application/json' `
        -Body '{}' `
        -SkipHttpErrorCheck

    if ($smokeResponse.StatusCode -ne 401) {
        throw "Smoke test expected HTTP 401 without a token, but received $($smokeResponse.StatusCode)."
    }
}

#endregion Smoke test

#region Result

$result = [pscustomobject]@{
    SubscriptionId          = $SubscriptionId
    TenantId                = $TenantId
    ResourceGroupName       = $ResourceGroupName
    FunctionAppName         = $FunctionAppName
    FunctionUrl             = $functionUrl
    ManagementUrl           = $managementUrl
    ApiApplicationIdUri     = $ApiAudience
    ManagedIdentityObjectId = $managedIdentityObjectId
    TagAuthorizationPolicy  = $tagAuthorizationPolicy
    RestrictedManagementAdministrativeUnitName = `
        $RestrictedManagementAdministrativeUnitName
    DeviceTagExtensionAttribute = $DeviceTagExtensionAttribute
    ManagerAuthorizationPolicy = $managerAuthorizationPolicy
    ClientSettingsPath      = $clientSettingsPath
    InstalledClientSettingsPath = $installedClientSettingsPath
    ClientModulePackagePath = $clientModulePackagePath
    ClientToolsPath         = [IO.Path]::GetFullPath($ClientToolsPath)
    SetupLogPath            = $setupLogPath
}

Write-Host "`nInstallation completed." -ForegroundColor Green
$result | Format-List
$result

#endregion Result
}
catch {
    $errorDetails = @(
        "Timestamp: $(Get-Date -Format 'o')"
        "Script: $PSCommandPath"
        "Message: $($_.Exception.Message)"
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
    Write-Error "Installation failed. Detailed error information was written to '$setupLogPath'." `
        -ErrorAction Continue
    if ($errorDetails -match `
        'AuthorizationFailed|does not have (?:permission|authorization)|Forbidden') {
        throw 'Azure deployment permissions are insufficient. Assign Owner, or Contributor together with Role Based Access Control Administrator, at the target resource group or subscription scope.'
    }
    throw
}
finally {
    if ($setupTranscriptActive) {
        Stop-Transcript -WhatIf:$false | Out-Null
        $setupTranscriptActive = $false
    }
}