#Requires -Version 7.2
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
Deploys the Autopilot import Azure Function and publishes its code.

.DESCRIPTION
Prompts for missing deployment values, selects the Azure subscription, creates
or updates the resource group and Entra application, deploys infra/main.bicep,
grants the managed identity its Microsoft Graph application permission,
publishes the Function package, and verifies that Easy Auth rejects anonymous
requests.

The installer also writes client.settings.json with the Function URL, API
Application ID URI, and Tenant ID used as defaults by Import-AutopilotDevice.ps1.

.PARAMETER SubscriptionId
Azure subscription GUID that will contain the Function resources. The current
Az context is offered as the interactive default.

.PARAMETER TenantId
Microsoft Entra tenant GUID that owns the API app registration and groups.

.PARAMETER ResourceGroupName
Name of the Azure resource group to create or update.

.PARAMETER Location
Azure region for the resource group and Function resources, such as westus2.

.PARAMETER FunctionAppName
Globally unique Azure Function App name. It must contain 3-60 letters, digits,
or hyphens.

.PARAMETER EntraClientId
Optional Application (client) ID of an existing Entra API app registration.
When omitted, the installer searches by EntraApplicationName and creates the
application if it does not exist.

.PARAMETER EntraApplicationName
Display name used to find or create the Entra API app registration. The default
is Autopilot Import API.

.PARAMETER ApiAudience
Optional token audience accepted by Easy Auth. The default is api:// followed
by the Entra application Client ID.

.PARAMETER TagAuthorizationRule
One or more group-to-tag rules in the form
<Entra-group-object-ID>=<tag1>,<tag2>. Missing rules are requested interactively.

.PARAMETER RequiredRole
App-role value required in caller tokens. The default is DeviceHash.Importer.

.PARAMETER InstallMissingModules
Installs missing Az modules, Microsoft.Graph.Authentication, and the Bicep CLI
for the current user where applicable.

.PARAMETER SkipEntraAppConfiguration
Skips app registration, API scope, app role, and group-assignment management.
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
client settings path.

.NOTES
The installing administrator requires Azure resource deployment permissions
and delegated Graph permissions for application and app-role management. End
users receive no Intune or Microsoft Graph permissions from this installer.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $SubscriptionId,

    [string] $TenantId,

    [string] $ResourceGroupName,

    [string] $Location,

    [string] $FunctionAppName,

    [string] $EntraClientId,

    [string] $EntraApplicationName = 'Autopilot Import API',

    [string] $ApiAudience,

    [string[]] $TagAuthorizationRule,

    [string] $RequiredRole = 'DeviceHash.Importer',

    [switch] $InstallMissingModules,

    [switch] $SkipEntraAppConfiguration,

    [switch] $SkipGraphPermission,

    [switch] $SkipPublish,

    [switch] $SkipSmokeTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
$templatePath = Join-Path $projectRoot 'infra\main.bicep'
$grantScriptPath = Join-Path $projectRoot 'scripts\Grant-ManagedIdentityGraphPermission.ps1'
$ensureEntraAppScriptPath = Join-Path $projectRoot 'scripts\Ensure-EntraApiApplication.ps1'

function Read-DeploymentValue {
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

function ConvertTo-TagAuthorizationPolicy {
    param(
        [string[]] $Rules
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

    $rulesByGroup = @{}
    foreach ($rule in $enteredRules) {
        $separatorIndex = $rule.IndexOf('=')
        if ($separatorIndex -lt 1 -or $separatorIndex -eq $rule.Length - 1) {
            throw "Invalid TagAuthorizationRule '$rule'. Expected '<group-object-id>=<tag1>,<tag2>'."
        }

        $groupId = $rule.Substring(0, $separatorIndex).Trim()
        $parsedGroupId = [guid]::Empty
        if (-not [guid]::TryParse($groupId, [ref] $parsedGroupId)) {
            throw "Group Object ID '$groupId' must be a GUID."
        }
        $normalizedGroupId = $parsedGroupId.ToString()

        $tags = @($rule.Substring($separatorIndex + 1).Split(',') | ForEach-Object {
            $_.Trim()
        } | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | Select-Object -Unique)
        if ($tags.Count -eq 0) {
            throw "At least one Device Tag is required for group '$normalizedGroupId'."
        }
        foreach ($tag in $tags) {
            if ($tag.Length -gt 128) {
                throw "Device Tag '$tag' must not exceed 128 characters."
            }
        }

        $rulesByGroup[$normalizedGroupId] = @(
            @($rulesByGroup[$normalizedGroupId]) + $tags | Select-Object -Unique
        )
    }

    $policy = @($rulesByGroup.Keys | Sort-Object | ForEach-Object {
        [pscustomobject]@{
            groupId = $_
            tags    = @($rulesByGroup[$_] | Sort-Object)
        }
    })
    return ,$policy
}

function Import-DeploymentModule {
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

if (-not (Test-Path $templatePath -PathType Leaf)) {
    throw "Bicep template not found: $templatePath"
}

Import-DeploymentModule -Name 'Az.Accounts'
Import-DeploymentModule -Name 'Az.Resources'
Import-DeploymentModule -Name 'Az.Websites'
Initialize-BicepCli

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
$ResourceGroupName = Read-DeploymentValue `
    -CurrentValue $ResourceGroupName `
    -Prompt 'Azure Resource Group' `
    -DefaultValue 'rg-autopilot-import'
$Location = Read-DeploymentValue `
    -CurrentValue $Location `
    -Prompt 'Azure Region' `
    -DefaultValue 'westeurope'

$defaultFunctionName = "func-autopilot-$($TenantId.Replace('-', '').Substring(0, 8))"
$FunctionAppName = Read-DeploymentValue `
    -CurrentValue $FunctionAppName `
    -Prompt 'Globally unique Function App name' `
    -DefaultValue $defaultFunctionName
$tagAuthorizationPolicy = ConvertTo-TagAuthorizationPolicy -Rules $TagAuthorizationRule
$tagAuthorizationPolicyJson = $tagAuthorizationPolicy | ConvertTo-Json -Depth 4 -Compress

$parsedGuid = [guid]::Empty
if (-not [guid]::TryParse($SubscriptionId, [ref] $parsedGuid)) {
    throw 'Azure Subscription ID must be a GUID.'
}
$parsedGuid = [guid]::Empty
if (-not [guid]::TryParse($TenantId, [ref] $parsedGuid)) {
    throw 'Entra Tenant ID must be a GUID.'
}
$parsedGuid = [guid]::Empty
if ($EntraClientId -and -not [guid]::TryParse($EntraClientId, [ref] $parsedGuid)) {
    throw 'Entra API application Client ID must be a GUID.'
}
if ($FunctionAppName -notmatch '^[a-zA-Z0-9-]{2,60}$') {
    throw 'Function App name must contain 2-60 letters, digits, or hyphens.'
}
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

Write-Host "`nRequested installation" -ForegroundColor Cyan
Write-Host "  Subscription : $($subscription.Name) ($SubscriptionId)"
Write-Host "  Tenant       : $TenantId"
Write-Host "  Resource group: $ResourceGroupName"
Write-Host "  Region       : $Location"
Write-Host "  Function     : $FunctionAppName"
Write-Host "  Entra app    : $EntraApplicationName"
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

$resourceGroup = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $resourceGroup) {
    $resourceGroup = New-AzResourceGroup -Name $ResourceGroupName -Location $Location
}

if (-not $SkipEntraAppConfiguration) {
    Import-DeploymentModule -Name 'Microsoft.Graph.Authentication'
    $entraApplication = & $ensureEntraAppScriptPath `
        -TenantId $TenantId `
        -ClientId $EntraClientId `
        -DisplayName $EntraApplicationName `
        -RequiredRole $RequiredRole `
        -AuthorizedGroupId $tagAuthorizationPolicy.groupId `
        -Confirm:$false
    $EntraClientId = $entraApplication.ClientId
    $ApiAudience = $entraApplication.ApplicationIdUri
}
elseif ([string]::IsNullOrWhiteSpace($EntraClientId)) {
    throw 'EntraClientId is required when SkipEntraAppConfiguration is used.'
}

if ([string]::IsNullOrWhiteSpace($ApiAudience)) {
    $ApiAudience = "api://$EntraClientId"
}

Write-Host "`nDeployment configuration" -ForegroundColor Cyan
Write-Host "  Subscription : $($subscription.Name) ($SubscriptionId)"
Write-Host "  Tenant       : $TenantId"
Write-Host "  Resource group: $ResourceGroupName"
Write-Host "  Region       : $Location"
Write-Host "  Function     : $FunctionAppName"
Write-Host "  API audience : $ApiAudience"
Write-Host "  Allowed Tags : $(@($tagAuthorizationPolicy.tags) -join ', ')"
Write-Host "  Required role: $RequiredRole`n"

$deploymentParameters = @{
    ResourceGroupName = $ResourceGroupName
    TemplateFile      = $templatePath
    functionAppName   = $FunctionAppName
    location          = $Location
    entraClientId     = $EntraClientId
    apiAudience       = $ApiAudience
    tagAuthorizationPolicy = $tagAuthorizationPolicyJson
    requiredRole      = $RequiredRole
}

Write-Host 'Validating Bicep deployment...'
$validationErrors = Test-AzResourceGroupDeployment @deploymentParameters
if ($validationErrors) {
    $validationErrors | Format-List | Out-String | Write-Error
    throw 'Bicep deployment validation failed.'
}

Write-Host 'Deploying Azure resources...'
$deployment = New-AzResourceGroupDeployment `
    @deploymentParameters `
    -Name "autopilot-import-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
if ($deployment.ProvisioningState -ne 'Succeeded') {
    throw "Azure deployment ended with state '$($deployment.ProvisioningState)'."
}

$functionUrl = [string] $deployment.Outputs.functionUrl.Value
$managedIdentityObjectId = [guid] $deployment.Outputs.managedIdentityObjectId.Value
$clientSettingsPath = Join-Path $projectRoot 'client.settings.json'
$clientSettings = [ordered]@{
    functionUrl            = $functionUrl
    apiApplicationIdUri    = $ApiAudience
    tenantId               = $TenantId
} | ConvertTo-Json
$clientSettingsTemporaryPath = "$clientSettingsPath.tmp"
Set-Content `
    -LiteralPath $clientSettingsTemporaryPath `
    -Value $clientSettings `
    -Encoding utf8NoBOM
Move-Item `
    -LiteralPath $clientSettingsTemporaryPath `
    -Destination $clientSettingsPath `
    -Force
Write-Host "Wrote client defaults to '$clientSettingsPath'."

if (-not $SkipGraphPermission) {
    Import-DeploymentModule -Name 'Microsoft.Graph.Authentication'
    & $grantScriptPath -ManagedIdentityObjectId $managedIdentityObjectId
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

$result = [pscustomobject]@{
    SubscriptionId          = $SubscriptionId
    TenantId                = $TenantId
    ResourceGroupName       = $ResourceGroupName
    FunctionAppName         = $FunctionAppName
    FunctionUrl             = $functionUrl
    ApiApplicationIdUri     = $ApiAudience
    ManagedIdentityObjectId = $managedIdentityObjectId
    TagAuthorizationPolicy  = $tagAuthorizationPolicy
    ClientSettingsPath      = $clientSettingsPath
}

Write-Host "`nInstallation completed." -ForegroundColor Green
$result | Format-List
$result