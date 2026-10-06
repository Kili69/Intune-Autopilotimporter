#Requires -Version 7.2
# Project-Version: 1.3.20261006.5
# Author: andreas.lucas@outlook.com (aka Kili)

# Copyright 2026 Andreas Lucas
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the project root for license information.

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

.PARAMETER WebClientId
Optional Application Client ID of the Entra SPA registration used by the web
frontend. When omitted, the installer finds or creates it by display name.

.PARAMETER EntraWebApplicationName
Display name used to find or create the SPA registration. The default is
Autopilot Import Web.

.PARAMETER AdditionalWebRedirectUri
Optional HTTPS redirect URIs for custom Function App domains. Existing SPA
redirect URIs are preserved.

.PARAMETER InstallerPrincipalId
Entra object ID of the user or group that remains a permanent Group Tag
manager. This parameter is required with SkipEntraAppConfiguration so that
non-interactive deployments do not need a delegated Microsoft Graph login.

.PARAMETER ApiAudience
Optional token audience accepted by Easy Auth. The default is api:// followed
by the Entra application Client ID.

.PARAMETER TagAuthorizationRule
One or more group-to-tag rules as <Entra-group-object-ID>=<tag1>,<tag2>
strings or objects with groupId, tags, and an optional
administrativeUnitName. Missing rules are requested
interactively.

.PARAMETER AdministrativeUnitName
Optional fallback administrative unit applied to string rules. Rule objects
can specify an individual regular or restricted management administrative
unit. Imported devices are added to the matching rule's unit after Intune
creates their Entra device.

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

.PARAMETER SkipExistingDeploymentDetection
Prevents delegation to Update-AutopilotImport.ps1 when the target Function App
already exists. This internal switch is used by the updater to avoid recursive
installer invocation.

.PARAMETER SkipEntraAppConfiguration
Skips app registration and API scope management.
EntraClientId must be supplied when this switch is used.

.PARAMETER SkipGraphPermission
Skips assignment of the required Microsoft Graph application permissions to
the Function managed identity, including GroupMember.Read.All and
User.ReadBasic.All.
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
PSCustomObject containing the subscription and tenant IDs and display names,
resource group, Function URL, API audience, managed identity object ID,
authorization policy, and local and installed client settings paths and client
tools directory.

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

    [guid] $WebClientId,

    [string] $EntraWebApplicationName = 'Autopilot Import Web',

    [ValidatePattern('^https://')]
    [string[]] $AdditionalWebRedirectUri,

    [guid] $InstallerPrincipalId,

    [string] $ApiAudience,

    [object[]] $TagAuthorizationRule,

    [Alias('Mau')]
    [string] $AdministrativeUnitName,

    [ValidatePattern('^extensionAttribute(?:[1-9]|1[0-5])$')]
    [string] $DeviceTagExtensionAttribute,

    [guid[]] $TagManagerPrincipalId,

    [string] $ClientToolsPath,

    [switch] $InstallMissingModules,

    [switch] $ForceGraphSignIn,

    [switch] $SkipExistingDeploymentDetection,

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
$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$isRepositoryLayout = Test-Path `
    -LiteralPath (Join-Path $repositoryRoot 'VERSION') `
    -PathType Leaf
$projectRoot = if ($isRepositoryLayout) { $repositoryRoot } else { $PSScriptRoot }
$functionAppRoot = if ($isRepositoryLayout) {
    Join-Path $projectRoot 'src\FunctionApp'
}
else {
    $projectRoot
}
$scriptsRoot = if ($isRepositoryLayout) {
    Join-Path $projectRoot 'src\Scripts'
}
else {
    Join-Path $projectRoot 'scripts'
}
$webProjectRoot = if ($isRepositoryLayout) {
    Join-Path $projectRoot 'src\Web'
}
else {
    Join-Path $projectRoot 'web'
}
$templatePath = if ($isRepositoryLayout) {
    Join-Path $projectRoot 'src\Infrastructure\main.bicep'
}
else {
    Join-Path $projectRoot 'infra\main.bicep'
}
$updaterPath = if ($isRepositoryLayout) {
    Join-Path $projectRoot 'src\Installer\Update-AutopilotImport.ps1'
}
else {
    Join-Path $projectRoot 'Update-AutopilotImport.ps1'
}
$grantScriptPath = Join-Path $scriptsRoot 'Grant-ManagedIdentityGraphPermission.ps1'
$ensureEntraAppScriptPath = Join-Path $scriptsRoot 'Ensure-EntraApiApplication.ps1'
$ensureEntraWebAppScriptPath = Join-Path $scriptsRoot 'Ensure-EntraWebApplication.ps1'
$autopilotImportModulePath = Join-Path $functionAppRoot `
    'src\AutopilotImport\AutopilotImport.psm1'
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

function Test-BuiltWebFrontend {
    <#
    .SYNOPSIS
    Tests whether the packaged web frontend contains all referenced assets.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $ProjectRoot
    )

    $sourceWebRoot = Join-Path $ProjectRoot `
        'src\FunctionApp\WebFrontend\wwwroot'
    $webRoot = if (Test-Path -LiteralPath $sourceWebRoot -PathType Container) {
        $sourceWebRoot
    }
    else {
        Join-Path $ProjectRoot 'WebFrontend\wwwroot'
    }
    $indexPath = Join-Path $webRoot 'index.html'
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        return $false
    }

    $index = Get-Content -LiteralPath $indexPath -Raw
    $assetMatches = [regex]::Matches(
        $index,
        '(?:src|href)=["''](?:/api/ui/)?(?<path>assets/[^"'']+)["'']'
    )
    if ($assetMatches.Count -eq 0) {
        return $false
    }

    return @($assetMatches | Where-Object {
        $relativePath = $_.Groups['path'].Value.Replace(
            '/',
            [IO.Path]::DirectorySeparatorChar
        )
        -not (Test-Path `
            -LiteralPath (Join-Path $webRoot $relativePath) `
            -PathType Leaf)
    }).Count -eq 0
}

function Invoke-WebReadinessRequest {
    <#
    .SYNOPSIS
    Waits for a newly published HTTP endpoint to become ready.
    #>
    param(
        [Parameter(Mandatory)]
        [uri] $Uri,

        [int] $ExpectedStatusCode = 200,

        [ValidateRange(1, 60)]
        [int] $MaximumAttempts = 24,

        [ValidateRange(0, 60)]
        [int] $RetryDelaySeconds = 5
    )

    $transientStatusCodes = @(404, 408, 429, 500, 502, 503, 504)
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            $response = Invoke-WebRequest `
                -Method Get `
                -Uri $Uri `
                -SkipHttpErrorCheck
            if ($response.StatusCode -eq $ExpectedStatusCode -or
                $response.StatusCode -notin $transientStatusCodes -or
                $attempt -eq $MaximumAttempts) {
                return $response
            }
        }
        catch {
            if ($attempt -eq $MaximumAttempts) {
                throw
            }
        }

        Write-Warning "Web endpoint is not ready yet. Retrying in $RetryDelaySeconds seconds ($attempt/$MaximumAttempts)..."
        Start-Sleep -Seconds $RetryDelaySeconds
    }
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
    <Entra-group-object-ID>=<tag1>,<tag2>, or rule objects with an optional
    administrativeUnitName. Multiple entries for the same
    group are consolidated by the AutopilotImport module.

    .OUTPUTS
    System.Object[]. Authorization policy entries containing a groupId and the
    corresponding collection of allowed tags.
    #>
    param(
        [object[]] $Rules,

        [string] $AdministrativeUnitName
    )

    $enteredRules = @($Rules | Where-Object {
        $null -ne $_ -and
        ($_ -isnot [string] -or -not [string]::IsNullOrWhiteSpace($_))
    })
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
        -AdministrativeUnitName `
            $AdministrativeUnitName)
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

function Install-AutoPilotClientTools {
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
    $sourceScriptsRoot = Join-Path $ProjectRoot 'src\Scripts'
    if (-not (Test-Path -LiteralPath $sourceScriptsRoot -PathType Container)) {
        $sourceScriptsRoot = Join-Path $ProjectRoot 'scripts'
    }
    $runtimeModuleSource = Join-Path $ProjectRoot `
        'src\FunctionApp\src\AutopilotImport\AutopilotImport.psm1'
    if (-not (Test-Path -LiteralPath $runtimeModuleSource -PathType Leaf)) {
        $runtimeModuleSource = Join-Path $ProjectRoot `
            'src\AutopilotImport\AutopilotImport.psm1'
    }
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
            -LiteralPath (Join-Path $sourceScriptsRoot $scriptName) `
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
        -LiteralPath $runtimeModuleSource `
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
        ForEach-Object {
            $oldModulePath = $_.FullName
            try {
                Remove-Item -LiteralPath $oldModulePath -Recurse -Force -ErrorAction Stop
            }
            catch [System.IO.IOException] {
                Write-Warning "Older client module '$oldModulePath' is in use and could not be removed. Close PowerShell sessions using that version and remove it later."
            }
        }

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

function Install-BicepStandaloneCli {
    <#
    .SYNOPSIS
    Installs the official standalone Bicep CLI for the current user.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $DestinationPath
    )

    $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    $assetName = switch ($architecture) {
        ([Runtime.InteropServices.Architecture]::X64) { 'bicep-win-x64.exe' }
        ([Runtime.InteropServices.Architecture]::Arm64) { 'bicep-win-arm64.exe' }
        default {
            throw "Automatic Bicep installation does not support the $architecture architecture. Install Bicep manually from https://aka.ms/bicep-install."
        }
    }
    $downloadUri = "https://github.com/Azure/bicep/releases/latest/download/$assetName"
    $destinationDirectory = Split-Path $DestinationPath -Parent
    $temporaryPath = Join-Path `
        ([IO.Path]::GetTempPath()) `
        "bicep-$([guid]::NewGuid().ToString('N')).exe"

    try {
        New-Item `
            -Path $destinationDirectory `
            -ItemType Directory `
            -Force | Out-Null
        Write-Host "Downloading the standalone Bicep CLI for $architecture..."
        Invoke-WebRequest `
            -Uri $downloadUri `
            -OutFile $temporaryPath `
            -UseBasicParsing
        if (-not (Test-Path -LiteralPath $temporaryPath -PathType Leaf) -or
            (Get-Item -LiteralPath $temporaryPath).Length -eq 0) {
            throw 'The downloaded Bicep executable is empty or missing.'
        }
        Move-Item `
            -LiteralPath $temporaryPath `
            -Destination $DestinationPath `
            -Force
        Unblock-File -LiteralPath $DestinationPath -ErrorAction SilentlyContinue
    }
    catch {
        throw "Standalone Bicep installation failed. Download Bicep manually from https://aka.ms/bicep-install. $($_.Exception.Message)"
    }
    finally {
        Remove-Item `
            -LiteralPath $temporaryPath `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

function Initialize-BicepCli {
    <#
    .SYNOPSIS
    Ensures that the Bicep CLI is available to the installer.

    .DESCRIPTION
    Returns immediately when bicep can already be resolved as a command.
    Otherwise, searches the standard per-user and system-wide installation
    paths. When Bicep is missing and the installer was started with
    InstallMissingModules, installs the Microsoft.Bicep winget package when
    winget is available. On systems without winget, such as Windows Server,
    downloads the official standalone executable for the current user. The
    resolved installation directory is added to PATH for the current process.

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
        if ($winget) {
            Write-Host 'Installing Bicep CLI with winget...'
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
        }
        else {
            Install-BicepStandaloneCli -DestinationPath $knownPaths[0]
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
        'Microsoft.Storage/storageAccounts/tableServices/write'
        'Microsoft.Storage/storageAccounts/tableServices/tables/write'
        'Microsoft.OperationalInsights/workspaces/write'
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
        $actionDescriptions = @{
            'Microsoft.Resources/deployments/write' = `
                'Create or update ARM/Bicep deployments'
            'Microsoft.Resources/subscriptions/resourceGroups/write' = `
                'Create or update the resource group'
            'Microsoft.Storage/storageAccounts/write' = `
                'Create or update the Storage Account'
            'Microsoft.Storage/storageAccounts/blobServices/write' = `
                'Create or update the Blob service'
            'Microsoft.Storage/storageAccounts/blobServices/containers/write' = `
                'Create or update Blob containers'
            'Microsoft.Storage/storageAccounts/tableServices/write' = `
                'Create or update the Table service'
            'Microsoft.Storage/storageAccounts/tableServices/tables/write' = `
                'Create or update Storage tables'
            'Microsoft.OperationalInsights/workspaces/write' = `
                'Create or update the Log Analytics workspace'
            'Microsoft.Insights/components/write' = `
                'Create or update Application Insights'
            'Microsoft.Web/serverfarms/write' = `
                'Create or update the App Service plan'
            'Microsoft.Web/sites/write' = `
                'Create or update the Function App'
            'Microsoft.Web/sites/config/write' = `
                'Create or update Function App configuration'
            'Microsoft.Authorization/roleAssignments/write' = `
                'Create or update Azure role assignments'
        }
        $missingActionDetails = @($missingActions | ForEach-Object {
            "  - $_ ($($actionDescriptions[$_]))"
        }) -join [Environment]::NewLine
        $roleAssignmentWriteMissing = $missingActions -contains `
            'Microsoft.Authorization/roleAssignments/write'
        $resourceGroupWriteMissing = $missingActions -contains `
            'Microsoft.Resources/subscriptions/resourceGroups/write'
        $requiredRoles = if ($roleAssignmentWriteMissing) {
            'Assign Owner, or assign both Contributor and Role Based Access Control Administrator (alternatively User Access Administrator).'
        }
        else {
            'Assign Contributor or Owner.'
        }
        $assignmentScope = if ($resourceGroupWriteMissing) {
            "subscription '/subscriptions/$SubscriptionId', because the resource group does not exist"
        }
        else {
            "resource group '$ResourceGroupName' or its subscription"
        }
        $permissionMessage = @(
            'Azure deployment permissions are insufficient.'
            "Checked scope: $scope"
            'Missing Azure actions:'
            $missingActionDetails
            "Required role assignment: $requiredRoles"
            "Assign the role or roles at the $assignmentScope."
            'After the assignment becomes effective, run Connect-AzAccount again and retry the installation.'
        ) -join [Environment]::NewLine
        Write-Verbose $permissionMessage
        $permissionException = [UnauthorizedAccessException]::new(
            $permissionMessage)
        $permissionException.Data['AutopilotDeploymentPermissionError'] = $true
        $permissionException.Data['MissingActions'] = `
            $missingActions -join ','
        $permissionException.Data['CheckedScope'] = $scope
        throw $permissionException
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

function Get-CustomWebRedirectUri {
    param(
        [AllowNull()]
        [object[]] $HostName
    )

    return @(
        @($HostName) |
            ForEach-Object { ([string] $_).Trim() } |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and
                $_ -notlike '*.azurewebsites.net'
            } |
            ForEach-Object { "https://$_/api/ui/index.html" } |
            Select-Object -Unique
    )
}

function Get-WebAppHostName {
    param(
        [AllowNull()]
        [object] $WebApp
    )

    if ($null -eq $WebApp) {
        return @()
    }

    $containers = @($WebApp)
    foreach ($containerName in @('SiteConfig', 'Properties')) {
        $property = $WebApp.PSObject.Properties[$containerName]
        if ($null -ne $property -and $null -ne $property.Value) {
            $containers += $property.Value
        }
    }

    return @(
        foreach ($container in $containers) {
            foreach ($propertyName in @('HostNames', 'EnabledHostNames')) {
                $property = $container.PSObject.Properties[$propertyName]
                if ($null -ne $property) {
                    @($property.Value)
                }
            }

            $sslStatesProperty = `
                $container.PSObject.Properties['HostNameSslStates']
            if ($null -ne $sslStatesProperty) {
                foreach ($sslState in @($sslStatesProperty.Value)) {
                    if ($null -ne $sslState) {
                        $nameProperty = $sslState.PSObject.Properties['Name']
                        if ($null -ne $nameProperty) {
                            $nameProperty.Value
                        }
                    }
                }
            }
        }
    )
}

function Get-WebAppHostNameBinding {
    param(
        [Parameter(Mandatory)]
        [string] $ResourceId
    )

    $response = Invoke-AzRestMethod `
        -Method GET `
        -Path "$ResourceId/hostNameBindings?api-version=2023-12-01"
    if ($response.StatusCode -ge 400) {
        throw "Function App hostname binding lookup failed with status $($response.StatusCode)."
    }

    $content = $response.Content | ConvertFrom-Json
    return @(
        @($content.value) |
            ForEach-Object { ([string] $_.name) -replace '^.*/', '' } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
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

$defaultFunctionName = "func-autopilot-$($TenantId.Replace('-', '').Substring(0, 8))"
$FunctionAppName = Read-FunctionAppName `
    -CurrentValue $FunctionAppName `
    -DefaultValue $defaultFunctionName

$contextMatches = $currentContext -and
    $currentContext.Subscription.Id -eq $SubscriptionId -and
    $currentContext.Tenant.Id -eq $TenantId
if (-not $contextMatches) {
    Connect-AzAccount `
        -Tenant $TenantId `
        -Subscription $SubscriptionId | Out-Null
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
    Connect-AzAccount `
        -Tenant $TenantId `
        -Subscription $SubscriptionId | Out-Null
    Set-AzContext `
        -Tenant $TenantId `
        -Subscription $SubscriptionId `
        -WhatIf:$false | Out-Null
    $subscription = Get-AzSubscription `
        -SubscriptionId $SubscriptionId `
        -TenantId $TenantId
}

$tenant = Get-AzTenant -TenantId $TenantId -ErrorAction Stop
$subscriptionName = if (-not [string]::IsNullOrWhiteSpace(
        [string] $subscription.Name)) {
    ([string] $subscription.Name).Trim()
}
else {
    $SubscriptionId
}
$tenantName = if (-not [string]::IsNullOrWhiteSpace(
        [string] $tenant.Name)) {
    ([string] $tenant.Name).Trim()
}
elseif (-not [string]::IsNullOrWhiteSpace(
        [string] $tenant.DefaultDomain)) {
    ([string] $tenant.DefaultDomain).Trim()
}
else {
    $TenantId
}

$existingFunctionApp = Get-AzWebApp `
    -ResourceGroupName $ResourceGroupName `
    -Name $FunctionAppName `
    -ErrorAction SilentlyContinue
if ($null -ne $existingFunctionApp -and
    -not $SkipExistingDeploymentDetection) {
    if (-not (Test-Path -LiteralPath $updaterPath -PathType Leaf)) {
        throw "Updater not found: $updaterPath"
    }
    if (-not $SkipEntraAppConfiguration -and
        -not $InstallMissingModules -and
        -not (Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication')) {
        throw (
            'Updating the existing deployment requires the PowerShell module ' +
            "'Microsoft.Graph.Authentication'. Run " +
            "'.\Install-AutopilotImport.ps1 -InstallMissingModules' to install " +
            'missing prerequisites before the update starts.'
        )
    }

    $documentsPath = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($documentsPath)) {
        $documentsPath = $HOME
    }
    $updateClientToolsPath = if (-not [string]::IsNullOrWhiteSpace(
            $ClientToolsPath)) {
        $ClientToolsPath
    }
    else {
        Join-Path $documentsPath 'AutopilotImport'
    }
    $updateParameters = @{
        SubscriptionId            = $SubscriptionId
        TenantId                  = $TenantId
        ResourceGroupName         = $ResourceGroupName
        FunctionAppName           = $FunctionAppName
        ClientToolsPath           = $updateClientToolsPath
        InstallMissingModules     = $InstallMissingModules
        ForceGraphSignIn          = $ForceGraphSignIn
        SkipEntraAppConfiguration = $SkipEntraAppConfiguration
        SkipGraphPermission       = $SkipGraphPermission
        SkipPublish               = $SkipPublish
        SkipSmokeTest             = $SkipSmokeTest
    }
    if ($PSBoundParameters.ContainsKey('Confirm')) {
        $updateParameters.Confirm = [bool] $PSBoundParameters['Confirm']
    }

    Write-Host (
        "Existing Function App '$FunctionAppName' detected. " +
        'Switching to update mode and preserving its application configuration.'
    ) -ForegroundColor Cyan
    if ($setupTranscriptActive) {
        Stop-Transcript -WhatIf:$false | Out-Null
        $setupTranscriptActive = $false
    }
    if ($WhatIfPreference) {
        return & $updaterPath @updateParameters -WhatIf
    }
    return & $updaterPath @updateParameters
}

$Location = Read-DeploymentValue `
    -CurrentValue $Location `
    -Prompt 'Azure Region' `
    -DefaultValue 'westeurope'

$documentsPath = [Environment]::GetFolderPath('MyDocuments')
if ([string]::IsNullOrWhiteSpace($documentsPath)) {
    $documentsPath = $HOME
}
$defaultClientToolsPath = Join-Path $documentsPath 'AutopilotImport'
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
        'AdministrativeUnitName')) {
    $AdministrativeUnitName = Read-Host `
        'Administrative unit display name (optional, MAU or RMAU)'
}
$AdministrativeUnitName = if (
    [string]::IsNullOrWhiteSpace(
        $AdministrativeUnitName)) {
    ''
}
else {
    $AdministrativeUnitName.Trim()
}
$tagAuthorizationPolicy = ConvertTo-TagAuthorizationPolicy `
    -Rules $TagAuthorizationRule `
    -AdministrativeUnitName `
        $AdministrativeUnitName
$tagAuthorizationPolicyJson = $tagAuthorizationPolicy | ConvertTo-Json -Depth 4 -Compress

$parsedGuid = [guid]::Empty
if ($EntraClientId -and -not [guid]::TryParse($EntraClientId, [ref] $parsedGuid)) {
    throw 'Entra API application Client ID must be a GUID.'
}

#endregion Deployment input and validation

#region Azure context and confirmation

$npmCommand = $null
$builtWebFrontendAvailable = $false
if (-not $SkipPublish) {
    $builtWebFrontendAvailable = Test-BuiltWebFrontend `
        -ProjectRoot $projectRoot
    $npmCommand = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $npmCommand -and -not $builtWebFrontendAvailable) {
        throw 'Publishing requires Node.js and npm, or a deployment package containing a complete prebuilt WebFrontend\wwwroot bundle. Install Node.js 22 or download the release deployment package.'
    }
}

$administrativeUnitNames = @($tagAuthorizationPolicy | ForEach-Object {
    if ($_.PSObject.Properties[
            'administrativeUnitName'] -and
        -not [string]::IsNullOrWhiteSpace(
            [string] $_.administrativeUnitName)) {
        ([string] $_.administrativeUnitName).Trim()
    }
} | Sort-Object -Unique)
if ($administrativeUnitNames.Count -gt 0) {
    Write-Host 'Validating configured Entra administrative units...'
    $tokenResult = Get-AzAccessToken `
        -ResourceUrl 'https://graph.microsoft.com/' `
        -ErrorAction Stop
    $graphToken = if ($tokenResult.Token -is [Security.SecureString]) {
        $tokenResult.Token
    }
    else {
        ConvertTo-SecureString ([string] $tokenResult.Token) `
            -AsPlainText `
            -Force
    }
    foreach ($administrativeUnitName in $administrativeUnitNames) {
        AutopilotImport\Resolve-EntraAdministrativeUnit `
            -AdministrativeUnitName $administrativeUnitName `
            -AccessToken $graphToken | Out-Null
    }
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
Write-Host "  Subscription : $subscriptionName ($SubscriptionId)"
Write-Host "  Tenant       : $tenantName ($TenantId)"
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
Write-Host "  Entra web app: $EntraWebApplicationName"
Write-Host "  Client tools : $ClientToolsPath"
Write-Host "  Device Tag attribute: $DeviceTagExtensionAttribute"
Write-Host "  Administrative unit: $AdministrativeUnitName"
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

$existingFunctionAppHostNames = @(
    Get-WebAppHostName -WebApp $existingFunctionApp
)
if ($null -ne $existingFunctionApp) {
    $existingFunctionAppResourceId = `
        "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName"
    $existingFunctionAppHostNames += @(
        Get-WebAppHostNameBinding `
            -ResourceId $existingFunctionAppResourceId
    )
}
$discoveredWebRedirectUris = @(
    Get-CustomWebRedirectUri -HostName $existingFunctionAppHostNames
)

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

    $webApplicationParameters = @{
        TenantId               = $TenantId
        ApiApplicationObjectId = $entraApplication.ApplicationObjectId
        ApiClientId            = $entraApplication.ClientId
        ApiScopeId             = $entraApplication.ScopeId
        RedirectUri            = "https://$FunctionAppName.azurewebsites.net/api/ui/index.html"
        DisplayName            = $EntraWebApplicationName
        Confirm                = $false
    }
    $additionalRedirectUris = @(
        @($AdditionalWebRedirectUri) + $discoveredWebRedirectUris |
            ForEach-Object { ([string] $_).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
    if ($additionalRedirectUris.Count -gt 0) {
        $webApplicationParameters.AdditionalRedirectUri = $additionalRedirectUris
    }
    if ($null -ne $WebClientId -and $WebClientId -ne [guid]::Empty) {
        $webApplicationParameters.ClientId = $WebClientId
    }
    $webApplication = & $ensureEntraWebAppScriptPath @webApplicationParameters
    $WebClientId = [guid] $webApplication.ClientId
}
elseif ([string]::IsNullOrWhiteSpace($EntraClientId)) {
    throw 'EntraClientId is required when SkipEntraAppConfiguration is used.'
}
elseif ($WebClientId -eq [guid]::Empty) {
    throw 'WebClientId is required when SkipEntraAppConfiguration is used.'
}
elseif ($InstallerPrincipalId -eq [guid]::Empty) {
    throw 'InstallerPrincipalId is required when SkipEntraAppConfiguration is used.'
}
else {
    $installingUserObjectId = $InstallerPrincipalId
    Write-Host "Preserving installer principal: $installingUserObjectId"
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
Write-Host "  Web client ID: $WebClientId"
Write-Host "  Device Tag attribute: $DeviceTagExtensionAttribute"
Write-Host "  Administrative unit: $AdministrativeUnitName"
Write-Host "  Allowed Tags : $(@($tagAuthorizationPolicy.tags) -join ', ')"
$additionalManagerPrincipalIds = @(ConvertTo-AdditionalManagerPrincipalIds `
    -PrincipalIds $TagManagerPrincipalId `
    -InstallingUserObjectId $installingUserObjectId)
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
    webClientId       = $WebClientId.ToString()
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
$webUrl = [string] $deployment.Outputs.webUrl.Value
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
    webUrl                 = $webUrl
    webClientId            = $WebClientId.ToString()
} | ConvertTo-Json
$clientSettingsPath = Join-Path $projectRoot 'client.settings.json'
Set-Content `
    -LiteralPath $clientSettingsPath `
    -Value $clientSettings `
    -Encoding utf8NoBOM
$installedClientSettingsPath = Install-AutoPilotClientTools `
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
    if (-not $builtWebFrontendAvailable) {
        Write-Host 'Building web frontend...'
        Push-Location $webProjectRoot
        try {
            & $npmCommand.Source ci
            if ($LASTEXITCODE -ne 0) {
                throw "npm ci failed with exit code $LASTEXITCODE."
            }
            & $npmCommand.Source run build
            if ($LASTEXITCODE -ne 0) {
                throw "Web frontend build failed with exit code $LASTEXITCODE."
            }
        }
        finally {
            Pop-Location
        }
    }
    else {
        Write-Host 'Publishing the complete prebuilt web frontend included in this deployment package.'
    }

    $packagePath = Join-Path ([IO.Path]::GetTempPath()) "autopilot-import-$([guid]::NewGuid()).zip"
    try {
        Compress-Archive `
            -Path @(
                (Join-Path $functionAppRoot 'host.json'),
                (Join-Path $functionAppRoot 'proxies.json'),
                (Join-Path $functionAppRoot 'requirements.psd1'),
                (Join-Path $functionAppRoot 'profile.ps1'),
                (Join-Path $functionAppRoot 'ImportDevice'),
                (Join-Path $functionAppRoot 'ProcessDeviceAttribute'),
                (Join-Path $functionAppRoot 'ManageTagPolicy'),
                (Join-Path $functionAppRoot 'GetAuthorizedTags'),
                (Join-Path $functionAppRoot 'ManageDeviceTags'),
                (Join-Path $functionAppRoot 'GetImportHistory'),
                (Join-Path $functionAppRoot 'RemoveExpiredImportHistory'),
                (Join-Path $functionAppRoot 'WebFrontend'),
                (Join-Path $functionAppRoot 'src')
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

    $webSmokeResponse = Invoke-WebReadinessRequest -Uri $webUrl
    if ($webSmokeResponse.StatusCode -ne 200) {
        throw "Web frontend smoke test expected HTTP 200, but received $($webSmokeResponse.StatusCode)."
    }
}

#endregion Smoke test

#region Result

$result = [pscustomobject]@{
    SubscriptionId          = $SubscriptionId
    SubscriptionName        = $subscriptionName
    TenantId                = $TenantId
    TenantName              = $tenantName
    ResourceGroupName       = $ResourceGroupName
    FunctionAppName         = $FunctionAppName
    FunctionUrl             = $functionUrl
    ManagementUrl           = $managementUrl
    WebUrl                  = $webUrl
    WebClientId             = $WebClientId.ToString()
    ApiApplicationIdUri     = $ApiAudience
    ManagedIdentityObjectId = $managedIdentityObjectId
    TagAuthorizationPolicy  = $tagAuthorizationPolicy
    AdministrativeUnitName = `
        $AdministrativeUnitName
    DeviceTagExtensionAttribute = $DeviceTagExtensionAttribute
    ManagerAuthorizationPolicy = $managerAuthorizationPolicy
    ClientSettingsPath      = $clientSettingsPath
    InstalledClientSettingsPath = $installedClientSettingsPath
    ClientModulePackagePath = $clientModulePackagePath
    ClientToolsPath         = [IO.Path]::GetFullPath($ClientToolsPath)
    SetupLogPath            = $setupLogPath
}

Write-Host "`nInstallation completed." -ForegroundColor Green
$result | Format-List | Out-Host
$result

#endregion Result
}
catch {
    $isDeploymentPermissionError = `
        $_.Exception.Data['AutopilotDeploymentPermissionError'] -eq $true
    $isMicrosoftGraphAuthorizationError =
        [string] $_.FullyQualifiedErrorId -match 'Microsoft\.Graph' -or
        [string] $_.TargetObject -match 'graph\.microsoft\.com'
    $errorRecordDetails = $_ | Format-List * -Force | Out-String
    $exceptionDetails = $_.Exception | Format-List * -Force | Out-String
    $isMicrosoftGraphPermissionError =
        $isMicrosoftGraphAuthorizationError -and
        @($errorRecordDetails, $exceptionDetails) -join [Environment]::NewLine `
            -match 'Authorization_RequestDenied|Forbidden'
    $graphAccount = $null
    $graphPermissionDetails = $null
    if ($isMicrosoftGraphPermissionError) {
        $entraApplicationVariable = Get-Variable `
            -Name entraApplication `
            -ErrorAction SilentlyContinue
        $graphAccount = if ($entraApplicationVariable -and
            $entraApplicationVariable.Value -and
            $entraApplicationVariable.Value.PSObject.Properties[
                'InstallingUserPrincipalName']) {
            [string] $entraApplicationVariable.Value.InstallingUserPrincipalName
        }
        else {
            'the currently signed-in Microsoft Graph account'
        }
        $graphPermissionDetails = @(
            'The Microsoft Graph account cannot update the Entra application.'
            "Account: $graphAccount"
            ''
            'This update modifies the existing Autopilot Import app registrations. The selected account needs an active Microsoft Entra Application Administrator or Cloud Application Administrator role. Azure subscription or resource-group roles do not grant this permission.'
            ''
            'To continue:'
            '1. Assign or activate one of these Microsoft Entra roles for the account, then wait for the assignment to become effective; or use another account that already has the role.'
            '2. Rerun .\Update-AutopilotImport.ps1 with the same parameters and add -ForceGraphSignIn.'
            '3. Complete the device-code sign-in with the account that has the Entra role.'
        ) -join [Environment]::NewLine
    }
    $errorDetails = @(
        "Timestamp: $(Get-Date -Format 'o')"
        "Script: $PSCommandPath"
        "Message: $($_.Exception.Message)"
        if ($isDeploymentPermissionError) {
            "Checked scope: $($_.Exception.Data['CheckedScope'])"
            "Missing actions: $($_.Exception.Data['MissingActions'])"
        }
        'Error record:'
        $errorRecordDetails
        'Exception:'
        $exceptionDetails
        'Script stack trace:'
        $_.ScriptStackTrace
        if ($graphPermissionDetails) {
            'Operator guidance:'
            $graphPermissionDetails
        }
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
    if ($isDeploymentPermissionError) {
        throw
    }
    if ($isMicrosoftGraphPermissionError) {
        $permissionException = [InvalidOperationException]::new(
            'Microsoft Entra permission is required to update the app registrations.'
        )
        $permissionException.Data['AutopilotGraphPermissionError'] = $true
        $permissionException.Data['GraphAccount'] = $graphAccount
        $permissionException.Data['PermissionDetails'] = $graphPermissionDetails
        $permissionException.Data['InstallerLogPath'] = $setupLogPath
        throw $permissionException
    }
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