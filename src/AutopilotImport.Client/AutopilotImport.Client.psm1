#Requires -Version 7.2
# Project-Version: 1.2.20260929.3
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
.SYNOPSIS
Provides client commands for the secured Windows Autopilot import service.

.DESCRIPTION
The AutopilotImport.Client module validates and imports Autopilot CSV files,
queries asynchronous import status, and manages Group Tag authorization and
manager policies. Commands resolve deployment settings from
persisted per-user configuration, client.settings.json, or explicit parameters
and acquire Microsoft Entra access tokens through Az.Accounts.

The module does not store credentials or access tokens. Administrative commands
that change policies support WhatIf and confirmation through ShouldProcess.

.NOTES
Requires PowerShell 7.2 or later. Runtime commands require Az.Accounts;
manager-policy commands additionally require Az.Websites and Az.Resources.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-ClientCommand {
    <#
    .SYNOPSIS
    Verifies that required PowerShell commands are available.

    .DESCRIPTION
    Resolves every supplied command name through Get-Command and throws one
    consolidated error listing commands that are not installed or discoverable.

    .PARAMETER Name
    Names of commands required by the calling client operation.

    .OUTPUTS
    None. The function throws when one or more commands are unavailable.
    #>
    param([Parameter(Mandatory)][string[]] $Name)

    $missing = @($Name | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missing.Count -gt 0) {
        throw "Required PowerShell commands are missing: $($missing -join ', '). Install the corresponding Az modules."
    }
}

function Resolve-ClientConfiguration {
    <#
    .SYNOPSIS
    Loads client settings and applies explicit parameter overrides.

    .DESCRIPTION
    Reads a JSON configuration file into a hashtable. When ConfigPath is empty,
    the persisted user configuration is preferred, followed by a legacy
    client.settings.json beside the module. Non-null and non-empty override
    values replace values read from the file. The resolved file path is returned
    in the ConfigPath entry even when the file does not exist.

    .PARAMETER ConfigPath
    Optional path to client.settings.json.

    .PARAMETER Overrides
    Setting names and explicit values that take precedence over file values.

    .OUTPUTS
    System.Collections.Hashtable containing merged settings and ConfigPath.
    #>
    param(
        [string] $ConfigPath,
        [hashtable] $Overrides = @{}
    )

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        # Prefer the upgrade-stable user file, but keep installed legacy
        # configurations working until the user bootstraps a profile file.
        $userConfigPath = Get-DefaultClientConfigurationPath
        $legacyConfigPath = Join-Path $PSScriptRoot 'client.settings.json'
        $ConfigPath = if (Test-Path -LiteralPath $userConfigPath -PathType Leaf) {
            $userConfigPath
        }
        elseif (Test-Path -LiteralPath $legacyConfigPath -PathType Leaf) {
            $legacyConfigPath
        }
        else {
            $userConfigPath
        }
    }

    $configuration = @{}
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        try {
            $settings = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        }
        catch {
            throw "Client configuration '$ConfigPath' is not valid JSON: $($_.Exception.Message)"
        }
        foreach ($property in $settings.PSObject.Properties) {
            $configuration[$property.Name] = $property.Value
        }
    }

    # Explicit command parameters always take precedence over persisted values.
    foreach ($name in $Overrides.Keys) {
        if ($null -ne $Overrides[$name] -and
            -not [string]::IsNullOrWhiteSpace([string] $Overrides[$name])) {
            $configuration[$name] = $Overrides[$name]
        }
    }

    $configuration.ConfigPath = $ConfigPath
    return $configuration
}

function Get-DefaultClientConfigurationPath {
    <#
    .SYNOPSIS
    Returns the persistent per-user client configuration path.

    .DESCRIPTION
    Places client.settings.json below the current user's home directory so the
    configuration survives module upgrades and does not require write access to
    the PowerShell module installation directory.

    .OUTPUTS
    System.String containing the absolute per-user configuration path.
    #>
    $userProfilePath = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::UserProfile
    )
    if ([string]::IsNullOrWhiteSpace($userProfilePath)) {
        $userProfilePath = [string] $HOME
    }
    if ([string]::IsNullOrWhiteSpace($userProfilePath)) {
        throw 'The current user profile path could not be determined.'
    }

    $configurationDirectory = Join-Path `
        ([IO.Path]::GetFullPath($userProfilePath)) `
        '.autopilotimporter'
    return Join-Path $configurationDirectory 'client.settings.json'
}

function Get-ConfigurationValue {
    <#
    .SYNOPSIS
    Returns one required value from resolved client configuration.

    .PARAMETER Configuration
    Hashtable returned by Resolve-ClientConfiguration.

    .PARAMETER Name
    Configuration key to retrieve.

    .PARAMETER Description
    Human-readable setting name included in the error when the value is absent.

    .OUTPUTS
    System.String containing the required setting value.
    #>
    param(
        [Parameter(Mandatory)][hashtable] $Configuration,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Description
    )

    $value = [string] $Configuration[$Name]
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "$Description is missing. Run Get-AutoPilotImporterClientConfiguration -FunctionUrl '<Function-URL>' once, provide -ConfigPath, or pass the value explicitly."
    }
    return $value
}

function Get-ClientApiErrorMessage {
    <#
    .SYNOPSIS
    Converts an import API error into an actionable client message.

    .DESCRIPTION
    Parses the Function error response when available, maps known service error
    codes to user-facing guidance, and appends the serial number and correlation
    ID needed to identify the failed request.

    .PARAMETER ErrorRecord
    Error raised by the import API request.

    .PARAMETER SerialNumber
    Device serial number associated with the failed request.

    .PARAMETER GroupTag
    Group Tag requested for the failed import.

    .OUTPUTS
    System.String containing the formatted error message.
    #>
    param(
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord] $ErrorRecord,
        [Parameter(Mandatory)][string] $SerialNumber,
        [Parameter(Mandatory)][string] $GroupTag
    )

    $response = $null
    $responseText = if ($ErrorRecord.ErrorDetails) {
        [string] $ErrorRecord.ErrorDetails.Message
    }
    else {
        ''
    }
    if (-not [string]::IsNullOrWhiteSpace($responseText)) {
        try { $response = $responseText | ConvertFrom-Json }
        catch { $response = $null }
    }

    $errorCode = if ($response -and $response.PSObject.Properties['error']) {
        [string] $response.error
    }
    else { '' }
    $serverMessage = if ($response -and $response.PSObject.Properties['message']) {
        [string] $response.message
    }
    else { '' }
    $correlationId = if ($response -and $response.PSObject.Properties['correlationId']) {
        [string] $response.correlationId
    }
    else { '' }

    $message = switch ($errorCode) {
        'groupTagNotAllowed' {
            "Group Tag '$GroupTag' is not allowed for the signed-in user. Verify the tag and the user's Entra group assignments."
        }
        'authenticationRequired' {
            'Authentication is required. Sign in again and retry the import.'
        }
        'invalidPrincipal' {
            'The signed-in identity could not be validated by the Function.'
        }
        'invalidRequest' {
            if (-not [string]::IsNullOrWhiteSpace($serverMessage)) {
                "The import request is invalid: $serverMessage"
            }
            else {
                'The import request is invalid.'
            }
        }
        'graphImportFailed' {
            'Microsoft Graph rejected or could not complete the Autopilot import.'
        }
        'serviceNotConfigured' {
            'The Autopilot import service is not configured correctly. Contact the service administrator.'
        }
        default {
            "Autopilot import failed: $($ErrorRecord.Exception.Message)"
        }
    }

    $message = "Import failed for serial '$SerialNumber'. $message"
    if (-not [string]::IsNullOrWhiteSpace($correlationId)) {
        $message += " Correlation ID: $correlationId."
    }
    return $message
}

function Add-ClientImportMetadata {
    <#
    .SYNOPSIS
    Adds client-side timing and availability information to an import response.

    .PARAMETER ImportResponse
    Response object returned by the Autopilot import Function.

    .PARAMETER ImportedAt
    Local timestamp recorded for the accepted import. Defaults to the current
    time including its UTC offset.

    .OUTPUTS
    System.Management.Automation.PSObject containing the original response plus
    importedAt and intuneAvailabilityNote properties.
    #>
    param(
        [Parameter(Mandatory)][psobject] $ImportResponse,
        [datetimeoffset] $ImportedAt = [datetimeoffset]::Now
    )

    $ImportResponse | Add-Member `
        -NotePropertyName importedAt `
        -NotePropertyValue $ImportedAt.ToString('yyyy-MM-dd HH:mm:ss zzz') `
        -Force
    $ImportResponse | Add-Member `
        -NotePropertyName intuneAvailabilityNote `
        -NotePropertyValue 'Intune processes imports asynchronously. It may take several minutes before the device appears in the Intune admin center.' `
        -Force
    return $ImportResponse
}

function Add-ClientImportStatusMetadata {
    <#
    .SYNOPSIS
    Adds a description and final-state flag to an import status response.

    .DESCRIPTION
    Interprets the Intune import status and extension-attribute status. The
    response is final when the import failed or both import and extension update
    completed.

    .PARAMETER ImportStatus
    Status response returned by the Autopilot import Function.

    .OUTPUTS
    System.Object containing the original status plus statusDescription and
    isFinal properties.
    #>
    param([Parameter(Mandatory)][object] $ImportStatus)

    $status = ([string] $ImportStatus.status).ToLowerInvariant()
    $extensionStatus = if ($ImportStatus.PSObject.Properties['extensionAttributeStatus']) {
        ([string] $ImportStatus.extensionAttributeStatus).ToLowerInvariant()
    }
    else {
        'unknown'
    }
    $description = switch ($status) {
        'unknown' {
            'Intune has accepted the import, but asynchronous processing has not reported a definitive state yet.'
        }
        'pending' {
            'Intune is processing the imported hardware hash.'
        }
        'partial' {
            'Intune has partially processed the import; processing is not complete yet.'
        }
        'complete' {
            if ($extensionStatus -eq 'complete') {
                'Intune completed the Autopilot import and the Entra device extension attribute was set successfully.'
            }
            else {
                'Intune completed the Autopilot import; the Entra device extension attribute update is still pending.'
            }
        }
        'error' {
            'Intune could not complete the Autopilot device import.'
        }
        default {
            "Intune returned the unrecognized import status '$status'."
        }
    }

    $ImportStatus | Add-Member -NotePropertyName statusDescription `
        -NotePropertyValue $description -Force
    $isFinal = $status -eq 'error' -or
        ($status -eq 'complete' -and $extensionStatus -eq 'complete')
    $ImportStatus | Add-Member -NotePropertyName isFinal `
        -NotePropertyValue $isFinal -Force
    return $ImportStatus
}

function Get-ClientAccessToken {
    <#
    .SYNOPSIS
    Acquires an Azure PowerShell access token for a resource.

    .DESCRIPTION
    Reuses the current Az context when tenant and optional subscription match.
    Otherwise, it starts Connect-AzAccount before requesting a token with
    Get-AzAccessToken. The returned token is normalized to SecureString.

    .PARAMETER TenantId
    Microsoft Entra tenant used for authentication.

    .PARAMETER ResourceUrl
    Application ID URI or resource URL for which the token is requested.

    .PARAMETER SubscriptionId
    Optional Azure subscription that the active context must use.

    .OUTPUTS
    System.Security.SecureString containing the access token.
    #>
    param(
        [Parameter(Mandatory)][string] $TenantId,
        [Parameter(Mandatory)][string] $ResourceUrl,
        [string] $SubscriptionId
    )

    Assert-ClientCommand -Name 'Get-AzContext', 'Connect-AzAccount', 'Get-AzAccessToken'
    $context = Get-AzContext -ErrorAction SilentlyContinue
    # Reuse the current login only when it belongs to the requested tenant and,
    # for control-plane calls, the requested subscription.
    $contextMatches = $context -and [string] $context.Tenant.Id -eq $TenantId
    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $contextMatches = $contextMatches -and
            [string] $context.Subscription.Id -eq $SubscriptionId
    }
    if (-not $contextMatches) {
        $connectParameters = @{ Tenant = $TenantId }
        if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
            $connectParameters.Subscription = $SubscriptionId
        }
        Connect-AzAccount @connectParameters | Out-Null
    }

    $tokenResult = Get-AzAccessToken -ResourceUrl $ResourceUrl
    # Normalize old and new Az.Accounts token shapes before returning a
    # SecureString accepted by Invoke-RestMethod -Authentication Bearer.
    $plainToken = if ($tokenResult.Token -is [Security.SecureString]) {
        ConvertFrom-SecureString -SecureString $tokenResult.Token -AsPlainText
    }
    else {
        [string] $tokenResult.Token
    }
    return ConvertTo-SecureString $plainToken -AsPlainText -Force
}

function Resolve-ClientFunctionAppFromUrl {
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^https://')]
        [string] $FunctionUrl,

        [Parameter(Mandatory)]
        [string] $TenantId,

        [string] $SubscriptionId
    )

    Assert-ClientCommand -Name @(
        'Get-AzContext'
        'Get-AzSubscription'
        'Get-AzWebApp'
        'Set-AzContext'
    )
    $functionUri = [uri] $FunctionUrl
    $hostName = $functionUri.Host
    [void] (Get-ClientAccessToken `
        -TenantId $TenantId `
        -ResourceUrl 'https://management.azure.com/' `
        -SubscriptionId $SubscriptionId)
    $originalContext = Get-AzContext -ErrorAction SilentlyContinue
    $subscriptions = if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
        @(Get-AzSubscription -TenantId $TenantId -ErrorAction Stop)
    }
    else {
        @(Get-AzSubscription `
            -SubscriptionId $SubscriptionId `
            -TenantId $TenantId `
            -ErrorAction Stop)
    }
    $matches = [Collections.Generic.List[object]]::new()
    try {
        foreach ($subscription in $subscriptions) {
            try {
                $subscriptionContext = Set-AzContext `
                    -Tenant $subscription.TenantId `
                    -Subscription $subscription.Id `
                    -WhatIf:$false `
                    -ErrorAction Stop
                foreach ($webApp in @(Get-AzWebApp `
                        -DefaultProfile $subscriptionContext `
                        -ErrorAction Stop)) {
                    $hostNames = @($webApp.HostNames) +
                        @($webApp.DefaultHostName)
                    if ([string] $webApp.Kind -like '*functionapp*' -and
                        $hostName -in $hostNames) {
                        $matches.Add([pscustomobject]@{
                                SubscriptionId = [string] $subscription.Id
                                ResourceGroupName = [string] $webApp.ResourceGroup
                                FunctionAppName = [string] $webApp.Name
                            })
                    }
                }
            }
            catch {
                Write-Verbose "Function App discovery could not search subscription '$($subscription.Id)': $($_.Exception.Message)"
            }
        }
    }
    finally {
        if ($originalContext) {
            Set-AzContext `
                -Context $originalContext `
                -WhatIf:$false `
                -ErrorAction SilentlyContinue | Out-Null
        }
    }
    if ($matches.Count -eq 0) {
        throw "No accessible Azure Function App uses hostname '$hostName'. Verify Azure access or pass -SubscriptionId, -ResourceGroupName, and -FunctionAppName explicitly."
    }
    if ($matches.Count -gt 1) {
        throw "Hostname '$hostName' matched more than one accessible Azure Function App. Pass -SubscriptionId, -ResourceGroupName, and -FunctionAppName explicitly."
    }
    return $matches[0]
}

function Save-ClientDeploymentConfiguration {
    param(
        [Parameter(Mandatory)]
        [hashtable] $Configuration,

        [Parameter(Mandatory)]
        [object] $Deployment
    )

    $settingsPath = [string] $Configuration.ConfigPath
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        return
    }
    $settings = Get-Content -LiteralPath $settingsPath -Raw |
        ConvertFrom-Json -AsHashtable
    $settings['subscriptionId'] = [string] $Deployment.SubscriptionId
    $settings['resourceGroupName'] = [string] $Deployment.ResourceGroupName
    $settings['functionAppName'] = [string] $Deployment.FunctionAppName
    $temporaryPath = "$settingsPath.tmp"
    try {
        $settings | ConvertTo-Json | Set-Content `
            -LiteralPath $temporaryPath `
            -Encoding utf8NoBOM
        Move-Item `
            -LiteralPath $temporaryPath `
            -Destination $settingsPath `
            -Force
    }
    finally {
        Remove-Item `
            -LiteralPath $temporaryPath `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

function Get-CoreModulePath {
    <#
    .SYNOPSIS
    Locates the AutopilotImport runtime module used by client policy commands.

    .DESCRIPTION
    Supports both the installed client-package layout and the repository or
    deployment-package layout, returning the first existing core module path.

    .OUTPUTS
    System.String containing the path to AutopilotImport.psm1.
    #>
    $candidates = @(
        (Join-Path $PSScriptRoot 'AutopilotImport.psm1'),
        (Join-Path $PSScriptRoot '..\AutopilotImport\AutopilotImport.psm1')
    )
    $modulePath = $candidates | Where-Object { Test-Path $_ -PathType Leaf } |
        Select-Object -First 1
    if (-not $modulePath) {
        throw "Required AutopilotImport core module was not found. Checked: $($candidates -join ', ')"
    }
    return $modulePath
}

function Get-AutoPilotImporterClientConfiguration {
    <#
    .SYNOPSIS
    Displays the active Autopilot Import client configuration.

    .DESCRIPTION
    With FunctionUrl, retrieves the public runtime configuration from the
    Function App and persists it in the current user's profile. Without
    FunctionUrl, reads the previously persisted configuration. A legacy
    client.settings.json beside the module remains supported when no user
    configuration exists.

    The runtime configuration contains no credentials, secrets, or access
    tokens. Azure subscription and resource group values are optional because
    the Function runtime does not expose Azure control-plane metadata.

    .PARAMETER FunctionUrl
    HTTPS URL of the Function App. The URL may be the Function origin or any URL
    below that origin. The command retrieves /api/ui/config from the same host.

    .PARAMETER SubscriptionId
    Optional Azure subscription ID to persist for manager-policy commands.

    .PARAMETER ResourceGroupName
    Optional Azure resource group containing the Function App. Required by
    manager-policy commands when it is not already persisted.

    .PARAMETER FunctionAppName
    Optional Azure Function App resource name. Specify this when FunctionUrl
    uses a custom domain and manager-policy commands will be used.

    .PARAMETER ConfigPath
    Optional path at which the retrieved configuration is stored or from which
    an existing configuration is read. When omitted, the command uses
    ~/.autopilotimporter/client.settings.json.

    .EXAMPLE
    Get-AutoPilotImporterClientConfiguration `
        -FunctionUrl 'https://func-autopilot-import.azurewebsites.net'

    Retrieves the Function runtime configuration, stores it in the user profile,
    and returns the resolved values.

    .EXAMPLE
    Get-AutoPilotImporterClientConfiguration `
        -FunctionUrl 'https://autopilot.example.com' `
        -SubscriptionId '00000000-0000-0000-0000-000000000000' `
        -ResourceGroupName 'rg-autopilot-import' `
        -FunctionAppName 'func-autopilot-import'

    Stores both public endpoints and Azure deployment details for manager-policy
    commands when the service uses a custom domain.

    .EXAMPLE
    Get-AutoPilotImporterClientConfiguration | Format-List

    Displays the configuration persisted by an earlier bootstrap call.

    .INPUTS
    None. This command does not accept pipeline input.

    .OUTPUTS
    PSCustomObject containing the resolved client configuration.
    #>
    [CmdletBinding()]
    param(
        [ValidatePattern('^https://')]
        [string] $FunctionUrl,

        [guid] $SubscriptionId,

        [ValidateNotNullOrEmpty()]
        [string] $ResourceGroupName,

        [ValidateNotNullOrEmpty()]
        [string] $FunctionAppName,

        [string] $ConfigPath
    )

    if (-not [string]::IsNullOrWhiteSpace($FunctionUrl)) {
        $resolvedConfigPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
            Get-DefaultClientConfigurationPath
        }
        else {
            [IO.Path]::GetFullPath($ConfigPath)
        }
        $existingConfiguration = Resolve-ClientConfiguration `
            -ConfigPath $resolvedConfigPath
        $functionUri = [uri] $FunctionUrl
        if (-not $functionUri.IsAbsoluteUri -or $functionUri.Scheme -ne 'https') {
            throw 'FunctionUrl must be an absolute HTTPS URL.'
        }

        # Accept any URL below the Function host, but always discover settings
        # from the well-known endpoint on that same origin.
        $origin = $functionUri.GetLeftPart([UriPartial]::Authority)
        $runtimeConfigurationUrl = "$origin/api/ui/config"
        try {
            $runtimeConfiguration = Invoke-RestMethod `
                -Method Get `
                -Uri $runtimeConfigurationUrl `
                -ErrorAction Stop
        }
        catch {
            throw "Could not retrieve the Autopilot Import client configuration from '$runtimeConfigurationUrl'. $($_.Exception.Message)"
        }

        # Copy response properties into a hashtable so missing optional fields
        # remain safe to inspect while StrictMode is enabled.
        $runtimeSettings = @{}
        foreach ($property in $runtimeConfiguration.PSObject.Properties) {
            $runtimeSettings[$property.Name] = $property.Value
        }
        $clientId = [string] $runtimeSettings['clientId']
        $authority = [string] $runtimeSettings['authority']
        $scope = [string] $runtimeSettings['scope']
        $importUrl = [string] $runtimeSettings['importUrl']
        $functionVersion = [string] $runtimeSettings['functionVersion']
        $scopeSuffix = '/DeviceHash.Import'
        if ([string]::IsNullOrWhiteSpace($clientId) -or
            [string]::IsNullOrWhiteSpace($authority) -or
            [string]::IsNullOrWhiteSpace($scope) -or
            [string]::IsNullOrWhiteSpace($importUrl)) {
            throw "The Function runtime configuration from '$runtimeConfigurationUrl' is incomplete."
        }

        $parsedClientId = [guid]::Empty
        if (-not [guid]::TryParse($clientId, [ref] $parsedClientId)) {
            throw "The Function runtime configuration contains an invalid web client ID '$clientId'."
        }

        $authorityUri = [uri] $authority
        $tenantId = $authorityUri.AbsolutePath.Trim('/')
        $parsedTenantId = [guid]::Empty
        if ($authorityUri.Scheme -ne 'https' -or
            $authorityUri.Host -ne 'login.microsoftonline.com' -or
            -not [guid]::TryParse($tenantId, [ref] $parsedTenantId)) {
            throw "The Function runtime configuration contains an invalid Microsoft Entra authority '$authority'."
        }
        if (-not $scope.EndsWith(
                $scopeSuffix,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "The Function runtime configuration contains an invalid API scope '$scope'."
        }
        # The token audience is the configured scope without its delegated
        # permission suffix, for example api://<client-id>.
        $apiApplicationIdUri = $scope.Substring(
            0,
            $scope.Length - $scopeSuffix.Length
        )
        if (-not $apiApplicationIdUri.StartsWith(
                'api://',
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "The Function runtime configuration contains an invalid API audience '$apiApplicationIdUri'."
        }

        # Do not persist a service endpoint redirected to another host by a
        # malformed or compromised discovery response.
        $importUri = [uri] $importUrl
        if ($importUri.Scheme -ne 'https' -or
            $importUri.GetLeftPart([UriPartial]::Authority) -ne $origin) {
            throw 'The Function runtime configuration contains an import URL from a different origin.'
        }

        $inferredFunctionAppName = if ($functionUri.Host.EndsWith(
                '.azurewebsites.net',
                [StringComparison]::OrdinalIgnoreCase)) {
            $functionUri.Host.Split('.')[0]
        }
        else {
            $null
        }
        $resolvedSubscriptionId = if (
            $PSBoundParameters.ContainsKey('SubscriptionId')) {
            $SubscriptionId.ToString()
        }
        else {
            [string] $existingConfiguration['subscriptionId']
        }
        $resolvedResourceGroupName = if (
            $PSBoundParameters.ContainsKey('ResourceGroupName')) {
            $ResourceGroupName
        }
        else {
            [string] $existingConfiguration['resourceGroupName']
        }
        $resolvedFunctionAppName = if (
            $PSBoundParameters.ContainsKey('FunctionAppName')) {
            $FunctionAppName
        }
        elseif (-not [string]::IsNullOrWhiteSpace(
                $inferredFunctionAppName)) {
            $inferredFunctionAppName
        }
        else {
            [string] $existingConfiguration['functionAppName']
        }
        $configurationDirectory = Split-Path `
            -Parent `
            -Path $resolvedConfigPath
        New-Item `
            -Path $configurationDirectory `
            -ItemType Directory `
            -Force | Out-Null

        $settings = [ordered]@{
            functionUrl         = $importUri.AbsoluteUri
            managementUrl       = "$origin/api/management/tag-policy"
            apiApplicationIdUri = $apiApplicationIdUri
            tenantId            = $parsedTenantId.ToString()
            subscriptionId      = $resolvedSubscriptionId
            resourceGroupName   = $resolvedResourceGroupName
            functionAppName     = $resolvedFunctionAppName
            webUrl              = "$origin/api/ui/index.html"
            webClientId         = $parsedClientId.ToString()
            functionVersion     = $functionVersion
        }
        # Write completely before replacing the profile file so interrupted
        # writes cannot leave a partially serialized configuration behind.
        $temporaryPath = "$resolvedConfigPath.tmp"
        try {
            $settings | ConvertTo-Json | Set-Content `
                -LiteralPath $temporaryPath `
                -Encoding utf8NoBOM
            Move-Item `
                -LiteralPath $temporaryPath `
                -Destination $resolvedConfigPath `
                -Force
        }
        finally {
            Remove-Item `
                -LiteralPath $temporaryPath `
                -Force `
                -ErrorAction SilentlyContinue
        }
        $missingAzureValues = @(
            if ([string]::IsNullOrWhiteSpace($resolvedSubscriptionId)) {
                'SubscriptionId'
            }
            if ([string]::IsNullOrWhiteSpace($resolvedResourceGroupName)) {
                'ResourceGroupName'
            }
            if ([string]::IsNullOrWhiteSpace($resolvedFunctionAppName)) {
                'FunctionAppName'
            }
        )
        if ($missingAzureValues.Count -gt 0) {
            Write-Warning "The API configuration was saved, but Azure deployment details required by manager-policy commands are missing: $($missingAzureValues -join ', '). Run this command again with -SubscriptionId, -ResourceGroupName, and -FunctionAppName."
        }
    }

    $configuration = Resolve-ClientConfiguration -ConfigPath $ConfigPath
    $resolvedConfigPath = [IO.Path]::GetFullPath(
        [string] $configuration.ConfigPath
    )
    if (-not (Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf)) {
        throw "Client configuration '$resolvedConfigPath' was not found. Run Get-AutoPilotImporterClientConfiguration -FunctionUrl '<Function-URL>' once or provide -ConfigPath."
    }

    $requiredSettings = [ordered]@{
        functionUrl         = 'Function URL'
        managementUrl       = 'management URL'
        apiApplicationIdUri = 'API application ID URI'
        tenantId            = 'Tenant ID'
        webUrl              = 'web URL'
    }
    $resolvedSettings = @{}
    foreach ($setting in $requiredSettings.GetEnumerator()) {
        $resolvedSettings[$setting.Key] = Get-ConfigurationValue `
            -Configuration $configuration `
            -Name $setting.Key `
            -Description $setting.Value
    }

    [pscustomobject][ordered]@{
        SubscriptionId      = [string] $configuration['subscriptionId']
        TenantId            = $resolvedSettings.tenantId
        ResourceGroupName   = [string] $configuration['resourceGroupName']
        FunctionAppName     = [string] $configuration['functionAppName']
        FunctionUrl         = $resolvedSettings.functionUrl
        ManagementUrl       = $resolvedSettings.managementUrl
        ApiApplicationIdUri = $resolvedSettings.apiApplicationIdUri
        WebUrl              = $resolvedSettings.webUrl
        WebClientId         = [string] $configuration['webClientId']
        FunctionVersion     = [string] $configuration['functionVersion']
        ConfigPath          = $resolvedConfigPath
    }
}

function New-AutoPilotImporterClientConfiguration {
    <#
    .SYNOPSIS
    Creates client.settings.json for an existing Autopilot Import deployment.

    .DESCRIPTION
    Connects to the specified Azure subscription and reads the Function App's
    Easy Auth configuration to determine the API application ID URI. It then
    creates a complete client.settings.json in the current directory or an
    optional output directory.

    .PARAMETER SubscriptionId
    Azure subscription containing the deployed Function App.

    .PARAMETER ResourceGroupName
    Resource group containing the deployed Function App.

    .PARAMETER TenantId
    Microsoft Entra tenant containing the API application.

    .PARAMETER FunctionAppName
    Name of the deployed Function App.

    .PARAMETER OutputPath
    Directory in which client.settings.json is created. The default is the
    current directory.

    .PARAMETER Force
    Replaces an existing client.settings.json in the output directory.

    .EXAMPLE
    New-AutoPilotImporterClientConfiguration `
        -SubscriptionId '00000000-0000-0000-0000-000000000000' `
        -ResourceGroupName 'rg-autopilot-import' `
        -TenantId '11111111-1111-1111-1111-111111111111' `
        -FunctionAppName 'func-autopilot-import'

    Creates client.settings.json in the current directory.

    .EXAMPLE
    New-AutoPilotImporterClientConfiguration `
        -SubscriptionId '00000000-0000-0000-0000-000000000000' `
        -ResourceGroupName 'rg-autopilot-import' `
        -TenantId '11111111-1111-1111-1111-111111111111' `
        -FunctionAppName 'func-autopilot-import' `
        -OutputPath 'C:\AutopilotImport' `
        -Force

    Creates or replaces C:\AutopilotImport\client.settings.json.

    .INPUTS
    None. This command does not accept pipeline input.

    .OUTPUTS
    System.IO.FileInfo. Returns the created client.settings.json file.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'None')]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ [guid]::TryParse($_, [ref] ([guid]::Empty)) })]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [ValidateScript({ [guid]::TryParse($_, [ref] ([guid]::Empty)) })]
        [string] $TenantId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $FunctionAppName,

        [ValidateNotNullOrEmpty()]
        [string] $OutputPath = (Get-Location).Path,

        [switch] $Force
    )

    Assert-ClientCommand -Name @(
        'Get-AzContext'
        'Connect-AzAccount'
        'Set-AzContext'
        'Invoke-AzRestMethod'
    )

    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context -or
        [string] $context.Subscription.Id -ne $SubscriptionId -or
        [string] $context.Tenant.Id -ne $TenantId) {
        Connect-AzAccount `
            -Tenant $TenantId `
            -Subscription $SubscriptionId | Out-Null
    }
    Set-AzContext `
        -Tenant $TenantId `
        -Subscription $SubscriptionId | Out-Null

    $resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName"
    $authenticationResponse = Invoke-AzRestMethod `
        -Method GET `
        -Path "$resourceId/config/authsettingsV2?api-version=2023-12-01"
    if ($authenticationResponse.StatusCode -ge 400) {
        throw "Unable to read Easy Auth settings for Function App '$FunctionAppName'."
    }

    $authentication = $authenticationResponse.Content | ConvertFrom-Json
    $azureAdConfiguration = `
        $authentication.properties.identityProviders.azureActiveDirectory
    $clientId = [string] $azureAdConfiguration.registration.clientId
    $apiApplicationIdUri = [string] @(
        $azureAdConfiguration.validation.allowedAudiences |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace([string] $_) -and
                [string] $_ -ne $clientId
            } |
            Select-Object -First 1
    )[0]
    if ([string]::IsNullOrWhiteSpace($apiApplicationIdUri) -and
        -not [string]::IsNullOrWhiteSpace($clientId)) {
        $apiApplicationIdUri = "api://$clientId"
    }
    if ([string]::IsNullOrWhiteSpace($apiApplicationIdUri)) {
        throw "Function App '$FunctionAppName' does not contain an API application ID URI in its Easy Auth settings."
    }

    $resolvedOutputPath = [IO.Path]::GetFullPath($OutputPath)
    $settingsPath = Join-Path $resolvedOutputPath 'client.settings.json'
    if ((Test-Path -LiteralPath $settingsPath) -and -not $Force) {
        throw "Client configuration '$settingsPath' already exists. Use -Force to replace it."
    }
    if (-not $PSCmdlet.ShouldProcess($settingsPath, 'Create client configuration')) {
        return
    }

    New-Item -Path $resolvedOutputPath -ItemType Directory -Force | Out-Null
    [ordered]@{
        functionUrl            = "https://$FunctionAppName.azurewebsites.net/api/devices/import"
        managementUrl          = "https://$FunctionAppName.azurewebsites.net/api/management/tag-policy"
        apiApplicationIdUri    = $apiApplicationIdUri
        tenantId               = $TenantId
        subscriptionId         = $SubscriptionId
        resourceGroupName      = $ResourceGroupName
        functionAppName        = $FunctionAppName
        webUrl                 = "https://$FunctionAppName.azurewebsites.net/api/ui/index.html"
    } | ConvertTo-Json | Set-Content `
        -LiteralPath $settingsPath `
        -Encoding utf8NoBOM

    Write-Warning "Copy '$settingsPath' to '$PSScriptRoot\client.settings.json' so the AutopilotImport.Client module uses it by default."
    Get-Item -LiteralPath $settingsPath
}

function Import-AutoPilotDevice {
    <#
    .SYNOPSIS
    Imports Windows Autopilot devices from a CSV through the secured Function.

    .DESCRIPTION
    Validates an Autopilot hardware-hash CSV and submits one authenticated API
    request per device. Deployment settings are read from client.settings.json
    unless explicit connection parameters override them. ValidateOnly performs
    all local CSV checks without signing in or calling the service.

    .PARAMETER CsvPath
    Path to a non-empty CSV containing Device Serial Number and Hardware Hash
    columns. Each hardware hash must be valid, non-empty Base64.

    .PARAMETER GroupTag
    Group Tag requested for every device in the CSV.

    .PARAMETER FunctionUrl
    HTTPS URL of the Autopilot import Function endpoint. Overrides functionUrl
    from client.settings.json.

    .PARAMETER ApiApplicationIdUri
    Application ID URI exposed by the secured Function API, beginning with
    api://. Overrides apiApplicationIdUri from client.settings.json.

    .PARAMETER TenantId
    Microsoft Entra tenant ID used to acquire the API access token. Overrides
    tenantId from client.settings.json.

    .PARAMETER ConfigPath
    Optional path to client.settings.json. The persisted user configuration is
    used when this parameter is omitted.

    .PARAMETER ValidateOnly
    Validates the CSV without authentication or API calls.

    .EXAMPLE
    Import-AutoPilotDevice `
        -CsvPath '.\AutopilotHWID.csv' `
        -GroupTag 'Shared'

    Validates and imports every device using the installed client settings.

    .EXAMPLE
    Import-AutoPilotDevice `
        -CsvPath '.\AutopilotHWID.csv' `
        -GroupTag 'Shared' `
        -ValidateOnly

    Validates the CSV and returns a summary without authenticating or importing.

    .EXAMPLE
    Import-AutoPilotDevice `
        -CsvPath '.\AutopilotHWID.csv' `
        -GroupTag 'Shared' `
        -WhatIf

    Validates the CSV and previews the import without authenticating or
    submitting devices.

    .INPUTS
    None. This command does not accept pipeline input.

    .OUTPUTS
    PSCustomObject validation summary when ValidateOnly is set. Otherwise,
    returns one enriched service response per submitted device.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'None')]
    param(
        [Parameter(Mandatory)]
        [string] $CsvPath,
        [Parameter(Mandatory)]
        [ValidateLength(1, 128)]
        [string] $GroupTag,
        [ValidatePattern('^https://')]
        [string] $FunctionUrl,
        [ValidatePattern('^api://')]
        [string] $ApiApplicationIdUri,
        [string] $TenantId,
        [string] $ConfigPath,
        [switch] $ValidateOnly
    )

    if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
        throw "The Autopilot CSV file '$CsvPath' does not exist or is not a file. Verify the path and try again."
    }
    $csvFile = Get-Item -LiteralPath $CsvPath
    if ($csvFile.Length -eq 0) {
        throw "The Autopilot CSV file '$($csvFile.FullName)' is empty. Export the device data again and try again."
    }

    $configuration = Resolve-ClientConfiguration -ConfigPath $ConfigPath -Overrides @{
        functionUrl = $FunctionUrl
        apiApplicationIdUri = $ApiApplicationIdUri
        tenantId = $TenantId
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

    # Materialize and validate every row before authentication or network I/O,
    # preventing a partially submitted batch when a later row is malformed.
    $devices = for ($rowIndex = 0; $rowIndex -lt $rows.Count; $rowIndex++) {
        $serialNumber = [string] $rows[$rowIndex].'Device Serial Number'
        $hardwareIdentifier = [string] $rows[$rowIndex].'Hardware Hash'
        if ([string]::IsNullOrWhiteSpace($serialNumber)) {
            throw "CSV row $($rowIndex + 2) does not contain a Device Serial Number."
        }
        if ([string]::IsNullOrWhiteSpace($hardwareIdentifier)) {
            throw "CSV row $($rowIndex + 2) does not contain a Hardware Hash."
        }
        try { $hashBytes = [Convert]::FromBase64String($hardwareIdentifier) }
        catch { throw "CSV row $($rowIndex + 2) contains an invalid Base64 Hardware Hash." }
        if ($hashBytes.Length -eq 0) {
            throw "CSV row $($rowIndex + 2) contains an empty Hardware Hash."
        }
        [pscustomobject]@{
            serialNumber = $serialNumber.Trim()
            hardwareIdentifier = $hardwareIdentifier
        }
    }

    if ($ValidateOnly) {
        return [pscustomobject]@{
            CsvPath = (Resolve-Path -LiteralPath $CsvPath).Path
            DeviceCount = $devices.Count
            GroupTag = $GroupTag
            FunctionUrl = [string] $configuration.functionUrl
            ApiApplicationIdUri = [string] $configuration.apiApplicationIdUri
            TenantId = [string] $configuration.tenantId
            ClientSettingsPath = if (Test-Path $configuration.ConfigPath) {
                (Resolve-Path $configuration.ConfigPath).Path
            } else { $null }
            IsValid = $true
        }
    }

    if (-not $PSCmdlet.ShouldProcess(
            "$($devices.Count) device(s) from '$($csvFile.FullName)'",
            "Import with Group Tag '$GroupTag'")) {
        return
    }

    $resolvedFunctionUrl = Get-ConfigurationValue $configuration functionUrl 'FunctionUrl'
    $audience = Get-ConfigurationValue $configuration apiApplicationIdUri 'ApiApplicationIdUri'
    $resolvedTenantId = Get-ConfigurationValue $configuration tenantId 'TenantId'
    $parsedTenantId = [guid]::Empty
    if (-not [guid]::TryParse($resolvedTenantId, [ref] $parsedTenantId)) {
        throw 'TenantId must be a GUID.'
    }
    $token = Get-ClientAccessToken -TenantId $resolvedTenantId -ResourceUrl $audience

    foreach ($device in $devices) {
        $body = @{
            serialNumber = $device.serialNumber
            hardwareIdentifier = $device.hardwareIdentifier
            groupTag = $GroupTag
        } | ConvertTo-Json -Compress
        try {
            $response = Invoke-RestMethod -Method Post -Uri $resolvedFunctionUrl.TrimEnd('/') `
                -Authentication Bearer -Token $token -ContentType 'application/json' `
                -Body $body -ErrorAction Stop
            Add-ClientImportMetadata -ImportResponse $response
        }
        catch {
            throw (Get-ClientApiErrorMessage `
                    -ErrorRecord $_ `
                    -SerialNumber $device.serialNumber `
                    -GroupTag $GroupTag)
        }
    }
}

function Get-AutoPilotImportStatus {
    <#
    .SYNOPSIS
    Returns the current Intune processing status of an Autopilot import.

    .DESCRIPTION
    Calls the secured import endpoint with an import ID and enriches the service
    response with statusDescription and isFinal. With Wait, the command polls
    until the import and extension-attribute processing reaches a final state or
    the timeout expires.

    .PARAMETER ImportId
    Import identifier returned by Import-AutoPilotDevice.

    .PARAMETER FunctionUrl
    HTTPS URL of the Autopilot import Function endpoint. Overrides functionUrl
    from client.settings.json.

    .PARAMETER ApiApplicationIdUri
    Application ID URI exposed by the secured Function API. Overrides the
    configured apiApplicationIdUri value.

    .PARAMETER TenantId
    Microsoft Entra tenant ID used to acquire an API token.

    .PARAMETER ConfigPath
    Optional path to client.settings.json.

    .PARAMETER Wait
    Polls until the result is final or TimeoutSeconds expires.

    .PARAMETER PollIntervalSeconds
    Seconds between requests when Wait is specified. The default is 15.

    .PARAMETER TimeoutSeconds
    Maximum wait time in seconds. The default is 1800 (30 minutes).

    .EXAMPLE
    Get-AutoPilotImportStatus `
        -ImportId '11111111-1111-1111-1111-111111111111'

    Returns the current status without waiting.

    .EXAMPLE
    Get-AutoPilotImportStatus `
        -ImportId '11111111-1111-1111-1111-111111111111' `
        -Wait `
        -PollIntervalSeconds 30 `
        -TimeoutSeconds 1800

    Polls every 30 seconds for up to 30 minutes.

    .INPUTS
    None. This command does not accept pipeline input.

    .OUTPUTS
    PSCustomObject containing the service status, statusDescription, and isFinal.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid] $ImportId,
        [ValidatePattern('^https://')][string] $FunctionUrl,
        [ValidatePattern('^api://')][string] $ApiApplicationIdUri,
        [string] $TenantId,
        [string] $ConfigPath,
        [switch] $Wait,
        [ValidateRange(1, 300)][int] $PollIntervalSeconds = 15,
        [ValidateRange(1, 86400)][int] $TimeoutSeconds = 1800
    )

    $configuration = Resolve-ClientConfiguration $ConfigPath @{
        functionUrl = $FunctionUrl
        apiApplicationIdUri = $ApiApplicationIdUri
        tenantId = $TenantId
    }
    $url = Get-ConfigurationValue $configuration functionUrl 'FunctionUrl'
    $audience = Get-ConfigurationValue $configuration apiApplicationIdUri 'ApiApplicationIdUri'
    $resolvedTenantId = Get-ConfigurationValue $configuration tenantId 'TenantId'
    $token = Get-ClientAccessToken $resolvedTenantId $audience
    $statusUrl = "$($url.TrimEnd('/'))?importId=$ImportId"

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            $result = Invoke-RestMethod `
                -Method Get `
                -Uri $statusUrl `
                -Authentication Bearer `
                -Token $token `
                -ErrorAction Stop
        }
        catch {
            $response = $null
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                try { $response = $_.ErrorDetails.Message | ConvertFrom-Json }
                catch { $response = $null }
            }
            $message = "Could not retrieve Autopilot import '$ImportId'."
            if ($response -and $response.PSObject.Properties['error']) {
                $message += " Service error: $($response.error)."
            }
            else {
                $message += " $($_.Exception.Message)"
            }
            if ($response -and $response.PSObject.Properties['correlationId']) {
                $message += " Correlation ID: $($response.correlationId)."
            }
            throw $message
        }

        $result = Add-ClientImportStatusMetadata -ImportStatus $result
        if (-not $Wait -or $result.isFinal) {
            return $result
        }
        # Include the next sleep interval so polling never intentionally waits
        # beyond the caller's timeout.
        if ($stopwatch.Elapsed.TotalSeconds + $PollIntervalSeconds -gt $TimeoutSeconds) {
            throw "Autopilot import '$ImportId' did not reach a final state within $TimeoutSeconds seconds. Last status: $($result.status)."
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    } while ($true)
}

function Get-ClientDeviceHashSha256 {
    param(
        [Parameter(Mandatory)]
        [ValidateLength(1, 65536)]
        [string] $DeviceHash
    )

    try {
        $deviceHashBytes = [Convert]::FromBase64String($DeviceHash)
    }
    catch {
        throw 'DeviceHash must be the Base64 Hardware Hash from the Autopilot CSV. To search by the displayed device serial number, use -SerialNumber.'
    }
    if ($deviceHashBytes.Length -eq 0) {
        throw 'DeviceHash must not be empty.'
    }
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($deviceHashBytes)
    ).ToLowerInvariant()
}

function Get-AutoPilotImportHistory {
    <#
    .SYNOPSIS
    Returns Autopilot import operations visible to the current user.

    .DESCRIPTION
    Returns imports requested by the signed-in user during the last 30 days.
    ImportId, SerialNumber, and DeviceHash can retrieve specific records,
    including who requested them. User filters and ShowAll require the caller
    to be allowed by the manager policy or have an enabled Intune Role
    Administrator assignment.

    Existing client configurations remain supported: when ImportHistoryUrl is
    omitted, the endpoint is derived from managementUrl.

    .PARAMETER Top
    Maximum number of import operations to return. The default is 100 and the
    supported range is 1 through 1000.

    .PARAMETER ImportId
    One or more import IDs to retrieve regardless of who requested them.

    .PARAMETER SerialNumber
    One or more Autopilot device serial numbers to retrieve regardless of who
    requested them. This is the first positional parameter.

    .PARAMETER User
    One or more user principal names whose imports should be retrieved. This
    filter is restricted to importer managers.

    .PARAMETER DeviceHash
    One or more Base64 Autopilot device hashes to retrieve. The command sends
    only locally computed SHA-256 indexes to the history endpoint.

    .PARAMETER ShowAll
    Returns all retained imports. This switch is restricted to importer
    managers and cannot be combined with ImportId, SerialNumber, DeviceHash,
    or User.

    .PARAMETER ImportHistoryUrl
    HTTPS URL of the import history management endpoint. Overrides the URL
    derived from managementUrl in client.settings.json.

    .PARAMETER ApiApplicationIdUri
    Application ID URI exposed by the secured Function API.

    .PARAMETER TenantId
    Microsoft Entra tenant ID used to acquire an API token.

    .PARAMETER ConfigPath
    Optional path to client.settings.json.

    .PARAMETER Raw
    Returns the unchanged response envelope, including count and correlationId.

    .EXAMPLE
    Get-AutoPilotImportHistory

    Returns up to 100 import operations using client.settings.json.

    .EXAMPLE
    Get-AutoPilotImportHistory -Top 500 |
        Where-Object Status -eq 'error'

    Returns failed operations requested by the signed-in user.

    .EXAMPLE
    Get-AutoPilotImportHistory `
        -ImportId '11111111-1111-1111-1111-111111111111'

    Returns the specified import and the user who requested it.

    .EXAMPLE
    Get-AutoPilotImportHistory `
        -SerialNumber '7892-5288-2670-2860-4823-9507-73'

    Returns imports for the specified Autopilot device serial number.

    .EXAMPLE
    Get-AutoPilotImportHistory '7892-5288-2670-2860-4823-9507-73'

    Returns imports using the serial number as a positional argument.

    .EXAMPLE
    Get-AutoPilotImportHistory -User 'aa@bloedgelaber.de'

    Returns imports requested by the specified user principal name.

    .EXAMPLE
    Get-AutoPilotImportHistory -ShowAll

    Returns all imports retained for 30 days when the caller is an importer
    manager.

    .OUTPUTS
    PSCustomObject import records. With Raw, returns the unchanged API response.
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 1000)]
        [int] $Top = 100,

        [ValidateCount(1, 50)]
        [guid[]] $ImportId,

        [Parameter(Position = 0)]
        [ValidateCount(1, 50)]
        [string[]] $SerialNumber,

        [ValidateCount(1, 50)]
        [string[]] $DeviceHash,

        [ValidateCount(1, 50)]
        [string[]] $User,

        [switch] $ShowAll,

        [ValidatePattern('^https://')]
        [string] $ImportHistoryUrl,

        [ValidatePattern('^api://')]
        [string] $ApiApplicationIdUri,

        [string] $TenantId,

        [string] $ConfigPath,

        [switch] $Raw
    )

    $configuration = Resolve-ClientConfiguration $ConfigPath @{
        importHistoryUrl = $ImportHistoryUrl
        apiApplicationIdUri = $ApiApplicationIdUri
        tenantId = $TenantId
    }
    $url = if ($configuration.ContainsKey('importHistoryUrl') -and
        -not [string]::IsNullOrWhiteSpace(
            [string] $configuration.importHistoryUrl)) {
        [string] $configuration.importHistoryUrl
    }
    else {
        $managementUrl = Get-ConfigurationValue `
            $configuration `
            managementUrl `
            'ManagementUrl'
        if ($managementUrl -notmatch '/tag-policy/?$') {
            throw "ImportHistoryUrl cannot be derived from managementUrl '$managementUrl'. Provide -ImportHistoryUrl."
        }
        $managementUrl -replace '/tag-policy/?$', '/imports'
    }
    $audience = Get-ConfigurationValue `
        $configuration `
        apiApplicationIdUri `
        'ApiApplicationIdUri'
    $resolvedTenantId = Get-ConfigurationValue `
        $configuration `
        tenantId `
        'TenantId'
    try {
        $token = Get-ClientAccessToken $resolvedTenantId $audience
    }
    catch {
        throw 'Authentication for the Autopilot import history failed. Run Connect-AzAccount and retry.'
    }
    [guid[]] $requestedImportIds = @()
    if ($PSBoundParameters.ContainsKey('ImportId')) {
        $requestedImportIds = @($ImportId)
    }
    [string[]] $requestedSerialNumbers = @()
    if ($PSBoundParameters.ContainsKey('SerialNumber')) {
        $requestedSerialNumbers = @($SerialNumber | ForEach-Object {
            ([string] $_).Trim()
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique)
        if ($requestedSerialNumbers.Count -ne $SerialNumber.Count) {
            throw 'SerialNumber values must not be empty.'
        }
    }
    [string[]] $requestedUsers = @()
    if ($PSBoundParameters.ContainsKey('User')) {
        $requestedUsers = @($User | ForEach-Object {
            ([string] $_).Trim()
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique)
        if ($requestedUsers.Count -ne $User.Count) {
            throw 'User values must not be empty.'
        }
    }
    [string[]] $requestedDeviceHashes = @()
    if ($PSBoundParameters.ContainsKey('DeviceHash')) {
        $requestedDeviceHashes = @($DeviceHash)
    }
    $hasExplicitFilter = $requestedImportIds.Count -gt 0 -or
        $requestedSerialNumbers.Count -gt 0 -or
        $requestedUsers.Count -gt 0 -or
        $requestedDeviceHashes.Count -gt 0
    if ($ShowAll -and $hasExplicitFilter) {
        throw 'ShowAll cannot be combined with ImportId, SerialNumber, DeviceHash, or User.'
    }
    if ($requestedImportIds.Count + $requestedSerialNumbers.Count +
        $requestedDeviceHashes.Count + $requestedUsers.Count -gt 50) {
        throw 'At most 50 ImportId, SerialNumber, DeviceHash, and User values may be requested.'
    }
    $requestUrl = "$($url.TrimEnd('/'))?top=$Top"
    if ($ShowAll) {
        $requestUrl += '&showAll=true'
    }
    $requestParameters = @{
        Method = if ($hasExplicitFilter) { 'Post' } else { 'Get' }
        Uri = $requestUrl
        Authentication = 'Bearer'
        Token = $token
        ErrorAction = 'Stop'
    }
    if ($hasExplicitFilter) {
        $requestParameters.ContentType = 'application/json'
        $requestParameters.Body = @{
            importIds = @($requestedImportIds | ForEach-Object { $_.ToString() })
            serialNumbers = @($requestedSerialNumbers)
            users = @($requestedUsers)
            deviceHashSha256 = @($requestedDeviceHashes | ForEach-Object {
                Get-ClientDeviceHashSha256 -DeviceHash $_
            })
        } | ConvertTo-Json -Compress
    }

    try {
        $response = Invoke-RestMethod @requestParameters
    }
    catch {
        $requestError = $_
        $serviceResponse = $null
        if ($requestError.ErrorDetails -and
            $requestError.ErrorDetails.Message) {
            try {
                $serviceResponse = $requestError.ErrorDetails.Message |
                    ConvertFrom-Json
            }
            catch {
                $serviceResponse = $null
            }
        }
        $statusCode = $null
        if ($requestError.Exception.PSObject.Properties['Response'] -and
            $requestError.Exception.Response -and
            $requestError.Exception.Response.PSObject.Properties['StatusCode']) {
            $statusCode = [int] $requestError.Exception.Response.StatusCode
        }
        elseif ($requestError.Exception.Data.Contains('StatusCode')) {
            $statusCode = [int] $requestError.Exception.Data['StatusCode']
        }

        $serviceError = if ($serviceResponse -and
            $serviceResponse.PSObject.Properties['error']) {
            [string] $serviceResponse.error
        }
        else {
            ''
        }
        $message = switch ($statusCode) {
            401 {
                'Authentication for the Autopilot import history failed. Sign in again and retry.'
            }
            403 {
                'The signed-in user is not authorized to view the requested import history. User filters and ShowAll require the importer-manager policy or the Intune Role Administrator role.'
            }
            404 {
                "The Autopilot import history endpoint was not found at '$requestUrl'. The deployed Function App is probably older than the installed client module or was published without GetImportHistory. Run Update-AutopilotImport.ps1 without -SkipPublish, then retry. If -ImportHistoryUrl was supplied, verify that it ends with '/api/management/imports'."
            }
            502 {
                'The Autopilot import service could not retrieve the history from Microsoft Graph. Retry later or ask an administrator to inspect the Function logs.'
            }
            default {
                if ($serviceError -eq 'serviceNotConfigured') {
                    'The Autopilot import history service is not configured correctly. Ask an administrator to verify the Function App settings.'
                }
                elseif ($serviceError -eq 'authorizationServiceUnavailable') {
                    'The authorization service is temporarily unavailable. Retry later.'
                }
                else {
                    "Could not retrieve the Autopilot import history. $($requestError.Exception.Message)"
                }
            }
        }
        if ($serviceResponse -and
            $serviceResponse.PSObject.Properties['correlationId']) {
            $message += " Correlation ID: $($serviceResponse.correlationId)."
        }
        throw $message
    }

    if ($Raw) {
        return $response
    }
    return @($response.imports | ForEach-Object {
        $importProperties = @{}
        foreach ($property in $_.PSObject.Properties) {
            $importProperties[$property.Name] = $property.Value
        }
        $auditTimestampNames = @(
            'requestReceivedAtUtc'
            'graphImportCreatedAtUtc'
            'queuedAtUtc'
            'processingStartedAtUtc'
            'entraDeviceResolvedAtUtc'
            'extensionAttributeUpdatedAtUtc'
            'administrativeUnitAssignedAtUtc'
            'processingCompletedAtUtc'
        )
        $auditTimestamps = @{}
        foreach ($timestampName in $auditTimestampNames) {
            $timestampValue = [string] $importProperties[$timestampName]
            $auditTimestamps[$timestampName] = if (
                [string]::IsNullOrWhiteSpace($timestampValue)) {
                $null
            }
            else {
                [datetimeoffset]::Parse(
                    $timestampValue,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind
                )
            }
        }
        $result = [pscustomobject][ordered]@{
            PSTypeName                       = 'AutopilotImport.ImportHistoryRecord'
            ImportId                         = [string] $importProperties['importId']
            BatchImportId                    = [string] $importProperties['batchImportId']
            SerialNumber                     = [string] $importProperties['serialNumber']
            GroupTag                         = [string] $importProperties['groupTag']
            Status                           = [string] $importProperties['status']
            DeviceHashSha256                 = [string] $importProperties['deviceHashSha256']
            DeviceErrorCode                  = $importProperties['deviceErrorCode']
            DeviceErrorName                  = [string] $importProperties['deviceErrorName']
            RequestedBy                      = [string] $importProperties['requestedBy']
            RequestedByObjectId              = [string] $importProperties['requestedByObjectId']
            RequestedByUserPrincipalName     = [string] $importProperties['requestedByUserPrincipalName']
            RequestedByDisplayName           = [string] $importProperties['requestedByDisplayName']
            RequestReceivedAtUtc              = $auditTimestamps['requestReceivedAtUtc']
            GraphImportCreatedAtUtc           = $auditTimestamps['graphImportCreatedAtUtc']
            QueuedAtUtc                       = $auditTimestamps['queuedAtUtc']
            ProcessingStartedAtUtc            = $auditTimestamps['processingStartedAtUtc']
            EntraDeviceResolvedAtUtc          = $auditTimestamps['entraDeviceResolvedAtUtc']
            ExtensionAttributeUpdatedAtUtc    = $auditTimestamps['extensionAttributeUpdatedAtUtc']
            AdministrativeUnitAssignedAtUtc   = $auditTimestamps['administrativeUnitAssignedAtUtc']
            ProcessingCompletedAtUtc          = $auditTimestamps['processingCompletedAtUtc']
        }
        $displayPropertySet = [Management.Automation.PSPropertySet]::new(
            'DefaultDisplayPropertySet',
            [string[]] @(
                'ImportId'
                'SerialNumber'
                'GroupTag'
                'Status'
                'RequestedBy'
                'RequestReceivedAtUtc'
                'ProcessingCompletedAtUtc'
                'DeviceErrorName'
            )
        )
        $result | Add-Member `
            -MemberType MemberSet `
            -Name PSStandardMembers `
            -Value ([Management.Automation.PSMemberInfo[]] @(
                $displayPropertySet))
        $result
    })
}

function ConvertTo-ClientTagPolicyResult {
    param(
        [Parameter(Mandatory)]
        [object] $Rule,

        [AllowNull()]
        [string] $GroupName,

        [AllowNull()]
        [string] $CorrelationId
    )

    $result = [pscustomobject][ordered]@{
        PSTypeName = 'AutopilotImport.TagPolicyRule'
        GroupId = [string] $Rule.groupId
        GroupName = $GroupName
        Tags = @($Rule.tags)
        AdministrativeUnitName = if (
            $Rule.PSObject.Properties[
                'administrativeUnitName']) {
            [string] $Rule.administrativeUnitName
        }
        else {
            $null
        }
        CorrelationId = $CorrelationId
    }
    $displayPropertySet = [Management.Automation.PSPropertySet]::new(
        'DefaultDisplayPropertySet',
        [string[]] @(
            'GroupId'
            'GroupName'
            'Tags'
            'AdministrativeUnitName'
        )
    )
    $result | Add-Member `
        -MemberType MemberSet `
        -Name PSStandardMembers `
        -Value ([Management.Automation.PSMemberInfo[]] @($displayPropertySet))
    return $result
}

function Get-AutoPilotTagPolicy {
    <#
    .SYNOPSIS
    Returns the current group-to-tag policy with Entra group display names.

    .DESCRIPTION
    Retrieves the current policy and resolves each group object ID through
    Microsoft Graph. Each rule is returned as a PowerShell object with stable
    GroupId, GroupName, Tags, AdministrativeUnitName, and
    CorrelationId properties.

    .PARAMETER Raw
    Returns the unchanged response from the management API without resolving
    group display names. Use this switch for automation that relies on the
    response envelope and its policy property.

    .PARAMETER ManagementUrl
    HTTPS URL of the Group Tag policy management endpoint. Overrides
    managementUrl from client.settings.json.

    .PARAMETER ApiApplicationIdUri
    Application ID URI exposed by the secured Function API.

    .PARAMETER TenantId
    Microsoft Entra tenant ID used for API and Microsoft Graph authentication.

    .PARAMETER ConfigPath
    Optional path to client.settings.json.

    .EXAMPLE
    Get-AutoPilotTagPolicy

    Returns policy rules with Entra group display names.

    .EXAMPLE
    $response = Get-AutoPilotTagPolicy -Raw
    $response.policy

    Returns the unchanged API response for automation.

    .INPUTS
    None. This command does not accept pipeline input.

    .OUTPUTS
    AutopilotImport.TagPolicyRule objects. With Raw, returns the unchanged
    management API response.
    #>
    [CmdletBinding()]
    param(
        [ValidatePattern('^https://')][string] $ManagementUrl,
        [ValidatePattern('^api://')][string] $ApiApplicationIdUri,
        [string] $TenantId,
        [string] $ConfigPath,
        [switch] $Raw
    )

    $configuration = Resolve-ClientConfiguration $ConfigPath @{
        managementUrl = $ManagementUrl; apiApplicationIdUri = $ApiApplicationIdUri; tenantId = $TenantId
    }
    $url = Get-ConfigurationValue $configuration managementUrl 'ManagementUrl'
    $audience = Get-ConfigurationValue $configuration apiApplicationIdUri 'ApiApplicationIdUri'
    $resolvedTenantId = Get-ConfigurationValue $configuration tenantId 'TenantId'
    $token = Get-ClientAccessToken $resolvedTenantId $audience
    $response = Invoke-RestMethod -Method Get -Uri $url.TrimEnd('/') `
        -Authentication Bearer -Token $token
    if ($Raw) {
        return $response
    }

    $policy = @($response.policy)
    if ($policy.Count -eq 0) {
        return
    }

    # The Function API returns object IDs; a separate Graph token is required
    # only to enrich the human-facing output with group display names.
    $graphToken = Get-ClientAccessToken `
        $resolvedTenantId `
        'https://graph.microsoft.com/'
    foreach ($rule in $policy) {
        $groupId = [string] $rule.groupId
        try {
            $escapedGroupId = [uri]::EscapeDataString($groupId)
            $group = Invoke-RestMethod `
                -Method Get `
                -Uri "https://graph.microsoft.com/v1.0/groups/${escapedGroupId}?`$select=id,displayName" `
                -Authentication Bearer `
                -Token $graphToken `
                -ErrorAction Stop
            $groupName = [string] $group.displayName
            if ([string]::IsNullOrWhiteSpace($groupName)) {
                throw 'Microsoft Graph returned an empty display name.'
            }
        }
        catch {
            Write-Warning "Could not resolve Entra group '$groupId': $($_.Exception.Message)"
            $groupName = '[Unresolved group]'
        }

        ConvertTo-ClientTagPolicyResult `
            -Rule $rule `
            -GroupName $groupName `
            -CorrelationId $(if ($response.PSObject.Properties['correlationId']) {
                [string] $response.correlationId
            })
    }
}

function Add-AutoPilotTagPolicy {
    <#
    .SYNOPSIS
    Adds an Entra group and its allowed Group Tags to the policy.

    .DESCRIPTION
    Accepts an Entra group object ID. Existing rules are preserved and tags
    for an existing group are merged. When no administrative unit is
    specified, that rule's current MAU or RMAU is preserved.

    .PARAMETER GroupId
    Entra group object ID. Group is retained as an alias for compatibility.

    .PARAMETER GroupTag
    One or more allowed Autopilot Group Tags for the group. Supply multiple
    values as an array or as a comma-separated string.

    .PARAMETER AdministrativeUnitName
    Optional display name of a regular or restricted management administrative
    unit. The value applies only to the added or updated group rule. If
    omitted, an existing value for that rule is retained; a new rule has no
    administrative unit. Supply an empty string to remove the unit assignment.
    Mau is a short alias for AdministrativeUnitName.

    .PARAMETER ManagementUrl
    HTTPS URL of the Group Tag policy management endpoint.

    .PARAMETER ApiApplicationIdUri
    Application ID URI exposed by the secured Function API.

    .PARAMETER TenantId
    Microsoft Entra tenant ID used for API authentication.

    .PARAMETER ConfigPath
    Optional path to client.settings.json.

    .EXAMPLE
    Add-AutoPilotTagPolicy `
        -GroupId '11111111-1111-1111-1111-111111111111' `
        -GroupTag 'Shared', 'Kiosk'

    Adds two allowed Group Tags to the Entra group.

    .EXAMPLE
    Add-AutoPilotTagPolicy `
        -GroupId '11111111-1111-1111-1111-111111111111' `
        -GroupTag 'BG-Default, PAW, PAW-CSM'

    Adds three comma-separated Group Tags to the Entra group.

    .EXAMPLE
    Add-AutoPilotTagPolicy `
        -GroupId '11111111-1111-1111-1111-111111111111' `
        -GroupTag 'Shared' `
        -AdministrativeUnitName 'Autopilot Devices' `
        -WhatIf

    Previews a policy update by group object ID and an associated restricted MAU.

    .INPUTS
    None. This command does not accept pipeline input.

    .OUTPUTS
    AutopilotImport.TagPolicyRule object for the added or updated group rule.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'None')]
    param(
        [Parameter(Mandatory)]
        [Alias('Group')]
        [guid] $GroupId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Alias('Tag')]
        [string[]] $GroupTag,

        [Alias('Mau')]
        [AllowEmptyString()]
        [ValidateLength(0, 256)]
        [string] $AdministrativeUnitName,

        [ValidatePattern('^https://')][string] $ManagementUrl,
        [ValidatePattern('^api://')][string] $ApiApplicationIdUri,
        [string] $TenantId,
        [string] $ConfigPath
    )

    $tags = @($GroupTag | ForEach-Object { $_.Split(',') } |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique)
    if ($tags.Count -eq 0) {
        throw 'Specify at least one Group Tag.'
    }
    foreach ($tag in $tags) {
        if ($tag.Length -gt 128) {
            throw "Group Tag '$tag' must not exceed 128 characters."
        }
    }

    $configuration = Resolve-ClientConfiguration $ConfigPath @{
        managementUrl = $ManagementUrl
        apiApplicationIdUri = $ApiApplicationIdUri
        tenantId = $TenantId
    }
    $url = Get-ConfigurationValue $configuration managementUrl 'ManagementUrl'
    $audience = Get-ConfigurationValue $configuration apiApplicationIdUri 'ApiApplicationIdUri'
    $resolvedTenantId = Get-ConfigurationValue $configuration tenantId 'TenantId'
    $apiToken = Get-ClientAccessToken $resolvedTenantId $audience

    $resolvedGroupId = $GroupId.ToString()

    $currentResponse = Invoke-RestMethod `
        -Method Get `
        -Uri $url.TrimEnd('/') `
        -Authentication Bearer `
        -Token $apiToken `
        -ErrorAction Stop
    $currentPolicy = @($currentResponse.policy)
    # Index the current rules by normalized group ID to merge tags without
    # discarding unrelated groups or their individual RMAU assignments.
    $rulesByGroup = [ordered]@{}
    $mauByGroup = @{}
    foreach ($rule in $currentPolicy) {
        $currentGroupId = ([guid] $rule.groupId).ToString()
        $rulesByGroup[$currentGroupId] = @($rule.tags)
        $mauByGroup[$currentGroupId] = if ($rule.PSObject.Properties[
                'administrativeUnitName']) {
            [string] $rule.administrativeUnitName
        }
        else {
            ''
        }
    }
    $rulesByGroup[$resolvedGroupId] = @(
        @($rulesByGroup[$resolvedGroupId]) + $tags |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) } |
            Select-Object -Unique
    )

    if ($PSBoundParameters.ContainsKey(
            'AdministrativeUnitName')) {
        $mauByGroup[$resolvedGroupId] =
            $AdministrativeUnitName.Trim()
    }
    $updatedPolicy = @($rulesByGroup.Keys | ForEach-Object {
        $policyEntry = [ordered]@{
            groupId = $_
            tags = @($rulesByGroup[$_])
        }
        if (-not [string]::IsNullOrWhiteSpace($mauByGroup[$_])) {
            $policyEntry.administrativeUnitName =
                $mauByGroup[$_].Trim()
        }
        [pscustomobject] $policyEntry
    })
    $body = @{
        policy = $updatedPolicy
    } | ConvertTo-Json -Depth 4 -Compress

    if (-not $PSCmdlet.ShouldProcess(
            $resolvedGroupId,
            "Add Group Tags '$($tags -join ', ')' to the Autopilot policy")) {
        return
    }

    $response = Invoke-RestMethod `
        -Method Put `
        -Uri $url.TrimEnd('/') `
        -Authentication Bearer `
        -Token $apiToken `
        -ContentType 'application/json' `
        -Body $body `
        -ErrorAction Stop
    $responsePolicy = if ($response.PSObject.Properties['policy']) {
        @($response.policy)
    }
    else {
        $updatedPolicy
    }
    $updatedRule = @($responsePolicy | Where-Object {
        ([guid] $_.groupId).ToString() -eq $resolvedGroupId
    }) | Select-Object -First 1
    ConvertTo-ClientTagPolicyResult `
        -Rule $updatedRule `
        -CorrelationId $(if ($response.PSObject.Properties['correlationId']) {
            [string] $response.correlationId
        })
}

function Remove-AutoPilotTagPolicy {
    <#
    .SYNOPSIS
    Removes Group Tags or an Entra group from the Group Tag policy.

    .DESCRIPTION
    Accepts either an Entra group object ID or an exact group display name.
    When GroupTag is specified, only those tags are removed from the selected
    group's rule. Without GroupTag, the selected group's complete rule is
    removed. All other rules and the currently configured restricted
    management administrative unit are preserved.

    .PARAMETER Group
    Entra group object ID or exact display name. If multiple groups have the
    same display name, use the object ID to select one unambiguously.

    .PARAMETER GroupTag
    Optional Autopilot Group Tags to remove from the selected group's rule.
    Supply multiple values as an array or as a comma-separated string. Omit
    this parameter to remove the complete rule.

    .PARAMETER ManagementUrl
    HTTPS URL of the Group Tag policy management endpoint.

    .PARAMETER ApiApplicationIdUri
    Application ID URI exposed by the secured Function API.

    .PARAMETER TenantId
    Microsoft Entra tenant ID used for API and group-name resolution.

    .PARAMETER ConfigPath
    Optional path to client.settings.json.

    .EXAMPLE
    Remove-AutoPilotTagPolicy `
        -Group 'Autopilot Operators' `
        -GroupTag 'Kiosk'

    Removes one Group Tag while preserving the group's other tags.

    .EXAMPLE
    Remove-AutoPilotTagPolicy `
        -Group '11111111-1111-1111-1111-111111111111' `
        -WhatIf

    Previews removal of the complete policy rule for the group.

    .INPUTS
    None. This command does not accept pipeline input.

    .OUTPUTS
    System.String success message with GroupId, GroupName, RemovedTags,
    RuleRemoved, CorrelationId, Updated, and ApiResponse metadata.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'None')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Alias('GroupId', 'GroupName')]
        [string] $Group,

        [ValidateNotNullOrEmpty()]
        [Alias('Tag')]
        [string[]] $GroupTag,

        [ValidatePattern('^https://')][string] $ManagementUrl,
        [ValidatePattern('^api://')][string] $ApiApplicationIdUri,
        [string] $TenantId,
        [string] $ConfigPath
    )

    $configuration = Resolve-ClientConfiguration $ConfigPath @{
        managementUrl = $ManagementUrl
        apiApplicationIdUri = $ApiApplicationIdUri
        tenantId = $TenantId
    }
    $url = Get-ConfigurationValue $configuration managementUrl 'ManagementUrl'
    $audience = Get-ConfigurationValue $configuration apiApplicationIdUri 'ApiApplicationIdUri'
    $resolvedTenantId = Get-ConfigurationValue $configuration tenantId 'TenantId'
    $apiToken = Get-ClientAccessToken $resolvedTenantId $audience

    $parsedGroupId = [guid]::Empty
    $groupDisplayName = $null
    if ([guid]::TryParse($Group.Trim(), [ref] $parsedGroupId)) {
        $resolvedGroupId = $parsedGroupId.ToString()
    }
    else {
        $graphToken = Get-ClientAccessToken `
            $resolvedTenantId `
            'https://graph.microsoft.com/'
        $escapedName = $Group.Trim().Replace("'", "''")
        $filter = [uri]::EscapeDataString("displayName eq '$escapedName'")
        $groupResponse = Invoke-RestMethod `
            -Method Get `
            -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$filter&`$select=id,displayName" `
            -Authentication Bearer `
            -Token $graphToken `
            -ErrorAction Stop
        $matchingGroups = @($groupResponse.value)
        if ($matchingGroups.Count -eq 0) {
            throw "Entra group '$Group' was not found. Specify its exact display name or object ID."
        }
        if ($matchingGroups.Count -gt 1) {
            throw "Multiple Entra groups are named '$Group'. Specify the group object ID instead."
        }
        $resolvedGroupId = ([guid] $matchingGroups[0].id).ToString()
        $groupDisplayName = [string] $matchingGroups[0].displayName
    }

    $currentResponse = Invoke-RestMethod `
        -Method Get `
        -Uri $url.TrimEnd('/') `
        -Authentication Bearer `
        -Token $apiToken `
        -ErrorAction Stop
    $currentPolicy = @($currentResponse.policy)
    $matchingRule = @($currentPolicy | Where-Object {
        ([guid] $_.groupId).ToString() -eq $resolvedGroupId
    })
    if ($matchingRule.Count -eq 0) {
        throw "Entra group '$Group' does not have a Group Tag policy rule."
    }

    # Supplying GroupTag means a partial update; omitting it removes the entire
    # group rule while still preserving every unrelated rule.
    $removeTags = @()
    if ($PSBoundParameters.ContainsKey('GroupTag')) {
        $removeTags = @($GroupTag | ForEach-Object { $_.Split(',') } |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique)
        if ($removeTags.Count -eq 0) {
            throw 'Specify at least one Group Tag to remove.'
        }
        foreach ($tag in $removeTags) {
            if ($tag.Length -gt 128) {
                throw "Group Tag '$tag' must not exceed 128 characters."
            }
        }

        $currentTags = @($matchingRule[0].tags | ForEach-Object {
            ([string] $_).Trim()
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique)
        $unknownTags = @($removeTags | Where-Object { $_ -notin $currentTags })
        if ($unknownTags.Count -gt 0) {
            throw "Group '$Group' does not contain Group Tag(s): $($unknownTags -join ', ')."
        }
        $remainingTags = @($currentTags | Where-Object {
            $_ -notin $removeTags
        })
        if ($remainingTags.Count -eq 0) {
            throw 'The last Group Tag cannot be removed from a policy rule. Omit -GroupTag to remove the complete group rule.'
        }

        $remainingPolicy = @($currentPolicy | ForEach-Object {
            $ruleGroupId = ([guid] $_.groupId).ToString()
            $ruleTags = if ($ruleGroupId -eq $resolvedGroupId) {
                $remainingTags
            }
            else {
                @($_.tags)
            }
            $policyEntry = [ordered]@{
                groupId = $ruleGroupId
                tags = @($ruleTags)
            }
            if ($_.PSObject.Properties[
                    'administrativeUnitName'] -and
                -not [string]::IsNullOrWhiteSpace(
                    [string] $_.administrativeUnitName)) {
                $policyEntry.administrativeUnitName =
                    ([string] $_.administrativeUnitName).Trim()
            }
            [pscustomobject] $policyEntry
        })
    }
    else {
        $remainingPolicy = @($currentPolicy | Where-Object {
            ([guid] $_.groupId).ToString() -ne $resolvedGroupId
        })
        if ($remainingPolicy.Count -eq 0) {
            throw 'The last Group Tag policy rule cannot be removed. Use Set-AutoPilotTagPolicy to replace the policy.'
        }
    }
    $body = @{
        policy = $remainingPolicy
    } | ConvertTo-Json -Depth 4 -Compress

    $target = if ([string]::IsNullOrWhiteSpace($groupDisplayName)) {
        $resolvedGroupId
    }
    else {
        "$groupDisplayName ($resolvedGroupId)"
    }
    $operation = if ($removeTags.Count -gt 0) {
        "Remove Group Tags '$($removeTags -join ', ')' from the Autopilot policy"
    }
    else {
        'Remove the group from the Autopilot Group Tag policy'
    }
    if (-not $PSCmdlet.ShouldProcess($target, $operation)) {
        return
    }

    $response = Invoke-RestMethod `
        -Method Put `
        -Uri $url.TrimEnd('/') `
        -Authentication Bearer `
        -Token $apiToken `
        -ContentType 'application/json' `
        -Body $body `
        -ErrorAction Stop

    $groupLabel = if ([string]::IsNullOrWhiteSpace($groupDisplayName)) {
        $resolvedGroupId
    }
    else {
        $groupDisplayName
    }
    $message = if ($removeTags.Count -eq 0) {
        "The tag policy for group '$groupLabel' was removed."
    }
    elseif ($removeTags.Count -eq 1) {
        "Group Tag '$($removeTags[0])' was removed from the tag policy for group '$groupLabel'."
    }
    else {
        "Group Tags '$($removeTags -join ', ')' were removed from the tag policy for group '$groupLabel'."
    }
    $message | Add-Member `
        -NotePropertyMembers @{
            GroupId      = $resolvedGroupId
            GroupName    = $groupDisplayName
            RemovedTags  = @($removeTags)
            RuleRemoved  = $removeTags.Count -eq 0
            CorrelationId = if ($response.PSObject.Properties['correlationId']) {
                [string] $response.correlationId
            }
            else {
                $null
            }
            Updated      = if ($response.PSObject.Properties['updated']) {
                [bool] $response.updated
            }
            else {
                $true
            }
            ApiResponse  = $response
        } `
        -PassThru
}

function Set-AutoPilotTagPolicy {
    <#
    .SYNOPSIS
    Replaces the complete group-to-tag policy.

    .DESCRIPTION
    Validates and replaces all Group Tag authorization rules through the secured
    management API. Every rule maps one Microsoft Entra group object ID to one
    or more permitted Autopilot Group Tags. Rules omitted from the supplied set
    are removed from the policy.

    .PARAMETER TagAuthorizationRule
    Complete policy as <group-object-id>=<tag1>,<tag2> strings or rule objects
    with groupId, tags, and an optional
    administrativeUnitName. Each group object ID must be a
    GUID and each rule must contain at least one Group Tag.

    .PARAMETER AdministrativeUnitName
    Optional fallback administrative unit applied to string rules. Rule
    objects can specify their own MAU or RMAU. Supply an empty string to
    disable automatic administrative-unit membership for string rules. Mau is
    a short alias for AdministrativeUnitName.

    .PARAMETER ManagementUrl
    HTTPS URL of the Group Tag policy management endpoint.

    .PARAMETER ApiApplicationIdUri
    Application ID URI exposed by the secured Function API.

    .PARAMETER TenantId
    Microsoft Entra tenant ID used to acquire the API token.

    .PARAMETER ConfigPath
    Optional path to client.settings.json. Values not supplied explicitly are
    read from this file.

    .EXAMPLE
    Set-AutoPilotTagPolicy `
        -TagAuthorizationRule @(
            [pscustomobject]@{
                groupId = '11111111-1111-1111-1111-111111111111'
                tags = @('Standard', 'Kiosk')
                administrativeUnitName = 'RMAU-Standard'
            }
            [pscustomobject]@{
                groupId = '22222222-2222-2222-2222-222222222222'
                tags = @('Engineering')
                administrativeUnitName = 'RMAU-Engineering'
            }
        ) `
        -WhatIf

    Previews a complete policy with an individual RMAU for each rule.

    .INPUTS
    None. This command does not accept pipeline input.

    .OUTPUTS
    PSCustomObject returned by the policy management API when the update runs.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'None')]
    param(
        [Parameter(Mandatory)][object[]] $TagAuthorizationRule,
        [Alias('Mau')]
        [string] $AdministrativeUnitName,
        [ValidatePattern('^https://')][string] $ManagementUrl,
        [ValidatePattern('^api://')][string] $ApiApplicationIdUri,
        [string] $TenantId,
        [string] $ConfigPath
    )

    $configuration = Resolve-ClientConfiguration $ConfigPath @{
        managementUrl = $ManagementUrl; apiApplicationIdUri = $ApiApplicationIdUri; tenantId = $TenantId
    }
    $url = Get-ConfigurationValue $configuration managementUrl 'ManagementUrl'
    # Reuse the runtime module's policy parser so client-side validation stays
    # identical to the Function's accepted rule format.
    $coreModulePath = Get-CoreModulePath
    Import-Module $coreModulePath -Force
    $policy = @(ConvertTo-TagAuthorizationPolicy `
        -Rules $TagAuthorizationRule `
        -AdministrativeUnitName `
            $AdministrativeUnitName)
    if (-not $PSCmdlet.ShouldProcess($url, "Replace tag authorization policy with $($policy.Count) group rule(s)")) {
        return
    }
    $audience = Get-ConfigurationValue $configuration apiApplicationIdUri 'ApiApplicationIdUri'
    $resolvedTenantId = Get-ConfigurationValue $configuration tenantId 'TenantId'
    $token = Get-ClientAccessToken $resolvedTenantId $audience
    $body = @{
        policy = $policy
    } | ConvertTo-Json -Depth 4 -Compress
    Invoke-RestMethod -Method Put -Uri $url.TrimEnd('/') -Authentication Bearer `
        -Token $token -ContentType 'application/json' -Body $body
}

function Get-AutoPilotTagPolicyManager {
    <#
    .SYNOPSIS
    Gets the explicitly configured Group Tag managers.

    .DESCRIPTION
    Reads MANAGER_AUTHORIZATION_POLICY from the configured Azure Function App
    and returns the installing manager and every additional manager as
    structured PowerShell objects. Values not supplied explicitly are resolved
    from client.settings.json.

    .PARAMETER SubscriptionId
    Azure subscription containing the Function App.

    .PARAMETER TenantId
    Microsoft Entra tenant used for Azure authentication.

    .PARAMETER ResourceGroupName
    Resource group containing the Function App.

    .PARAMETER FunctionAppName
    Name of the Autopilot Import Function App.

    .PARAMETER ConfigPath
    Optional path to client.settings.json.

    .EXAMPLE
    Get-AutoPilotTagPolicyManager

    Lists the configured managers using the installed client settings.

    .OUTPUTS
    PSCustomObject records containing FunctionAppName, PrincipalId, and
    ManagerType.
    #>
    [CmdletBinding()]
    param(
        [guid] $SubscriptionId,
        [guid] $TenantId,
        [string] $ResourceGroupName,
        [string] $FunctionAppName,
        [string] $ConfigPath
    )

    Assert-ClientCommand -Name 'Get-AzWebApp', 'Set-AzContext'
    $configuration = Resolve-ClientConfiguration $ConfigPath @{
        subscriptionId = $SubscriptionId; tenantId = $TenantId
        resourceGroupName = $ResourceGroupName; functionAppName = $FunctionAppName
    }
    $missingDeploymentValues = @(
        foreach ($entry in @(
                @{ Name = 'SubscriptionId'; Key = 'subscriptionId' }
                @{ Name = 'ResourceGroupName'; Key = 'resourceGroupName' }
                @{ Name = 'FunctionAppName'; Key = 'functionAppName' }
            )) {
            if ([string]::IsNullOrWhiteSpace(
                    [string] $configuration[$entry.Key])) {
                $entry.Name
            }
        }
    )
    if ($missingDeploymentValues.Count -gt 0) {
        $configuredFunctionUrl = [string] $configuration['functionUrl']
        $configuredTenantId = Get-ConfigurationValue `
            $configuration tenantId 'TenantId'
        if ([string]::IsNullOrWhiteSpace($configuredFunctionUrl)) {
            throw "Azure deployment details required by manager-policy commands are missing: $($missingDeploymentValues -join ', '). Pass -SubscriptionId, -ResourceGroupName, and -FunctionAppName explicitly."
        }
        $deployment = Resolve-ClientFunctionAppFromUrl `
            -FunctionUrl $configuredFunctionUrl `
            -TenantId $configuredTenantId `
            -SubscriptionId ([string] $configuration['subscriptionId'])
        $configuration['subscriptionId'] = $deployment.SubscriptionId
        $configuration['resourceGroupName'] = $deployment.ResourceGroupName
        $configuration['functionAppName'] = $deployment.FunctionAppName
        Save-ClientDeploymentConfiguration `
            -Configuration $configuration `
            -Deployment $deployment
    }

    $resolvedSubscriptionId = Get-ConfigurationValue `
        $configuration subscriptionId 'SubscriptionId'
    $resolvedTenantId = Get-ConfigurationValue `
        $configuration tenantId 'TenantId'
    $resolvedResourceGroup = Get-ConfigurationValue `
        $configuration resourceGroupName 'ResourceGroupName'
    $resolvedFunctionName = Get-ConfigurationValue `
        $configuration functionAppName 'FunctionAppName'

    [void](Get-ClientAccessToken `
        $resolvedTenantId `
        'https://management.azure.com/' `
        $resolvedSubscriptionId)
    Set-AzContext `
        -Tenant $resolvedTenantId `
        -Subscription $resolvedSubscriptionId `
        -WhatIf:$false | Out-Null
    $functionApp = Get-AzWebApp `
        -ResourceGroupName $resolvedResourceGroup `
        -Name $resolvedFunctionName
    if (-not $functionApp) {
        throw "Function App '$resolvedFunctionName' was not found."
    }

    $managerPolicySetting = @($functionApp.SiteConfig.AppSettings |
        Where-Object Name -eq 'MANAGER_AUTHORIZATION_POLICY' |
        Select-Object -First 1)
    if ($managerPolicySetting.Count -eq 0) {
        throw "Function App '$resolvedFunctionName' does not contain MANAGER_AUTHORIZATION_POLICY."
    }
    try {
        $managerPolicy = $managerPolicySetting[0].Value | ConvertFrom-Json
        $installerId = ([guid] $managerPolicy.installerPrincipalId).ToString()
        $additionalIds = @($managerPolicy.additionalPrincipalIds |
            Where-Object { $null -ne $_ } |
            ForEach-Object { ([guid] $_).ToString() })
    }
    catch {
        throw "The existing MANAGER_AUTHORIZATION_POLICY is invalid: $($_.Exception.Message)"
    }

    @(
        [pscustomobject]@{
            PSTypeName = 'AutopilotImport.TagPolicyManager'
            FunctionAppName = $resolvedFunctionName
            PrincipalId = $installerId
            ManagerType = 'Installer'
        }
        foreach ($principalId in $additionalIds) {
            [pscustomobject]@{
                PSTypeName = 'AutopilotImport.TagPolicyManager'
                FunctionAppName = $resolvedFunctionName
                PrincipalId = $principalId
                ManagerType = 'Additional'
            }
        }
    )
}

function Update-AutoPilotTagPolicyManager {
    <#
    .SYNOPSIS
    Adds and removes explicit Group Tag managers atomically.

    .DESCRIPTION
    Updates the MANAGER_AUTHORIZATION_POLICY application setting of an existing
    Autopilot Import Function App. The command preserves the installing user,
    keeps Intune Role Administrator access enabled, and verifies that the caller
    has an effective Owner or Contributor assignment on the Function App or a
    parent scope before applying the change.

    Values not supplied explicitly are resolved from client.settings.json.

    .PARAMETER AddPrincipalId
    Microsoft Entra object IDs of users or groups to add as explicit Group Tag
    managers.

    .PARAMETER RemovePrincipalId
    Microsoft Entra object IDs of users or groups to remove. The identity that
    installed the solution cannot be removed.

    .PARAMETER SubscriptionId
    Azure subscription containing the Function App.

    .PARAMETER TenantId
    Microsoft Entra tenant used for Azure authentication.

    .PARAMETER ResourceGroupName
    Resource group containing the Function App.

    .PARAMETER FunctionAppName
    Name of the Autopilot Import Function App to update.

    .PARAMETER ConfigPath
    Optional path to client.settings.json.

    .EXAMPLE
    Update-AutoPilotTagPolicyManager `
        -AddPrincipalId '11111111-1111-1111-1111-111111111111' `
        -RemovePrincipalId '22222222-2222-2222-2222-222222222222'

    Adds one manager and removes another using the installed client settings.

    .EXAMPLE
    Update-AutoPilotTagPolicyManager `
        -AddPrincipalId '11111111-1111-1111-1111-111111111111' `
        -WhatIf

    Authenticates, validates authorization, and previews the resulting policy
    without updating the Function App setting.

    .INPUTS
    None. This command does not accept pipeline input.

    .OUTPUTS
    PSCustomObject containing FunctionAppName and the resulting ManagerPolicy.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'None')]
    param(
        [guid[]] $AddPrincipalId,
        [guid[]] $RemovePrincipalId,
        [guid] $SubscriptionId,
        [guid] $TenantId,
        [string] $ResourceGroupName,
        [string] $FunctionAppName,
        [string] $ConfigPath
    )

    Assert-ClientCommand -Name 'Get-AzWebApp', 'Get-AzRoleAssignment', 'Set-AzWebApp', 'Set-AzContext'
    $addIds = @($AddPrincipalId | Where-Object { $null -ne $_ } |
        ForEach-Object { $_.ToString() })
    $removeIds = @($RemovePrincipalId | Where-Object { $null -ne $_ } |
        ForEach-Object { $_.ToString() })
    if ($addIds.Count -eq 0 -and $removeIds.Count -eq 0) {
        throw 'Specify at least one principal ID to add or remove.'
    }
    $configuration = Resolve-ClientConfiguration $ConfigPath @{
        subscriptionId = $SubscriptionId; tenantId = $TenantId
        resourceGroupName = $ResourceGroupName; functionAppName = $FunctionAppName
    }
    $missingDeploymentValues = @(
        foreach ($entry in @(
                @{ Name = 'SubscriptionId'; Key = 'subscriptionId' }
                @{ Name = 'ResourceGroupName'; Key = 'resourceGroupName' }
                @{ Name = 'FunctionAppName'; Key = 'functionAppName' }
            )) {
            if ([string]::IsNullOrWhiteSpace(
                    [string] $configuration[$entry.Key])) {
                $entry.Name
            }
        }
    )
    if ($missingDeploymentValues.Count -gt 0) {
        $configuredFunctionUrl = [string] $configuration['functionUrl']
        $configuredTenantId = Get-ConfigurationValue `
            $configuration tenantId 'TenantId'
        if ([string]::IsNullOrWhiteSpace($configuredFunctionUrl)) {
            throw "Azure deployment details required by manager-policy commands are missing: $($missingDeploymentValues -join ', '). Pass -SubscriptionId, -ResourceGroupName, and -FunctionAppName explicitly."
        }
        Write-Verbose "Discovering Azure Function App deployment details for '$configuredFunctionUrl'."
        $deployment = Resolve-ClientFunctionAppFromUrl `
            -FunctionUrl $configuredFunctionUrl `
            -TenantId $configuredTenantId `
            -SubscriptionId ([string] $configuration['subscriptionId'])
        $configuration['subscriptionId'] = $deployment.SubscriptionId
        $configuration['resourceGroupName'] = $deployment.ResourceGroupName
        $configuration['functionAppName'] = $deployment.FunctionAppName
        Save-ClientDeploymentConfiguration `
            -Configuration $configuration `
            -Deployment $deployment
    }
    $resolvedSubscriptionId = Get-ConfigurationValue $configuration subscriptionId 'SubscriptionId'
    $resolvedTenantId = Get-ConfigurationValue $configuration tenantId 'TenantId'
    $resolvedResourceGroup = Get-ConfigurationValue $configuration resourceGroupName 'ResourceGroupName'
    $resolvedFunctionName = Get-ConfigurationValue $configuration functionAppName 'FunctionAppName'

    [void](Get-ClientAccessToken $resolvedTenantId 'https://management.azure.com/' $resolvedSubscriptionId)
    Set-AzContext -Tenant $resolvedTenantId -Subscription $resolvedSubscriptionId -WhatIf:$false | Out-Null
    $functionApp = Get-AzWebApp -ResourceGroupName $resolvedResourceGroup -Name $resolvedFunctionName
    if (-not $functionApp) { throw "Function App '$resolvedFunctionName' was not found." }

    $managementTokenResult = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'
    $plainToken = if ($managementTokenResult.Token -is [Security.SecureString]) {
        ConvertFrom-SecureString $managementTokenResult.Token -AsPlainText
    } else { [string] $managementTokenResult.Token }
    # Decode the Azure-issued access token only to identify the signed-in
    # principal whose effective role assignments must be checked.
    $payload = $plainToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $payload = $payload.PadRight($payload.Length + ((4 - $payload.Length % 4) % 4), '=')
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    $assignments = @(Get-AzRoleAssignment -ObjectId ([guid] $claims.oid) -ExpandPrincipalGroups)

    $coreModulePath = Get-CoreModulePath
    Import-Module $coreModulePath -Force
    if (-not (Test-TagManagerPolicyAdministratorRole $assignments $functionApp.Id)) {
        throw "Only an Owner or Contributor of Function App '$resolvedFunctionName' may change its Group Tag managers."
    }

    # Round-trip every existing setting because Set-AzWebApp replaces the
    # complete AppSettings collection rather than patching a single key.
    $appSettings = @{}
    foreach ($setting in @($functionApp.SiteConfig.AppSettings)) {
        $appSettings[[string] $setting.Name] = [string] $setting.Value
    }
    if (-not $appSettings.ContainsKey('MANAGER_AUTHORIZATION_POLICY')) {
        throw "Function App '$resolvedFunctionName' does not contain MANAGER_AUTHORIZATION_POLICY."
    }
    try {
        $currentPolicy = $appSettings.MANAGER_AUTHORIZATION_POLICY | ConvertFrom-Json
        $installerId = ([guid] $currentPolicy.installerPrincipalId).ToString()
        $additionalIds = @($currentPolicy.additionalPrincipalIds | Where-Object { $null -ne $_ } |
            ForEach-Object { ([guid] $_).ToString() })
    }
    catch { throw "The existing MANAGER_AUTHORIZATION_POLICY is invalid: $($_.Exception.Message)" }
    # The installer identity is the recovery administrator and must remain in
    # the policy even when it also appears in the requested removal set.
    if ($installerId -in $removeIds) { throw 'The installing user cannot be removed.' }
    $updatedIds = @(@($additionalIds) + $addIds | Where-Object {
        $_ -notin $removeIds -and $_ -ne $installerId
    } | Sort-Object -Unique)
    $updatedPolicy = [ordered]@{
        installerPrincipalId = $installerId
        additionalPrincipalIds = $updatedIds
        allowIntuneRoleAdministrators = $true
    }
    if ($PSCmdlet.ShouldProcess("$resolvedResourceGroup/$resolvedFunctionName", 'Update Group Tag managers')) {
        $updatedPolicyJson = $updatedPolicy |
            ConvertTo-Json -Depth 4 -Compress
        $appSettings['MANAGER_AUTHORIZATION_POLICY'] = `
            [string] $updatedPolicyJson
        Set-AzWebApp -ResourceGroupName $resolvedResourceGroup -Name $resolvedFunctionName `
            -AppSettings $appSettings | Out-Null
    }
    [pscustomobject]@{ FunctionAppName = $resolvedFunctionName; ManagerPolicy = $updatedPolicy }
}

function Add-AutoPilotTagPolicyManager {
    <#
    .SYNOPSIS
    Adds explicit users or groups to the Group Tag manager policy.

    .DESCRIPTION
    Adds Microsoft Entra principal object IDs to the Function App's explicit
    Group Tag manager list. This command delegates authentication, authorization
    checks, deduplication, and the update to Update-AutoPilotTagPolicyManager.

    .PARAMETER PrincipalId
    Microsoft Entra object IDs of users or groups to add as managers.

    .PARAMETER SubscriptionId
    Azure subscription containing the Function App. The configured value is
    used when omitted.

    .PARAMETER TenantId
    Microsoft Entra tenant used for Azure authentication. The configured value
    is used when omitted.

    .PARAMETER ResourceGroupName
    Resource group containing the Function App. The configured value is used
    when omitted.

    .PARAMETER FunctionAppName
    Name of the Function App to update. The configured value is used when
    omitted.

    .PARAMETER ConfigPath
    Optional path to client.settings.json.

    .EXAMPLE
    Add-AutoPilotTagPolicyManager `
        -PrincipalId '11111111-1111-1111-1111-111111111111'

    Adds one explicit manager using the installed client settings.

    .EXAMPLE
    Add-AutoPilotTagPolicyManager `
        -PrincipalId '11111111-1111-1111-1111-111111111111' `
        -WhatIf

    Previews the manager policy update.

    .INPUTS
    None. This command does not accept pipeline input.

    .OUTPUTS
    PSCustomObject containing FunctionAppName and the resulting ManagerPolicy.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'None')]
    param(
        [Parameter(Mandatory)][guid[]] $PrincipalId,
        [guid] $SubscriptionId, [guid] $TenantId,
        [string] $ResourceGroupName, [string] $FunctionAppName, [string] $ConfigPath
    )
    $parameters = @{ AddPrincipalId = $PrincipalId; Confirm = $false }
    foreach ($name in @(
            'SubscriptionId', 'TenantId', 'ResourceGroupName',
            'FunctionAppName', 'ConfigPath'
        )) {
        if ($PSBoundParameters.ContainsKey($name)) {
            $parameters[$name] = $PSBoundParameters[$name]
        }
    }
    if ($WhatIfPreference) {
        $parameters.WhatIf = $true
    }
    Update-AutoPilotTagPolicyManager @parameters
}

function Remove-AutoPilotTagPolicyManager {
    <#
    .SYNOPSIS
    Removes explicit users or groups from the Group Tag manager policy.

    .DESCRIPTION
    Removes Microsoft Entra principal object IDs from the Function App's
    explicit Group Tag manager list. The identity that installed the solution
    remains protected. This command delegates validation and the update to
    Update-AutoPilotTagPolicyManager.

    .PARAMETER PrincipalId
    Microsoft Entra object IDs of users or groups to remove. The installing
    identity cannot be removed.

    .PARAMETER SubscriptionId
    Azure subscription containing the Function App. The configured value is
    used when omitted.

    .PARAMETER TenantId
    Microsoft Entra tenant used for Azure authentication. The configured value
    is used when omitted.

    .PARAMETER ResourceGroupName
    Resource group containing the Function App. The configured value is used
    when omitted.

    .PARAMETER FunctionAppName
    Name of the Function App to update. The configured value is used when
    omitted.

    .PARAMETER ConfigPath
    Optional path to client.settings.json.

    .EXAMPLE
    Remove-AutoPilotTagPolicyManager `
        -PrincipalId '11111111-1111-1111-1111-111111111111'

    Removes one explicit manager using the installed client settings.

    .EXAMPLE
    Remove-AutoPilotTagPolicyManager `
        -PrincipalId '11111111-1111-1111-1111-111111111111' `
        -WhatIf

    Previews the manager policy update.

    .INPUTS
    None. This command does not accept pipeline input.

    .OUTPUTS
    PSCustomObject containing FunctionAppName and the resulting ManagerPolicy.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'None')]
    param(
        [Parameter(Mandatory)][guid[]] $PrincipalId,
        [guid] $SubscriptionId, [guid] $TenantId,
        [string] $ResourceGroupName, [string] $FunctionAppName, [string] $ConfigPath
    )
    $parameters = @{ RemovePrincipalId = $PrincipalId; Confirm = $false }
    foreach ($name in @(
            'SubscriptionId', 'TenantId', 'ResourceGroupName',
            'FunctionAppName', 'ConfigPath'
        )) {
        if ($PSBoundParameters.ContainsKey($name)) {
            $parameters[$name] = $PSBoundParameters[$name]
        }
    }
    if ($WhatIfPreference) {
        $parameters.WhatIf = $true
    }
    Update-AutoPilotTagPolicyManager @parameters
}

Export-ModuleMember -Function @(
    'New-AutoPilotImporterClientConfiguration',
    'Get-AutoPilotImporterClientConfiguration',
    'Import-AutoPilotDevice',
    'Get-AutoPilotImportStatus',
    'Get-AutoPilotImportHistory',
    'Get-AutoPilotTagPolicy',
    'Add-AutoPilotTagPolicy',
    'Remove-AutoPilotTagPolicy',
    'Set-AutoPilotTagPolicy',
    'Get-AutoPilotTagPolicyManager',
    'Update-AutoPilotTagPolicyManager',
    'Add-AutoPilotTagPolicyManager',
    'Remove-AutoPilotTagPolicyManager'
)
