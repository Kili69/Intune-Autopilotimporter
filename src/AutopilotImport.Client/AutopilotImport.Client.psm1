#Requires -Version 7.2
# Project-Version: 1.4.20261020.11
# Author: andreas.lucas@outlook.com (aka Kili)

<#
.SYNOPSIS
Provides client commands for the secured Windows Autopilot import service.

.DESCRIPTION
The AutopilotImport.Client module validates and imports Autopilot CSV files,
changes Group Tags for eligible existing devices, queries asynchronous
operation status, and manages Group Tag authorization and manager policies.
Commands resolve deployment settings from persisted per-user configuration,
client.settings.json, or explicit parameters and acquire Microsoft Entra
access tokens through Az.Accounts.

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

    # Ensure the configuration hashtable is initialized even if the file does not exist.
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

    # Ensure the management URL is normalized if present.
    if ($configuration.ContainsKey('managementUrl') -and
        -not [string]::IsNullOrWhiteSpace([string] $configuration['managementUrl'])) {
        $configuration['managementUrl'] = Resolve-ClientManagementUrl `
            -ManagementUrl $configuration['managementUrl']
    }

    # Persist the configuration path for reference.
    $configuration.ConfigPath = $ConfigPath
    return $configuration
}

function Resolve-ClientManagementUrl {
    <#
    .NOTES
    Normalizes only recognized site/UI/management-root paths. An already
    specific management route or an unknown path is retained so explicit
    endpoints are not silently redirected. Empty and unparseable values are
    passed through for the calling command's configuration validation.

    .SYNOPSIS
    Resolves a site URL or a management endpoint to the exact API route.

    .DESCRIPTION
    Accepts either a management endpoint such as
    https://example.com/api/management/tag-policy or a website/root URL such as
    https://example.com or https://example.com/api/ui/index.html and normalizes
    the value to the canonical API endpoint used by the client.

    .PARAMETER ManagementUrl
    Value supplied to a client command or persisted in client settings.

    .PARAMETER Route
    Optional route relative to /api/management. Defaults to tag-policy.

    .OUTPUTS
    String. The resolved API endpoint URL.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $ManagementUrl,

        [string] $Route = 'tag-policy'
    )

    # Return early if the management URL is empty or consists only of whitespace.
    if ([string]::IsNullOrWhiteSpace($ManagementUrl)) {
        return $ManagementUrl
    }

    $trimmedUrl = $ManagementUrl.Trim()
    # Trim any leading or trailing whitespace from the management URL.
    try {
        $uri = [uri] $trimmedUrl
    }
    catch {
        return $trimmedUrl
    }

    # Normalize the route relative to /api/management.
    $normalizedRoute = if ([string]::IsNullOrWhiteSpace($Route)) {
        'tag-policy'
    }
    else {
        $Route.Trim('/')
    }
    $path = ($uri.AbsolutePath ?? '').TrimEnd('/')
    $authority = $uri.GetLeftPart([UriPartial]::Authority)
    if ([string]::IsNullOrWhiteSpace($authority)) {
        return $trimmedUrl
    }

    # Determine the appropriate API endpoint based on the path.
    if ($path -match '(?i)^/api/management/?$') {
        return "$authority/api/management/$normalizedRoute"
    }
    # If the path does not match any known patterns, return the original absolute URI.
    if ($path -match '(?i)^/api/management/.*$') {
        return $uri.AbsoluteUri.TrimEnd('/')
    }
    # If the path matches the UI route, redirect to the normalized API endpoint.
    if ($path -match '(?i)^/api/ui(?:/.*)?$') {
        return "$authority/api/management/$normalizedRoute"
    }
    # If the path is empty or the root, redirect to the normalized API endpoint.
    if ([string]::IsNullOrWhiteSpace($path) -or $path -eq '/') {
        return "$authority/api/management/$normalizedRoute"
    }

    return $uri.AbsoluteUri.TrimEnd('/')
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
    # Ensure the configuration directory exists.
    $configurationDirectory = Join-Path `
        ([IO.Path]::GetFullPath($userProfilePath)) `
        '.autopilotimporter'
    return Join-Path $configurationDirectory 'client.settings.json'
}

function Get-ConfigurationValue {
    <#
    .DESCRIPTION
    Converts the selected setting to text and rejects absent or whitespace-only
    values before token acquisition or HTTP requests. Optional settings should
    be read directly from the configuration rather than through this helper.

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
    # Trim any leading or trailing whitespace from the value.
    $value = $value.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "$Description is missing. Run Get-AutoPilotImporterClientConfiguration -FunctionUrl '<Function-URL>' once, provide -ConfigPath, or pass the value explicitly."
    }
    return $value
}

function Get-ClientApiErrorMessage {
    <#
    .NOTES
    ErrorDetails can contain a proxy's non-JSON body. JSON parsing is therefore
    best-effort; the original exception remains the fallback. Only recognized
    API error identifiers receive tailored guidance, and the correlation ID is
    appended without exposing tokens or the hardware hash.

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
    # Initialize the response object to null.
    $responseText = if ($ErrorRecord.ErrorDetails) {
        [string] $ErrorRecord.ErrorDetails.Message
    }
    else {
        ''
    }
    # Attempt to parse the response text as JSON if it is not empty.
    if (-not [string]::IsNullOrWhiteSpace($responseText)) {
        try { $response = $responseText | ConvertFrom-Json }
        catch { $response = $null }
    }

    # Extract relevant fields from the parsed response, if available.
    $errorCode = if ($response -and $response.PSObject.Properties['error']) {
        [string] $response.error
    }
    else { '' }
    # Extract the server-provided error code, message, and correlation ID for later use.
    $serverMessage = if ($response -and $response.PSObject.Properties['message']) {
        [string] $response.message
    }
    else { '' }
    # Extract the correlation ID for later use.
    $correlationId = if ($response -and $response.PSObject.Properties['correlationId']) {
        [string] $response.correlationId
    }
    else { '' }

    # Determine the appropriate error message based on the extracted error code.
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

    # Prepend the serial number to the error message for context.
    $message = "Import failed for serial '$SerialNumber'. $message"
    if (-not [string]::IsNullOrWhiteSpace($correlationId)) {
        $message += " Correlation ID: $correlationId."
    }
    return $message
}

function Add-ClientImportMetadata {
    <#
    .DESCRIPTION
    Enriches the same response object in place, replacing prior client metadata
    when called again. The local acceptance timestamp is informational and must
    not be interpreted as the server's processing-completion timestamp.

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

    # Add client-side metadata to the import response.
    $ImportResponse | Add-Member `
        -NotePropertyName importedAt `
        -NotePropertyValue $ImportedAt.ToString('yyyy-MM-dd HH:mm:ss zzz') `
        -Force
    # Add a note about Intune's asynchronous processing to the import response.
    $ImportResponse | Add-Member `
        -NotePropertyName intuneAvailabilityNote `
        -NotePropertyValue 'Intune processes imports asynchronously. It may take several minutes before the device appears in the Intune admin center.' `
        -Force
    return $ImportResponse
}

function Add-ClientImportStatusMetadata {
    <#
    .NOTES
    Mutates and returns the response, preserving all server fields. An Intune
    complete state alone is not final: extensionAttributeStatus must also be
    complete. Older responses without that field stay nonfinal instead of
    implying that queued Entra processing succeeded.

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

    # Normalize the import status and extension attribute status to lowercase strings for consistent processing.
    $status = ([string] $ImportStatus.status).ToLowerInvariant()
    $extensionStatus = if ($ImportStatus.PSObject.Properties['extensionAttributeStatus']) {
        ([string] $ImportStatus.extensionAttributeStatus).ToLowerInvariant()
    }
    else {
        'unknown'
    }
    # Determine the human-readable description based on the normalized status values.
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

    # Add the human-readable description and final-state flag to the import status response.
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
    .NOTES
    Reuses a matching Az context when possible and signs in for the requested
    tenant/subscription otherwise. Normalizes old string and new SecureString
    Az.Accounts token results to SecureString for Invoke-RestMethod. Tokens are
    returned only in memory and are not written to client configuration.

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

    # Acquire an access token for the specified resource and tenant, optionally scoped to a subscription.
    Assert-ClientCommand -Name 'Get-AzContext', 'Connect-AzAccount', 'Get-AzAccessToken'
    $context = Get-AzContext -ErrorAction SilentlyContinue
    # Reuse the current login only when it belongs to the requested tenant and,
    # for control-plane calls, the requested subscription.
    $contextMatches = $context -and [string] $context.Tenant.Id -eq $TenantId
    # Check if the current context matches the requested tenant and subscription.
    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $contextMatches = $contextMatches -and
            [string] $context.Subscription.Id -eq $SubscriptionId
    }
    # If the current context does not match, initiate a new login with the specified tenant and subscription.
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
    <#
    .SYNOPSIS
    Finds the Azure Function App that owns a default or custom hostname.

    .DESCRIPTION
    Acquires an ARM token and searches accessible subscriptions in the tenant.
    Matches only Function Apps, using both default and bound hostnames.
    Inaccessible subscriptions are reported on the verbose stream; no match or
    multiple matches require explicit deployment parameters from the caller.
    The original Azure context is restored after the search.

    .PARAMETER FunctionUrl
    HTTPS URL whose hostname identifies the deployed Function App.
    .PARAMETER TenantId
    Tenant in which subscriptions are searched.
    .PARAMETER SubscriptionId
    Optional subscription restriction to avoid a tenant-wide search.
    .OUTPUTS
    PSCustomObject with SubscriptionId, ResourceGroupName and FunctionAppName.
    #>
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
    # Parse the function URL and extract the hostname for matching against Function Apps.
    $functionUri = [uri] $FunctionUrl
    # Extract the hostname from the URI for later comparison with Function App hostnames.
    $hostName = $functionUri.Host
    [void] (Get-ClientAccessToken `
        -TenantId $TenantId `
        -ResourceUrl 'https://management.azure.com/' `
        -SubscriptionId $SubscriptionId)
    # Store the original Azure context to restore it later, ensuring the caller's context is not disrupted.
    $originalContext = Get-AzContext -ErrorAction SilentlyContinue
    # Initialize a list to hold matching Function Apps.
    $subscriptions = if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
        @(Get-AzSubscription -TenantId $TenantId -ErrorAction Stop)
    }
    else {
        @(Get-AzSubscription `
            -SubscriptionId $SubscriptionId `
            -TenantId $TenantId `
            -ErrorAction Stop)
    }
    # Iterate through each subscription to find matching Function Apps.
    $matches = [Collections.Generic.List[object]]::new()
    try {
        # Loop through each subscription to search for Function Apps matching the hostname.
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
    # Return the single matching Function App or throw an error if none or multiple matches are found.
    if ($matches.Count -eq 0) {
        throw "No accessible Azure Function App uses hostname '$hostName'. Verify Azure access or pass -SubscriptionId, -ResourceGroupName, and -FunctionAppName explicitly."
    }
    # If exactly one match is found, return it.
    if ($matches.Count -gt 1) {
        throw "Hostname '$hostName' matched more than one accessible Azure Function App. Pass -SubscriptionId, -ResourceGroupName, and -FunctionAppName explicitly."
    }
    return $matches[0]
}

function Save-ClientDeploymentConfiguration {
    <#
    .SYNOPSIS
    Persists discovered deployment coordinates without replacing other settings.

    .DESCRIPTION
    Updates an existing JSON configuration through a sibling temporary file
    followed by a move. Missing files are deliberately not created: bootstrap
    owns initial configuration creation. The temporary file is cleaned up even
    when serialization or replacement fails.

    .PARAMETER Configuration
    Resolved client settings containing the ConfigPath to update.
    .PARAMETER Deployment
    Discovered SubscriptionId, ResourceGroupName and FunctionAppName.
    .OUTPUTS
    None. Writes the existing client configuration file.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable] $Configuration,

        [Parameter(Mandatory)]
        [object] $Deployment
    )

    # Get the path to the client configuration file and ensure it exists before proceeding.
    $settingsPath = [string] $Configuration.ConfigPath
    # If the configuration file does not exist, exit early.
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        return
    }
    # Read the existing configuration and update it with the discovered deployment coordinates.
    $settings = Get-Content -LiteralPath $settingsPath -Raw |
        ConvertFrom-Json -AsHashtable
    $settings['subscriptionId'] = [string] $Deployment.SubscriptionId
    $settings['resourceGroupName'] = [string] $Deployment.ResourceGroupName
    $settings['functionAppName'] = [string] $Deployment.FunctionAppName
    # Write the updated configuration to a temporary file and replace the original atomically.
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
        # Clean up the temporary file even if the move fails.
        Remove-Item `
            -LiteralPath $temporaryPath `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

function Get-CoreModulePath {
    <#
    .NOTES
    Checks the bundled core module and the sibling compatibility layout in
    order. Throws with both attempted paths if the installation is incomplete
    rather than importing an unrelated module from PSModulePath.

    .SYNOPSIS
    Locates the AutopilotImport runtime module used by client policy commands.

    .DESCRIPTION
    Supports both the installed client-package layout and the repository or
    deployment-package layout, returning the first existing core module path.

    .OUTPUTS
    System.String containing the path to AutopilotImport.psm1.
    #>

    # Define candidate paths for the core module and select the first existing one.
    $candidates = @(
        (Join-Path $PSScriptRoot 'AutopilotImport.psm1'),
        (Join-Path $PSScriptRoot '..\AutopilotImport\AutopilotImport.psm1')
    )
    # Attempt to find the first existing core module path from the candidate list.
    $modulePath = $candidates | Where-Object { Test-Path $_ -PathType Leaf } |
        Select-Object -First 1
    # If no existing core module path is found, throw an error.
    if (-not $modulePath) {
        throw "Required AutopilotImport core module was not found. Checked: $($candidates -join ', ')"
    }
    return $modulePath
}

function Get-AutoPilotImporterClientConfiguration {
    <#
    .NOTES
    Bootstrap validates the public runtime endpoints before replacing the
    persisted user settings. Custom domains do not reliably reveal the Azure
    resource name; control-plane coordinates may be supplied explicitly and
    are otherwise discovered only when an administrative command needs them.

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

    # Ensure that the FunctionUrl is provided and is a valid HTTPS URL before proceeding.
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

        # Validate and parse the client ID as a GUID before proceeding.
        $parsedClientId = [guid]::Empty
        if (-not [guid]::TryParse($clientId, [ref] $parsedClientId)) {
            throw "The Function runtime configuration contains an invalid web client ID '$clientId'."
        }

        # Validate and parse the authority URL to extract the tenant ID.
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

        # Infer the Function App name from the host if it follows the standard Azure Websites naming convention.
        $inferredFunctionAppName = if ($functionUri.Host.EndsWith(
                '.azurewebsites.net',
                [StringComparison]::OrdinalIgnoreCase)) {
            $functionUri.Host.Split('.')[0]
        }
        else {
            $null
        }
        # If the Function App name could not be inferred, it will be resolved from the existing configuration or provided parameters.
        $resolvedSubscriptionId = if (
            $PSBoundParameters.ContainsKey('SubscriptionId')) {
            $SubscriptionId.ToString()
        }
        else {
            [string] $existingConfiguration['subscriptionId']
        }
        # Resolve the Function App name from the existing configuration or provided parameters if it could not be inferred.
        $resolvedResourceGroupName = if (
            $PSBoundParameters.ContainsKey('ResourceGroupName')) {
            $ResourceGroupName
        }
        else {
            [string] $existingConfiguration['resourceGroupName']
        }
        # At this point, all necessary Azure-related values have been resolved.
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
        # Ensure the configuration directory exists before writing the settings file.
        $configurationDirectory = Split-Path `
            -Parent `
            -Path $resolvedConfigPath
        New-Item `
            -Path $configurationDirectory `
            -ItemType Directory `
            -Force | Out-Null

        # Prepare the settings hashtable with all resolved values before writing it to the configuration file.
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
        # Check for any missing Azure-related values and warn the user if necessary.
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
        # If any required Azure-related values are missing, they will be included in the $missingAzureValues array.
        if ($missingAzureValues.Count -gt 0) {
            Write-Warning "The API configuration was saved, but Azure deployment details required by manager-policy commands are missing: $($missingAzureValues -join ', '). Run this command again with -SubscriptionId, -ResourceGroupName, and -FunctionAppName."
        }
    }

    # Resolve the client configuration and ensure the configuration file exists.
    $configuration = Resolve-ClientConfiguration -ConfigPath $ConfigPath
    $resolvedConfigPath = [IO.Path]::GetFullPath(
        [string] $configuration.ConfigPath
    )
    if (-not (Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf)) {
        throw "Client configuration '$resolvedConfigPath' was not found. Run Get-AutoPilotImporterClientConfiguration -FunctionUrl '<Function-URL>' once or provide -ConfigPath."
    }

    # Define the required settings and their descriptions for user prompts.
    $requiredSettings = [ordered]@{
        functionUrl         = 'Function URL'
        managementUrl       = 'management URL'
        apiApplicationIdUri = 'API application ID URI'
        tenantId            = 'Tenant ID'
        webUrl              = 'web URL'
    }
    $resolvedSettings = @{}
    # Iterate through each required setting and resolve its value from the configuration or user input.
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
    .NOTES
    Reads Easy Auth through ARM, not from local guesses. Prefers a configured
    API audience different from the application client ID, then derives api://
    from that ID when necessary. Existing files require Force; ShouldProcess
    gates filesystem writes, but Azure reads/sign-in still occur under WhatIf.

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

    # Ensure the user is authenticated and has the correct Azure context before proceeding with the client configuration.
    Assert-ClientCommand -Name @(
        'Get-AzContext'
        'Connect-AzAccount'
        'Set-AzContext'
        'Invoke-AzRestMethod'
    )
    # Retrieve the current Azure context to verify the subscription and tenant.
    $context = Get-AzContext -ErrorAction SilentlyContinue
    # If the context is not set or does not match the provided subscription and tenant, prompt the user to authenticate.
    if (-not $context -or
        [string] $context.Subscription.Id -ne $SubscriptionId -or
        [string] $context.Tenant.Id -ne $TenantId) {
        Connect-AzAccount `
            -Tenant $TenantId `
            -Subscription $SubscriptionId | Out-Null
    }
    # Set the Azure context to the specified subscription and tenant.
    Set-AzContext `
        -Tenant $TenantId `
        -Subscription $SubscriptionId | Out-Null

    $resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName"
    # Invoke the REST method to retrieve the Easy Auth settings for the Function App.
    $authenticationResponse = Invoke-AzRestMethod `
        -Method GET `
        -Path "$resourceId/config/authsettingsV2?api-version=2023-12-01"
    # Check if the REST method returned an error and throw an exception if it did.
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
    # If the API application ID URI is not explicitly set, attempt to construct it from the client ID.
    if ([string]::IsNullOrWhiteSpace($apiApplicationIdUri) -and
        -not [string]::IsNullOrWhiteSpace($clientId)) {
        $apiApplicationIdUri = "api://$clientId"
    }
    # Ensure that the API application ID URI is set, throwing an exception if it is missing.
    if ([string]::IsNullOrWhiteSpace($apiApplicationIdUri)) {
        throw "Function App '$FunctionAppName' does not contain an API application ID URI in its Easy Auth settings."
    }

    # Resolve the output path for the client configuration and ensure the directory exists.
    $resolvedOutputPath = [IO.Path]::GetFullPath($OutputPath)
    # Determine the full path for the client settings file within the resolved output directory.
    $settingsPath = Join-Path $resolvedOutputPath 'client.settings.json'
    # Check if the client settings file already exists and handle the -Force parameter.
    if ((Test-Path -LiteralPath $settingsPath) -and -not $Force) {
        throw "Client configuration '$settingsPath' already exists. Use -Force to replace it."
    }
    # Confirm with the user before creating the client configuration file.
    if (-not $PSCmdlet.ShouldProcess($settingsPath, 'Create client configuration')) {
        return
    }

    # Create the output directory if it does not exist.
    New-Item -Path $resolvedOutputPath -ItemType Directory -Force | Out-Null
    # Construct the client configuration as an ordered hashtable.
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
    # Inform the user to copy the client settings file to the script root for default usage.
    Write-Warning "Copy '$settingsPath' to '$PSScriptRoot\client.settings.json' so the AutopilotImport.Client module uses it by default."
    Get-Item -LiteralPath $settingsPath
}

function Import-AutoPilotDevice {
    <#
    .NOTES
    Validates every CSV row before acquiring a token to avoid partial submission
    caused by malformed later rows. ValidateOnly and WhatIf do not submit or
    authenticate. Real imports are sequential, reuse one API token and stop on
    the first rejected request; previously accepted rows are not rolled back.

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

    # Ensure the CSV file exists and is not empty before proceeding.
    if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
        throw "The Autopilot CSV file '$CsvPath' does not exist or is not a file. Verify the path and try again."
    }
    $csvFile = Get-Item -LiteralPath $CsvPath
    if ($csvFile.Length -eq 0) {
        throw "The Autopilot CSV file '$($csvFile.FullName)' is empty. Export the device data again and try again."
    }
    # Resolve the client configuration, applying any overrides provided via parameters.
    $configuration = Resolve-ClientConfiguration -ConfigPath $ConfigPath -Overrides @{
        functionUrl = $FunctionUrl
        apiApplicationIdUri = $ApiApplicationIdUri
        tenantId = $TenantId
    }
    $rows = @(Import-Csv -LiteralPath $CsvPath)
    # Import the CSV file and store its rows in an array for further processing.
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
    # This ensures that all rows are well-formed before any network requests are made.
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
    # At this point, all devices have been validated and are ready for import.
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
    # Confirm with the user before proceeding with the import operation.
    if (-not $PSCmdlet.ShouldProcess(
            "$($devices.Count) device(s) from '$($csvFile.FullName)'",
            "Import with Group Tag '$GroupTag'")) {
        return
    }
    # Resolve the necessary configuration values for the import operation.
    $resolvedFunctionUrl = Get-ConfigurationValue $configuration functionUrl 'FunctionUrl'
    # Resolve the function URL from the configuration, ensuring it is available for the import request.
    # Resolve the API audience from the configuration.
    $audience = Get-ConfigurationValue $configuration apiApplicationIdUri 'ApiApplicationIdUri'
    # Resolve the tenant ID from the configuration.
    $resolvedTenantId = Get-ConfigurationValue $configuration tenantId 'TenantId'
    # Parse and validate the tenant ID as a GUID.
    $parsedTenantId = [guid]::Empty
    if (-not [guid]::TryParse($resolvedTenantId, [ref] $parsedTenantId)) {
        throw 'TenantId must be a GUID.'
    }
    # Acquire an access token for the client to authenticate with the import service.
    $token = Get-ClientAccessToken -TenantId $resolvedTenantId -ResourceUrl $audience
    # Iterate over each device and perform the import operation.
    foreach ($device in $devices) {
        # Prepare the request body for the current device.
        $body = @{
            serialNumber = $device.serialNumber
            hardwareIdentifier = $device.hardwareIdentifier
            groupTag = $GroupTag
        } | ConvertTo-Json -Compress
        # Convert the request body to JSON format for the HTTP request.
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

function Resolve-ClientDeviceTagAssignmentsUrl {
    <#
    .SYNOPSIS
    Resolves the endpoint for listing and re-tagging eligible Autopilot devices.

    .DESCRIPTION
    Prefers an explicit deviceTagAssignmentsUrl. Otherwise derives the canonical
    route from the import URL's authority, preserving custom domains but not
    the import route. Both paths require absolute HTTPS URLs.

    .PARAMETER Configuration
    Resolved settings with deviceTagAssignmentsUrl or functionUrl.
    .OUTPUTS
    System.String containing the absolute assignments endpoint.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable] $Configuration
    )
    # Determine the appropriate URL for device tag assignments, either from the configuration or derived from the function URL.
    $configuredUrl = [string] $Configuration['deviceTagAssignmentsUrl']
    # Check if a deviceTagAssignmentsUrl is explicitly configured.
    if (-not [string]::IsNullOrWhiteSpace($configuredUrl)) {
        # Validate that the configured URL is an absolute HTTPS URL.
        $assignmentsUri = [uri] $configuredUrl
        if (-not $assignmentsUri.IsAbsoluteUri -or
            $assignmentsUri.Scheme -ne 'https') {
            throw 'DeviceTagAssignmentsUrl must be an absolute HTTPS URL.'
        }
        return $assignmentsUri.AbsoluteUri
    }

    # Derive the device tag assignments URL from the function URL if not explicitly configured.
    # Validate that the function URL is an absolute HTTPS URL before constructing the assignments endpoint.
    $functionUrl = Get-ConfigurationValue `
        -Configuration $Configuration `
        -Name functionUrl `
        -Description FunctionUrl
    $functionUri = [uri] $functionUrl
    # Ensure the function URL is properly parsed into a URI object.
    if (-not $functionUri.IsAbsoluteUri -or $functionUri.Scheme -ne 'https') {
        throw 'FunctionUrl must be an absolute HTTPS URL.'
    }
    return "$($functionUri.GetLeftPart([UriPartial]::Authority))/api/devices/tags/assignments"
}

function Get-ClientTagChangeErrorMessage {
    <#
    .SYNOPSIS
    Formats a failed device-list or Group Tag change request for the caller.

    .DESCRIPTION
    Prefers the API's message, then its error identifier, then the original
    exception. Non-JSON proxy responses retain the original exception instead
    of hiding it behind a JSON parsing failure. Includes the API correlation
    ID when present so the request can be traced in Function logs.

    .PARAMETER ErrorRecord
    Original Invoke-RestMethod failure, including optional JSON ErrorDetails.
    .PARAMETER Action
    Human-readable operation description prepended to the error.
    .OUTPUTS
    System.String. Does not itself throw or write to an error stream.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord,

        [Parameter(Mandatory)]
        [string] $Action
    )
    # Attempt to parse the error details from the API response, if available.
    $response = $null
    # Initialize the response variable to null before attempting to parse the error details.
    if ($ErrorRecord.ErrorDetails -and
        -not [string]::IsNullOrWhiteSpace(
            [string] $ErrorRecord.ErrorDetails.Message)) {
        try {
            $response = $ErrorRecord.ErrorDetails.Message | ConvertFrom-Json
        }
        catch {
            $response = $null
        }
    }
    # Determine the most appropriate error message to display to the user.
    $message = if ($response -and
        $response.PSObject.Properties['message'] -and
        -not [string]::IsNullOrWhiteSpace([string] $response.message)) {
        [string] $response.message
    }
    elseif ($response -and $response.PSObject.Properties['error']) {
        "Service error: $($response.error)."
    }
    else {
        $ErrorRecord.Exception.Message
    }
    # Construct the final error message, including the action description and any correlation ID if available.
    $result = "$Action failed. $message"
    if ($response -and $response.PSObject.Properties['correlationId']) {
        $result += " Correlation ID: $($response.correlationId)."
    }
    return $result
}

function Get-AutoPilotDeviceTagAssignment {
    <#
    .NOTES
    Eligibility and authorization are server-side decisions; this command does
    not broaden the returned device list. A missing devices property is a
    protocol error, while an empty devices array is a valid result.

    .SYNOPSIS
    Lists existing Autopilot devices eligible for a Group Tag change.

    .DESCRIPTION
    Returns devices that have not contacted the Autopilot deployment service.
    The result includes the device ID, serial number, current Group Tag, Entra
    groups, and administrative units.

    .PARAMETER DeviceTagAssignmentsUrl
    HTTPS URL of the device tag assignments endpoint. When omitted, the command
    derives the endpoint from FunctionUrl.

    .PARAMETER FunctionUrl
    HTTPS URL of the Autopilot import Function endpoint.

    .PARAMETER ApiApplicationIdUri
    Application ID URI exposed by the secured Function API.

    .PARAMETER TenantId
    Microsoft Entra tenant ID used to acquire an API token.

    .PARAMETER ConfigPath
    Optional path to client.settings.json.

    .EXAMPLE
    Get-AutoPilotDeviceTagAssignment

    Lists eligible devices using the installed client configuration.

    .OUTPUTS
    PSCustomObject for each eligible Autopilot device.
    #>
    [CmdletBinding()]
    param(
        [ValidatePattern('^https://')]
        [string] $DeviceTagAssignmentsUrl,
        [ValidatePattern('^https://')]
        [string] $FunctionUrl,
        [ValidatePattern('^api://')]
        [string] $ApiApplicationIdUri,
        [string] $TenantId,
        [string] $ConfigPath
    )
    # Resolve the client configuration, applying any overrides provided via parameters.
    $configuration = Resolve-ClientConfiguration -ConfigPath $ConfigPath `
        -Overrides @{
            deviceTagAssignmentsUrl = $DeviceTagAssignmentsUrl
            functionUrl = $FunctionUrl
            apiApplicationIdUri = $ApiApplicationIdUri
            tenantId = $TenantId
        }
    # Determine the resolved URL for device tag assignments based on the configuration.
    $url = Resolve-ClientDeviceTagAssignmentsUrl `
        -Configuration $configuration
    # Retrieve the audience (API application ID URI) from the resolved configuration.
    $audience = Get-ConfigurationValue `
        -Configuration $configuration `
        -Name apiApplicationIdUri `
        -Description ApiApplicationIdUri
    $resolvedTenantId = Get-ConfigurationValue `
        -Configuration $configuration `
        -Name tenantId `
        -Description TenantId
    # Acquire an access token for the API using the resolved tenant ID and audience.
    $token = Get-ClientAccessToken `
        -TenantId $resolvedTenantId `
        -ResourceUrl $audience
    # Invoke the REST API to retrieve the list of eligible Autopilot devices using the acquired access token.
    try {
        $response = Invoke-RestMethod `
            -Method Get `
            -Uri $url `
            -Authentication Bearer `
            -Token $token `
            -ErrorAction Stop
    }
    catch {
        throw (Get-ClientTagChangeErrorMessage `
                -ErrorRecord $_ `
                -Action 'Retrieving eligible Autopilot devices')
    }
    # Check if the response contains a devices collection and throw an error if it does not.
    if (-not $response.PSObject.Properties['devices']) {
        throw 'Retrieving eligible Autopilot devices failed. The service response does not contain a devices collection.'
    }
    return @($response.devices)
}

function Set-AutoPilotDeviceGroupTag {
    <#
    .NOTES
    Resolves configuration in begin, acquires a token lazily after the first
    approved ShouldProcess action, and handles pipeline IDs sequentially.
    Wait polls the queued operation rather than treating POST acceptance as
    completion. The timeout includes the next sleep interval.

    .SYNOPSIS
    Assigns an authorized Group Tag to existing Autopilot devices.

    .DESCRIPTION
    Queues a Group Tag change for one or more eligible Autopilot device IDs.
    Device objects returned by Get-AutoPilotDeviceTagAssignment can be piped
    directly to this command. With Wait, each operation is polled until it
    completes or the timeout expires.

    .PARAMETER DeviceId
    One or more registered Windows Autopilot device IDs. Accepts the id property
    from Get-AutoPilotDeviceTagAssignment through the pipeline.

    .PARAMETER GroupTag
    New Group Tag authorized for the signed-in user's Entra groups.

    .PARAMETER DeviceTagAssignmentsUrl
    HTTPS URL of the device tag assignments endpoint. When omitted, the command
    derives the endpoint from FunctionUrl.

    .PARAMETER FunctionUrl
    HTTPS URL of the Autopilot import Function endpoint.

    .PARAMETER ApiApplicationIdUri
    Application ID URI exposed by the secured Function API.

    .PARAMETER TenantId
    Microsoft Entra tenant ID used to acquire an API token.

    .PARAMETER ConfigPath
    Optional path to client.settings.json.

    .PARAMETER Wait
    Polls each operation until it completes or TimeoutSeconds expires.

    .PARAMETER PollIntervalSeconds
    Seconds between status requests when Wait is specified. The default is 15.

    .PARAMETER TimeoutSeconds
    Maximum wait time per device. The default is 1800 seconds.

    .EXAMPLE
    Get-AutoPilotDeviceTagAssignment |
        Where-Object serialNumber -eq 'PC-0001' |
        Set-AutoPilotDeviceGroupTag -GroupTag 'Autopilot-Kiosk' -Wait

    Assigns the target Group Tag and waits for post-processing to complete.

    .OUTPUTS
    PSCustomObject containing the queued or completed tag change operation.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('id')]
        [guid[]] $DeviceId,

        [Parameter(Mandatory)]
        [ValidateLength(1, 128)]
        [string] $GroupTag,

        [ValidatePattern('^https://')]
        [string] $DeviceTagAssignmentsUrl,
        [ValidatePattern('^https://')]
        [string] $FunctionUrl,
        [ValidatePattern('^api://')]
        [string] $ApiApplicationIdUri,
        [string] $TenantId,
        [string] $ConfigPath,
        [switch] $Wait,
        [ValidateRange(1, 300)]
        [int] $PollIntervalSeconds = 15,
        [ValidateRange(1, 86400)]
        [int] $TimeoutSeconds = 1800
    )
    # Begin block for initializing configuration, resolving URLs, and acquiring initial access token.
    begin {
        # Resolve the client configuration, applying any overrides provided via parameters.
        $configuration = Resolve-ClientConfiguration -ConfigPath $ConfigPath `
            -Overrides @{
                deviceTagAssignmentsUrl = $DeviceTagAssignmentsUrl
                functionUrl = $FunctionUrl
                apiApplicationIdUri = $ApiApplicationIdUri
                tenantId = $TenantId
            }
        # Resolve the URL for device tag assignments based on the resolved configuration.
        $url = Resolve-ClientDeviceTagAssignmentsUrl `
            -Configuration $configuration
        # Retrieve the audience (API application ID URI) from the resolved configuration.
        $audience = Get-ConfigurationValue `
            -Configuration $configuration `
            -Name apiApplicationIdUri `
            -Description ApiApplicationIdUri
        # Retrieve the resolved tenant ID from the configuration.
        $resolvedTenantId = Get-ConfigurationValue `
            -Configuration $configuration `
            -Name tenantId `
            -Description TenantId
        # Initialize the access token variable to null.
        $token = $null
    }
    # Process block for iterating over each device ID and assigning the group tag.
    process {
        # Iterate over each device ID provided in the input.
        foreach ($id in $DeviceId) {
            # Check if the operation should proceed for the current device ID.
            if (-not $PSCmdlet.ShouldProcess(
                    "Autopilot device '$id'",
                    "Assign Group Tag '$GroupTag'")) {
                continue
            }
            # Acquire an access token if it has not been acquired yet.
            if ($null -eq $token) {
                $token = Get-ClientAccessToken `
                    -TenantId $resolvedTenantId `
                    -ResourceUrl $audience
            }
            # Construct the request body for assigning the group tag to the device.
            $body = @{
                deviceId = $id.ToString()
                groupTag = $GroupTag
            } | ConvertTo-Json -Compress
            # Invoke the REST API to assign the group tag to the device and handle any errors that occur.
            try {
                $result = Invoke-RestMethod `
                    -Method Post `
                    -Uri $url `
                    -Authentication Bearer `
                    -Token $token `
                    -ContentType 'application/json' `
                    -Body $body `
                    -ErrorAction Stop
            }
            catch {
                throw (Get-ClientTagChangeErrorMessage `
                        -ErrorRecord $_ `
                        -Action "Changing the Group Tag for Autopilot device '$id'")
            }

            # If the caller does not want to wait for the operation to complete, mark the result as not final and continue.
            if (-not $Wait) {
                $result | Add-Member `
                    -NotePropertyName isFinal `
                    -NotePropertyValue $false `
                    -Force
                $result
                continue
            }

            # Parse the operation ID from the result and validate it.
            $operationId = [guid]::Empty
            if (-not [guid]::TryParse(
                    [string] $result.operationId,
                    [ref] $operationId)) {
                throw "Changing the Group Tag for Autopilot device '$id' failed. The service returned an invalid operation ID."
            }
            # Construct the status URL for polling the operation status and start the stopwatch.
            $statusUrl = "${url}?operationId=$operationId"
            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            do {
                try {
                    $statusResult = Invoke-RestMethod `
                        -Method Get `
                        -Uri $statusUrl `
                        -Authentication Bearer `
                        -Token $token `
                        -ErrorAction Stop
                }
                catch {
                    throw (Get-ClientTagChangeErrorMessage `
                            -ErrorRecord $_ `
                            -Action "Retrieving Group Tag change '$operationId'")
                }
                $status = ([string] $statusResult.workflowStatus).ToLowerInvariant()
                $isFinal = $status -in @('complete', 'error')
                $statusResult | Add-Member `
                    -NotePropertyName isFinal `
                    -NotePropertyValue $isFinal `
                    -Force
                if ($isFinal) {
                    $statusResult
                    break
                }
                # Check if the operation has timed out and throw an error if it has.
                if ($stopwatch.Elapsed.TotalSeconds +
                    $PollIntervalSeconds -gt $TimeoutSeconds) {
                    throw "Group Tag change '$operationId' did not complete within $TimeoutSeconds seconds. Last status: $status."
                }
                # Wait for the specified polling interval before checking the status again.
                Start-Sleep -Seconds $PollIntervalSeconds
            } while ($true)
        }
    }
}

function Get-AutoPilotImportStatus {
    <#
    .NOTES
    Reads the live import route, not retained audit history. Without Wait it
    returns one enriched response; with Wait it polls until isFinal or timeout.
    HTTP failures retain service error and correlation identifiers. A successful
    request or an Intune complete state does not imply Entra work is complete.

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
    # Resolve the client configuration and retrieve the necessary values for the function URL, audience, and tenant ID.
    $configuration = Resolve-ClientConfiguration $ConfigPath @{
        functionUrl = $FunctionUrl
        apiApplicationIdUri = $ApiApplicationIdUri
        tenantId = $TenantId
    }
    # Retrieve the resolved values from the configuration.
    $url = Get-ConfigurationValue $configuration functionUrl 'FunctionUrl'
    # Retrieve the audience and tenant ID from the configuration.
    $audience = Get-ConfigurationValue $configuration apiApplicationIdUri 'ApiApplicationIdUri'
    # Acquire an access token using the resolved tenant ID and audience.
    $resolvedTenantId = Get-ConfigurationValue $configuration tenantId 'TenantId'
    # Acquire the access token for the API.
    $token = Get-ClientAccessToken $resolvedTenantId $audience
    # Construct the status URL for polling the import status.
    $statusUrl = "$($url.TrimEnd('/'))?importId=$ImportId"

    # Start the stopwatch to track the elapsed time for polling.
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    # Begin polling loop to check the import status at regular intervals.
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
    <#
    .SYNOPSIS
    Computes the audit-search index for a Base64 Autopilot hardware hash.

    .DESCRIPTION
    Decodes Base64 before hashing so the index represents the binary hardware
    identifier, not its textual representation. Rejects invalid or empty
    hashes and returns lowercase hexadecimal SHA-256. History requests send
    only this index, never the original hardware hash.

    .PARAMETER DeviceHash
    Base64 Hardware Hash value from the Autopilot CSV, not a serial number.
    .OUTPUTS
    System.String containing exactly 64 lowercase hexadecimal characters.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateLength(1, 65536)]
        [string] $DeviceHash
    )

    # Attempt to decode the Base64 device hash and handle any errors.
    try {
        $deviceHashBytes = [Convert]::FromBase64String($DeviceHash)
    }
    catch {
        throw 'DeviceHash must be the Base64 Hardware Hash from the Autopilot CSV. To search by the displayed device serial number, use -SerialNumber.'
    }
    # Ensure the decoded device hash is not empty before computing the SHA-256 index.
    if ($deviceHashBytes.Length -eq 0) {
        throw 'DeviceHash must not be empty.'
    }
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($deviceHashBytes)
    ).ToLowerInvariant()
}

function Get-AutoPilotImportHistory {
    <#
    .NOTES
    Unfiltered/self and ShowAll queries use GET; explicit filters use a JSON
    POST so identities and hash indexes are not placed in the URL. DeviceHash
    is decoded and SHA-256 indexed locally. Raw bypasses client projection;
    normal output parses audit times as DateTimeOffset and retains real Intune
    error details. A 404 means a missing endpoint, not an empty history.

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

    # Resolve the client configuration and retrieve the necessary values for the function URL, audience, and tenant ID.
    $configuration = Resolve-ClientConfiguration $ConfigPath @{
        importHistoryUrl = $ImportHistoryUrl
        apiApplicationIdUri = $ApiApplicationIdUri
        tenantId = $TenantId
    }
    # Determine the final URL for the import history API, either from the configuration or derived from the management URL.
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
    # Retrieve the audience and tenant ID from the configuration.
    $audience = Get-ConfigurationValue `
        $configuration `
        apiApplicationIdUri `
        'ApiApplicationIdUri'
    # Acquire an access token using the resolved tenant ID and audience.
    $resolvedTenantId = Get-ConfigurationValue `
        $configuration `
        tenantId `
        'TenantId'
    # Acquire an access token using the resolved tenant ID and audience.
    try {
        $token = Get-ClientAccessToken $resolvedTenantId $audience
    }
    catch {
        throw 'Authentication for the Autopilot import history failed. Run Connect-AzAccount and retry.'
    }
    # Initialize the arrays for the requested import IDs, serial numbers, users, and device hashes.
    [guid[]] $requestedImportIds = @()
    if ($PSBoundParameters.ContainsKey('ImportId')) {
        $requestedImportIds = @($ImportId)
    }
    # Process the requested import IDs if provided.
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
    # Process the requested users if provided.
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
    # Process the requested device hashes if provided.
    [string[]] $requestedDeviceHashes = @()
    if ($PSBoundParameters.ContainsKey('DeviceHash')) {
        $requestedDeviceHashes = @($DeviceHash)
    }
    # Determine if any explicit filters have been provided by the user.
    $hasExplicitFilter = $requestedImportIds.Count -gt 0 -or
        $requestedSerialNumbers.Count -gt 0 -or
        $requestedUsers.Count -gt 0 -or
        $requestedDeviceHashes.Count -gt 0
    # Validate that ShowAll is not combined with explicit filters.
    if ($ShowAll -and $hasExplicitFilter) {
        throw 'ShowAll cannot be combined with ImportId, SerialNumber, DeviceHash, or User.'
    }
    # Validate that the total number of requested import IDs, serial numbers, device hashes, and users does not exceed 50.
    if ($requestedImportIds.Count + $requestedSerialNumbers.Count +
        $requestedDeviceHashes.Count + $requestedUsers.Count -gt 50) {
        throw 'At most 50 ImportId, SerialNumber, DeviceHash, and User values may be requested.'
    }
    # Construct the request URL with the appropriate query parameters.
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
    # If explicit filters are provided, include them in the request body as JSON.
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
    # Invoke the REST method and handle any errors that occur during the request.
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
        # Append the correlation ID to the error message if available.
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
            'graphImportCompletedAtUtc'
            'autopilotGroupTagUpdatedAtUtc'
            'queuedAtUtc'
            'processingStartedAtUtc'
            'entraDeviceResolvedAtUtc'
            'extensionAttributeUpdatedAtUtc'
            'administrativeUnitAssignedAtUtc'
            'processingCompletedAtUtc'
            'processingErrorAtUtc'
            'processingFailedAtUtc'
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
            PolicyName                       = [string] $importProperties['policyName']
            DeviceGroupsUpdatedAtUtc         = [string] $importProperties['deviceGroupsUpdatedAtUtc']
            EntraDeviceId                    = [string] $importProperties['entraDeviceId']
            AppliedExtensionAttributes       = $importProperties['appliedExtensionAttributes']
            TargetDeviceGroupIds             = $importProperties['targetDeviceGroupIds']
            AddedDeviceGroupIds              = $importProperties['addedDeviceGroupIds']
            RemovedDeviceGroupIds            = $importProperties['removedDeviceGroupIds']
            AdministrativeUnitName           = $importProperties['administrativeUnitName']
            RemovedAdministrativeUnits       = $importProperties['removedAdministrativeUnits']
            DeviceHashSha256                 = [string] $importProperties['deviceHashSha256']
            DeviceErrorCode                  = $importProperties['deviceErrorCode']
            DeviceErrorName                  = [string] $importProperties['deviceErrorName']
            RequestedBy                      = [string] $importProperties['requestedBy']
            RequestedByObjectId              = [string] $importProperties['requestedByObjectId']
            RequestedByUserPrincipalName     = [string] $importProperties['requestedByUserPrincipalName']
            RequestedByDisplayName           = [string] $importProperties['requestedByDisplayName']
            RequestReceivedAtUtc              = $auditTimestamps['requestReceivedAtUtc']
            GraphImportCreatedAtUtc           = $auditTimestamps['graphImportCreatedAtUtc']
            GraphImportCompletedAtUtc         = $auditTimestamps['graphImportCompletedAtUtc']
            AutopilotGroupTagUpdatedAtUtc     = $auditTimestamps['autopilotGroupTagUpdatedAtUtc']
            QueuedAtUtc                       = $auditTimestamps['queuedAtUtc']
            ProcessingStartedAtUtc            = $auditTimestamps['processingStartedAtUtc']
            EntraDeviceResolvedAtUtc          = $auditTimestamps['entraDeviceResolvedAtUtc']
            ExtensionAttributeUpdatedAtUtc    = $auditTimestamps['extensionAttributeUpdatedAtUtc']
            AdministrativeUnitAssignedAtUtc   = $auditTimestamps['administrativeUnitAssignedAtUtc']
            ProcessingCompletedAtUtc          = $auditTimestamps['processingCompletedAtUtc']
            ProcessingErrorAtUtc              = $auditTimestamps['processingErrorAtUtc']
            ProcessingFailedAtUtc             = $auditTimestamps['processingFailedAtUtc']
            ProcessingError                   = [string] $importProperties['processingError']
            ProcessingErrorStep               = [string] $importProperties['processingErrorStep']
            ProcessingErrorStatusCode         = $importProperties['processingErrorStatusCode']
            ProcessingAttempt                 = $importProperties['processingAttempt']
            ProcessingMaxAttempts             = $importProperties['processingMaxAttempts']
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
    <#
    .SYNOPSIS
    Projects one API rule into the client policy output and display shape.

    .DESCRIPTION
    Adds resolved group names, a legacy default extension-attribute slot and
    request correlation metadata. Optional device actions are copied only
    when present so a legacy authorization rule does not become an explicit
    action rule merely by being displayed. Sets the default table columns
    without discarding properties available through Format-List.

    .PARAMETER Rule
    Policy rule returned by the management API.
    .PARAMETER GroupName
    Resolved Entra display name, or the caller's unresolved-group marker.
    .PARAMETER ExtensionAttribute
    Deployment-selected legacy slot; defaults to extensionAttribute1.
    .PARAMETER CorrelationId
    Optional API request identifier for troubleshooting.
    .OUTPUTS
    AutopilotImport.TagPolicyRule with preserved supported action properties.
    #>
    param(
        [Parameter(Mandatory)]
        [object] $Rule,

        [AllowNull()]
        [string] $GroupName,

        [AllowNull()]
        [string] $ExtensionAttribute,

        [AllowNull()]
        [string] $CorrelationId
    )

    # Resolve the extension attribute to use, defaulting to extensionAttribute1 if not provided.
    $resolvedExtensionAttribute = if (
        -not [string]::IsNullOrWhiteSpace([string] $ExtensionAttribute)) {
        [string] $ExtensionAttribute.Trim()
    }
    else {
        'extensionAttribute1'
    }

    # Construct the result object with the resolved extension attribute and other properties.
    $result = [pscustomobject][ordered]@{
        PSTypeName = 'AutopilotImport.TagPolicyRule'
        Name = if ($Rule.PSObject.Properties['name']) { [string] $Rule.name } else { "Policy $($Rule.groupId)" }
        GroupId = [string] $Rule.groupId
        GroupName = $GroupName
        Tags = @($Rule.tags)
        ExtensionAttribute = $resolvedExtensionAttribute
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
    # Add any additional properties from the original rule that are present.
    foreach ($key in @('ruleId', 'description', 'groupTag', 'extensionAttributes', 'deviceGroupIds')) {
        if ($Rule.PSObject.Properties[$key]) {
            $result | Add-Member -NotePropertyName $key -NotePropertyValue $Rule.$key
        }
    }
    # Define the default display property set for the result object.
    $displayPropertySet = [Management.Automation.PSPropertySet]::new(
        'DefaultDisplayPropertySet',
        [string[]] @(
            'Name'
            'GroupId'
            'GroupName'
            'Tags'
            'ExtensionAttribute'
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
    .PARAMETER DeviceTagExtensionAttribute
    Legacy deployment attribute slot used in the formatted result. Overrides
    configuration; defaults to extensionAttribute1 and does not change rules.

    .NOTES
    Raw returns the API response without extra Graph reads. Normal output uses
    a separate Graph token to resolve authorization-group names; a lookup
    failure produces a warning and unresolved marker without losing the rule.

    .SYNOPSIS
    Returns the current group-to-tag policy with Entra group display names.

    .DESCRIPTION
    Retrieves the current policy and resolves each group object ID through
    Microsoft Graph. Each rule is returned as a PowerShell object with stable
    RuleId, Description (when present), GroupId, GroupName, Tags, AdministrativeUnitName, and
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
        [ValidatePattern('^extensionAttribute(?:[1-9]|1[0-5])$')]
        [string] $DeviceTagExtensionAttribute,
        [switch] $Raw
    )

    # Resolve the client configuration using the provided parameters and any defaults from the configuration file.
    $configuration = Resolve-ClientConfiguration $ConfigPath @{
        managementUrl = $ManagementUrl
        apiApplicationIdUri = $ApiApplicationIdUri
        tenantId = $TenantId
        deviceTagExtensionAttribute = $DeviceTagExtensionAttribute
    }
    # Extract the resolved values for the management URL, API audience, tenant ID, and extension attribute.
    $url = Get-ConfigurationValue $configuration managementUrl 'ManagementUrl'
    # Extract the resolved management URL from the configuration.
    $audience = Get-ConfigurationValue $configuration apiApplicationIdUri 'ApiApplicationIdUri'
    # Extract the resolved API audience from the configuration.
    # Extract the resolved tenant ID from the configuration.
    # Determine the resolved extension attribute, falling back to 'extensionAttribute1' if not specified.
    $resolvedTenantId = Get-ConfigurationValue $configuration tenantId 'TenantId'
    # Extract the resolved tenant ID from the configuration.
    # Determine the resolved extension attribute, falling back to 'extensionAttribute1' if not specified.
    $resolvedExtensionAttribute = if (
        $PSBoundParameters.ContainsKey('DeviceTagExtensionAttribute') -and
        -not [string]::IsNullOrWhiteSpace([string] $DeviceTagExtensionAttribute)) {
        [string] $DeviceTagExtensionAttribute.Trim()
    }
    elseif ($configuration.ContainsKey('deviceTagExtensionAttribute') -and
        -not [string]::IsNullOrWhiteSpace([string] $configuration['deviceTagExtensionAttribute'])) {
        [string] $configuration['deviceTagExtensionAttribute'].Trim()
    }
    else {
        'extensionAttribute1'
    }
    $token = Get-ClientAccessToken $resolvedTenantId $audience
    $response = Invoke-RestMethod -Method Get -Uri $url.TrimEnd('/') `
        -Authentication Bearer -Token $token
    if ($Raw) {
        return $response
    }

    # Convert the response into an array of policy rules for further processing.
    $policy = @($response.policy)
    if ($policy.Count -eq 0) {
        return
    }

    # The Function API returns object IDs; a separate Graph token is required
    # only to enrich the human-facing output with group display names.
    $graphToken = Get-ClientAccessToken `
        $resolvedTenantId `
        'https://graph.microsoft.com/'
    # Iterate over each policy rule to enrich it with group display names and convert it to the client tag policy result.
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
        # Convert the enriched policy rule into the client tag policy result.
        ConvertTo-ClientTagPolicyResult `
            -Rule $rule `
            -GroupName $groupName `
            -ExtensionAttribute $resolvedExtensionAttribute `
            -CorrelationId $(if ($response.PSObject.Properties['correlationId']) {
                [string] $response.correlationId
            })
    }
}

function Get-AutoPilotTagPolicyHistory {
    <#
    .SYNOPSIS
    Returns one page of changes for a single policy rule.
    .DESCRIPTION
    Calls the manager-authorized REST history endpoint with the persistent rule
    ID returned by Get-AutoPilotTagPolicy. Returns only that rule's old/new
    values, actor, time and operation stage. Renaming preserves the ID.
    Pages may be empty with a continuation when other rules occupy the scanned
    storage page; continue until continuation is empty. Does not mutate rules.
    .PARAMETER RuleId
    Persistent non-empty rule GUID from Get-AutoPilotTagPolicy.
    .PARAMETER Continuation
    Opaque continuation from the previous response. Use with the same RuleId.
    .PARAMETER ManagementUrl
    HTTPS policy management endpoint; defaults to the client configuration.
    .PARAMETER ApiApplicationIdUri
    API audience; defaults to the client configuration.
    .PARAMETER TenantId
    Tenant for API authentication; defaults to the client configuration.
    .PARAMETER ConfigPath
    Optional client settings path.
    .EXAMPLE
    $rule = Get-AutoPilotTagPolicy | Select-Object -First 1
    Get-AutoPilotTagPolicyHistory -RuleId $rule.ruleId
    .OUTPUTS
    Response containing events, continuation and correlationId.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateScript({ $_ -ne [guid]::Empty })][guid] $RuleId,
        [ValidatePattern('^\d{19}-[0-9a-f-]{36}$')][string] $Continuation,
        [ValidatePattern('^https://')][string] $ManagementUrl,
        [ValidatePattern('^api://')][string] $ApiApplicationIdUri,
        [string] $TenantId,
        [string] $ConfigPath
    )
    # Build the request URI with the rule ID and optional continuation token.
    $configuration = Resolve-ClientConfiguration $ConfigPath @{
        managementUrl = $ManagementUrl; apiApplicationIdUri = $ApiApplicationIdUri; tenantId = $TenantId
    }
    # Extract the resolved values for the management URL, API audience, and tenant ID from the configuration.
    $url = Get-ConfigurationValue $configuration managementUrl 'ManagementUrl'
    # Extract the resolved management URL from the configuration.
    # Extract the resolved API audience from the configuration.
    # Extract the resolved tenant ID from the configuration.
    $audience = Get-ConfigurationValue $configuration apiApplicationIdUri 'ApiApplicationIdUri'
    $tenant = Get-ConfigurationValue $configuration tenantId 'TenantId'
    $uri = [UriBuilder]::new($url)
    $uri.Query = "history=true&ruleId=$RuleId"
    # Append the continuation token to the query string if provided.
    if ($Continuation) { $uri.Query = $uri.Query.TrimStart('?') + "&continuation=$([uri]::EscapeDataString($Continuation))" }
    # Acquire an access token for the API using the resolved tenant and audience.
    $token = Get-ClientAccessToken $tenant $audience
    # Invoke the REST API to retrieve the policy history using the constructed URI and access token.
    Invoke-RestMethod -Method Get -Uri $uri.Uri.AbsoluteUri -Authentication Bearer -Token $token -ErrorAction Stop
}

function Add-AutoPilotTagPolicy {
    <#
    .NOTES
    Performs a read/merge/replace of the full policy, preserving unrelated
    rules and their actions/AUs. Group-based shortcuts reject multiple named
    rules for one group because the target would be ambiguous. This is not an
    ETag compare-and-swap; simultaneous editors can race.

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

    # Normalize and validate the provided group tags before proceeding with the API request.
    $tags = @($GroupTag | ForEach-Object { $_.Split(',') } |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique)
    if ($tags.Count -eq 0) {
        throw 'Specify at least one Group Tag.'
    }
    # Ensure each group tag does not exceed the maximum allowed length of 128 characters.
    foreach ($tag in $tags) {
        if ($tag.Length -gt 128) {
            throw "Group Tag '$tag' must not exceed 128 characters."
        }
    }

    # Resolve the client configuration using the provided configuration path and any explicitly specified parameters.
    $configuration = Resolve-ClientConfiguration $ConfigPath @{
        managementUrl = $ManagementUrl
        apiApplicationIdUri = $ApiApplicationIdUri
        tenantId = $TenantId
    }
    # Extract the resolved management URL, API audience, and tenant ID from the configuration.
    $url = Get-ConfigurationValue $configuration managementUrl 'ManagementUrl'
    $audience = Get-ConfigurationValue $configuration apiApplicationIdUri 'ApiApplicationIdUri'
    $resolvedTenantId = Get-ConfigurationValue $configuration tenantId 'TenantId'
    # Acquire an access token for the API using the resolved tenant and audience.
    $apiToken = Get-ClientAccessToken $resolvedTenantId $audience
    # Convert the provided group ID to a string for consistent comparison and indexing.
    $resolvedGroupId = $GroupId.ToString()
    # Retrieve the current policy from the API for further processing and merging with local changes.
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
    $sourceRules = @{}
    # Check for duplicate group IDs in the current policy to prevent ambiguous updates.
    if (@($currentPolicy | Group-Object groupId | Where-Object Count -gt 1).Count -gt 0) {
        throw 'Multiple named rules share a user group. Use Set-AutoPilotTagPolicy with complete rule objects to avoid ambiguous updates.'
    }
    # Iterate through each rule in the current policy to build indexed collections for efficient merging and validation.
    foreach ($rule in $currentPolicy) {
        $currentGroupId = ([guid] $rule.groupId).ToString()
        $sourceRules[$currentGroupId] = $rule
        if ($currentGroupId -eq $resolvedGroupId -and $rule.PSObject.Properties['groupTag'] -and
            @($tags | Where-Object { $_ -ine $rule.groupTag }).Count -gt 0) {
            throw 'A named device-action rule has one Group Tag. Use Set-AutoPilotTagPolicy with complete rule objects to change it.'
        }
        $rulesByGroup[$currentGroupId] = @($rule.tags)
        $mauByGroup[$currentGroupId] = if ($rule.PSObject.Properties[
                'administrativeUnitName']) {
            [string] $rule.administrativeUnitName
        }
        else {
            ''
        }
    }
    # Merge the new tags into the existing rules for the resolved group ID, ensuring uniqueness and non-empty values.
    $rulesByGroup[$resolvedGroupId] = @(
        @($rulesByGroup[$resolvedGroupId]) + $tags |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) } |
            Select-Object -Unique
    )

    # Update the administrative unit name for the resolved group ID if explicitly specified.
    if ($PSBoundParameters.ContainsKey(
            'AdministrativeUnitName')) {
        $mauByGroup[$resolvedGroupId] =
            $AdministrativeUnitName.Trim()
    }
    # Construct the updated policy by combining the merged tags and administrative unit names with the original rule properties.
    $updatedPolicy = @($rulesByGroup.Keys | ForEach-Object {
        $policyEntry = [ordered]@{
            groupId = $_
            tags = @($rulesByGroup[$_])
        }
        if ($sourceRules.ContainsKey($_)) {
            foreach ($key in @('ruleId', 'name', 'description', 'groupTag', 'extensionAttributes', 'deviceGroupIds')) {
                if ($sourceRules[$_].PSObject.Properties[$key]) { $policyEntry[$key] = $sourceRules[$_].$key }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($mauByGroup[$_])) {
            $policyEntry.administrativeUnitName =
                $mauByGroup[$_].Trim()
        }
        [pscustomobject] $policyEntry
    })
    $body = @{
        policy = $updatedPolicy
    } | ConvertTo-Json -Depth 8 -Compress
    # Send the updated policy to the API and handle the response, including extracting the updated rule and correlation ID.
    if (-not $PSCmdlet.ShouldProcess(
            $resolvedGroupId,
            "Add Group Tags '$($tags -join ', ')' to the Autopilot policy")) {
        return
    }

    # Invoke the REST API to update the policy with the merged changes.
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
    # Extract the updated rule for the resolved group ID from the response policy.
    $updatedRule = @($responsePolicy | Where-Object {
        ([guid] $_.groupId).ToString() -eq $resolvedGroupId
    }) | Select-Object -First 1
    # Determine the extension attribute to use for device tagging, defaulting to 'extensionAttribute1' if not specified in the configuration.
    $resolvedExtensionAttribute = if (
        $configuration.ContainsKey('deviceTagExtensionAttribute') -and
        -not [string]::IsNullOrWhiteSpace([string] $configuration['deviceTagExtensionAttribute'])) {
        [string] $configuration['deviceTagExtensionAttribute'].Trim()
    }
    else {
        'extensionAttribute1'
    }
    # Convert the updated rule and extension attribute into a client-friendly result object for further processing or output.
    ConvertTo-ClientTagPolicyResult `
        -Rule $updatedRule `
        -ExtensionAttribute $resolvedExtensionAttribute `
        -CorrelationId $(if ($response.PSObject.Properties['correlationId']) {
            [string] $response.correlationId
        })
}

function Remove-AutoPilotTagPolicy {
    <#
    .NOTES
    Reads the latest complete policy, removes only the selected group/tags and
    preserves remaining actions/AUs. The final rule cannot be removed. Named
    rules sharing a group must be edited through complete rule objects instead
    of this ambiguous group-level shortcut.

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
    # Resolve the management URL, API audience, and tenant ID from the client configuration.
    $url = Get-ConfigurationValue $configuration managementUrl 'ManagementUrl'
    $audience = Get-ConfigurationValue $configuration apiApplicationIdUri 'ApiApplicationIdUri'
    $resolvedTenantId = Get-ConfigurationValue $configuration tenantId 'TenantId'
    $apiToken = Get-ClientAccessToken $resolvedTenantId $audience

    # Attempt to parse the provided group identifier as a GUID to determine if it is an object ID or a display name.
    $parsedGroupId = [guid]::Empty
    $groupDisplayName = $null
    # Initialize variables to hold the resolved group ID and display name.
    if ([guid]::TryParse($Group.Trim(), [ref] $parsedGroupId)) {
        $resolvedGroupId = $parsedGroupId.ToString()
    }
    else {
        # If the group identifier is not a GUID, treat it as a display name and attempt to resolve it via the Microsoft Graph API.
        $graphToken = Get-ClientAccessToken `
            $resolvedTenantId `
            'https://graph.microsoft.com/'
        # Acquire a Microsoft Graph API access token for the resolved tenant ID.
        # Escape the group display name to safely include it in the OData filter query.
        $escapedName = $Group.Trim().Replace("'", "''")
        $filter = [uri]::EscapeDataString("displayName eq '$escapedName'")
        # Construct the OData filter query for the Microsoft Graph API request.
        $groupResponse = Invoke-RestMethod `
            -Method Get `
            -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$filter&`$select=id,displayName" `
            -Authentication Bearer `
            -Token $graphToken `
            -ErrorAction Stop
        # Extract the list of matching groups from the API response.
        $matchingGroups = @($groupResponse.value)
        if ($matchingGroups.Count -eq 0) {
            throw "Entra group '$Group' was not found. Specify its exact display name or object ID."
        }
        if ($matchingGroups.Count -gt 1) {
            throw "Multiple Entra groups are named '$Group'. Specify the group object ID instead."
        }
        # Resolve the group ID and display name from the single matching group.
        $resolvedGroupId = ([guid] $matchingGroups[0].id).ToString()
        $groupDisplayName = [string] $matchingGroups[0].displayName
    }

    # Invoke the REST API to retrieve the current policy for the resolved group ID.
    $currentResponse = Invoke-RestMethod `
        -Method Get `
        -Uri $url.TrimEnd('/') `
        -Authentication Bearer `
        -Token $apiToken `
        -ErrorAction Stop
    # Extract the current policy from the API response.
    $currentPolicy = @($currentResponse.policy)
    # Find the policy rule that matches the resolved group ID.
    $matchingRule = @($currentPolicy | Where-Object {
        ([guid] $_.groupId).ToString() -eq $resolvedGroupId
    })
    if ($matchingRule.Count -eq 0) {
        throw "Entra group '$Group' does not have a Group Tag policy rule."
    }
    if ($matchingRule.Count -gt 1) {
        throw 'Multiple named rules match this group. Use Set-AutoPilotTagPolicy with complete rule objects.'
    }

    # Supplying GroupTag means a partial update; omitting it removes the entire
    # group rule while still preserving every unrelated rule.
    $removeTags = @()
    # Initialize the list of Group Tags to be removed.
    # Check if the GroupTag parameter was supplied.
    # If it was, process the tags to be removed by splitting, trimming, and ensuring uniqueness.
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

        # Extract the current list of Group Tags from the matching policy rule, ensuring they are trimmed, non-empty, and unique.
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
        # Construct the remaining policy by updating the tags for the resolved group ID while preserving other rules.
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
            # Preserve additional properties from the original policy rule if they exist.
            foreach ($key in @('ruleId', 'name', 'description', 'groupTag', 'extensionAttributes', 'deviceGroupIds')) {
                if ($_.PSObject.Properties[$key]) { $policyEntry[$key] = $_.$key }
            }
            # Preserve the administrativeUnitName property from the original policy rule if it exists and is not empty.
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
        # If no specific tags are being removed, construct the remaining policy by excluding the rule for the resolved group ID.
        $remainingPolicy = @($currentPolicy | Where-Object {
            ([guid] $_.groupId).ToString() -ne $resolvedGroupId
        })
        # Check if the remaining policy is empty, which would indicate that the last group tag policy rule is being removed.
        if ($remainingPolicy.Count -eq 0) {
            throw 'The last Group Tag policy rule cannot be removed. Use Set-AutoPilotTagPolicy to replace the policy.'
        }
    }
    # Prepare the request body for the API call with the remaining policy.
    $body = @{
        policy = $remainingPolicy
    } | ConvertTo-Json -Depth 8 -Compress

    $target = if ([string]::IsNullOrWhiteSpace($groupDisplayName)) {
        $resolvedGroupId
    }
    else {
        "$groupDisplayName ($resolvedGroupId)"
    }
    # Determine the operation description for the ShouldProcess confirmation.
    $operation = if ($removeTags.Count -gt 0) {
        "Remove Group Tags '$($removeTags -join ', ')' from the Autopilot policy"
    }
    else {
        'Remove the group from the Autopilot Group Tag policy'
    }
    if (-not $PSCmdlet.ShouldProcess($target, $operation)) {
        return
    }
    # Perform the API call to update the Autopilot tag policy with the remaining policy.
    $response = Invoke-RestMethod `
        -Method Put `
        -Uri $url.TrimEnd('/') `
        -Authentication Bearer `
        -Token $apiToken `
        -ContentType 'application/json' `
        -Body $body `
        -ErrorAction Stop

    # Extract the group label for display purposes based on whether the group display name is available.
    $groupLabel = if ([string]::IsNullOrWhiteSpace($groupDisplayName)) {
        $resolvedGroupId
    }
    else {
        $groupDisplayName
    }
    # Construct the message to be displayed based on the number of tags being removed.
    $message = if ($removeTags.Count -eq 0) {
        "The tag policy for group '$groupLabel' was removed."
    }
    elseif ($removeTags.Count -eq 1) {
        "Group Tag '$($removeTags[0])' was removed from the tag policy for group '$groupLabel'."
    }
    else {
        "Group Tags '$($removeTags -join ', ')' were removed from the tag policy for group '$groupLabel'."
    }
    # Attach additional metadata to the message object, including group ID, group name, removed tags, rule removal status, correlation ID, update status, and the API response.
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
    .PARAMETER GroupName
    Exact Entra group display name or object ID for updating one existing
    group's tags. Must be used together with Tags instead of TagAuthorizationRule.

    .PARAMETER Tags
    Complete replacement tag list for GroupName. Accepts comma-separated
    entries. Named action rules require exactly one Group Tag.

    .NOTES
    Group mode replaces that group's tags while preserving unrelated rules and
    action metadata. Full-rule mode delegates validation to the shared runtime
    parser and serializes its existing flat array without another wrapper.
    Writes are gated by ShouldProcess; successful writes reload server state.

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
    Named device-action rules accept name, groupId, groupTag,
    extensionAttributes as an attribute-to-value map, and deviceGroupIds as
    target device group object IDs. A Group Tag is required.
    Intune Scope Tags are not managed.

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
        [object[]] $TagAuthorizationRule,
        [string] $GroupName,
        [Alias('Tag')]
        [string[]] $Tags,
        [Alias('Mau')]
        [string] $AdministrativeUnitName,
        [ValidatePattern('^https://')][string] $ManagementUrl,
        [ValidatePattern('^api://')][string] $ApiApplicationIdUri,
        [string] $TenantId,
        [string] $ConfigPath
    )
    # Determine if the command is operating in group update mode based on the presence of -GroupName and -Tags parameters.
    $groupUpdateMode = $PSBoundParameters.ContainsKey('GroupName') -or
        $PSBoundParameters.ContainsKey('Tags')
    # $groupUpdateMode will be $true if either -GroupName or -Tags is specified, indicating that the command is updating a single group rule.
    if ($groupUpdateMode -and $PSBoundParameters.ContainsKey('TagAuthorizationRule')) {
        throw 'Use either -TagAuthorizationRule or -GroupName with -Tags, not both.'
    }
    #   If $groupUpdateMode is $true, the command expects -GroupName and -Tags to be specified.
    #   If $groupUpdateMode is $false, the command expects -TagAuthorizationRule to be specified.
    if ($groupUpdateMode -and (
            -not $PSBoundParameters.ContainsKey('GroupName') -or
            -not $PSBoundParameters.ContainsKey('Tags'))) {
        throw 'Specify both -GroupName and -Tags when updating a single rule.'
    }
    # Resolve the client configuration using the provided configuration path and override values for management URL, API application ID URI, and tenant ID.
    if (-not $groupUpdateMode -and -not $PSBoundParameters.ContainsKey('TagAuthorizationRule')) {
        throw 'Specify either -TagAuthorizationRule or -GroupName with -Tags.'
    }

    $configuration = Resolve-ClientConfiguration $ConfigPath @{
        managementUrl = $ManagementUrl; apiApplicationIdUri = $ApiApplicationIdUri; tenantId = $TenantId
    }
    # Retrieve the resolved values for management URL, API application ID URI, and tenant ID from the configuration.
    $url = Get-ConfigurationValue $configuration managementUrl 'ManagementUrl'
    $audience = Get-ConfigurationValue $configuration apiApplicationIdUri 'ApiApplicationIdUri'
    $resolvedTenantId = Get-ConfigurationValue $configuration tenantId 'TenantId'
    # Obtain the client access token using the resolved tenant ID and audience.
    $token = Get-ClientAccessToken $resolvedTenantId $audience

    # If the command is operating in group update mode, normalize the tags and resolve the group ID.
    #   Normalizing the tags involves splitting the comma-separated list, trimming whitespace, and removing empty entries.
    #   Resolving the group ID involves checking if the provided group name is a valid GUID or querying the Microsoft Graph API for the group ID based on the display name.
    if ($groupUpdateMode) {
        $normalizedTags = @($Tags | ForEach-Object { $_.Split(',') } |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique)
        if ($normalizedTags.Count -eq 0) {
            throw 'Specify at least one tag in -Tags.'
        }

        $resolvedGroupId = $null
        $parsedGroupId = [guid]::Empty
        if ([guid]::TryParse($GroupName.Trim(), [ref] $parsedGroupId)) {
            $resolvedGroupId = $parsedGroupId.ToString()
        }
        else {
            # If the group name is not a valid GUID, query the Microsoft Graph API to resolve the group ID based on the display name.
            $graphToken = Get-ClientAccessToken $resolvedTenantId 'https://graph.microsoft.com/'
            $escapedName = $GroupName.Trim().Replace("'", "''")
            $filter = [uri]::EscapeDataString("displayName eq '$escapedName'")
            # Construct the filter query for the Microsoft Graph API request to search for the group by display name.
            $groupResponse = Invoke-RestMethod `
                -Method Get `
                -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$filter&`$select=id,displayName" `
                -Authentication Bearer `
                -Token $graphToken `
                -ErrorAction Stop
            $matchingGroups = if ($groupResponse.PSObject.Properties['value']) {
                @($groupResponse.value)
            }
            else {
                @($groupResponse)
            }
            # Ensure that exactly one matching group was found and retrieve its ID.
            if ($matchingGroups.Count -eq 0) {
                throw "Entra group '$GroupName' was not found. Specify its exact display name or object ID."
            }
            # At this point, $matchingGroups contains exactly one group, and its ID is stored in $resolvedGroupId.
            if ($matchingGroups.Count -gt 1) {
                throw "Multiple Entra groups are named '$GroupName'. Specify the group object ID instead."
            }
            $resolvedGroupId = ([guid] $matchingGroups[0].id).ToString()
        }

        # Retrieve the current Group Tag policy for the resolved group ID.
        $currentResponse = Invoke-RestMethod `
            -Method Get `
            -Uri $url.TrimEnd('/') `
            -Authentication Bearer `
            -Token $token `
            -ErrorAction Stop
        # The response contains the current policy, which will be used to determine the matching rule and prepare the updated policy.
        $currentPolicy = @($currentResponse.policy)
        # Find the policy rule that matches the resolved group ID.
        $matchingRule = @($currentPolicy | Where-Object {
            ([guid] $_.groupId).ToString() -eq $resolvedGroupId
        })
        # Ensure that exactly one matching rule is found for the group.
        if ($matchingRule.Count -eq 0) {
            throw "Entra group '$GroupName' does not have a Group Tag policy rule."
        }
        if ($matchingRule.Count -gt 1) {
            throw 'Multiple named rules match this group. Use Set-AutoPilotTagPolicy with complete rule objects.'
        }
        # Prepare the updated policy by modifying the matching rule with the new tags and preserving other properties.
        $updatedPolicy = @($currentPolicy | ForEach-Object {
            $ruleGroupId = ([guid] $_.groupId).ToString()
            if ($ruleGroupId -ne $resolvedGroupId) {
                return $_
            }

            $policyEntry = [ordered]@{
                groupId = $resolvedGroupId
                tags = @($normalizedTags)
            }
            foreach ($key in @('ruleId', 'name', 'description', 'groupTag', 'extensionAttributes', 'deviceGroupIds')) {
                if ($_.PSObject.Properties[$key]) { $policyEntry[$key] = $_.$key }
            }
            if ($policyEntry.Contains('groupTag')) {
                if ($normalizedTags.Count -ne 1) { throw 'Named device-action rules require exactly one Group Tag.' }
                $policyEntry.groupTag = $normalizedTags[0]
            }
            if ($PSBoundParameters.ContainsKey('AdministrativeUnitName') -and
                -not [string]::IsNullOrWhiteSpace([string] $AdministrativeUnitName)) {
                $policyEntry.administrativeUnitName = $AdministrativeUnitName.Trim()
            }
            elseif ($_.PSObject.Properties['administrativeUnitName'] -and
                -not [string]::IsNullOrWhiteSpace([string] $_.administrativeUnitName)) {
                $policyEntry.administrativeUnitName = ([string] $_.administrativeUnitName).Trim()
            }

            [pscustomobject] $policyEntry
        })

        # Convert the updated policy to JSON for the API request body.
        $body = @{
            policy = $updatedPolicy
        } | ConvertTo-Json -Depth 8 -Compress
        # Prompt the user for confirmation before making the API request to update the policy.
        if (-not $PSCmdlet.ShouldProcess(
                $resolvedGroupId,
                "Update Group Tags '$($normalizedTags -join ', ')' for the Autopilot policy")) {
            return
        }

        # Make the API request to update the policy with the new tags.
        Invoke-RestMethod -Method Put -Uri $url.TrimEnd('/') -Authentication Bearer `
            -Token $token -ContentType 'application/json' -Body $body
        # Retrieve the fresh policy after the update to ensure the changes were applied.
        $freshPolicy = Get-AutoPilotTagPolicy `
            -ManagementUrl $url `
            -ApiApplicationIdUri $audience `
            -TenantId $resolvedTenantId
        return $freshPolicy
    }

    # Reuse the runtime module's policy parser so client-side validation stays
    # identical to the Function's accepted rule format.
    $coreModulePath = Get-CoreModulePath
    Import-Module $coreModulePath -Force
    # Convert the tag authorization rules to the policy format expected by the API.
    $policy = ConvertTo-TagAuthorizationPolicy `
        -Rules $TagAuthorizationRule `
        -AdministrativeUnitName `
            $AdministrativeUnitName
    # Prompt the user for confirmation before replacing the tag authorization policy.
    if (-not $PSCmdlet.ShouldProcess($url, "Replace tag authorization policy with $($policy.Count) group rule(s)")) {
        return
    }
    # Convert the policy to JSON for the API request body.
    $body = @{
        policy = $policy
    } | ConvertTo-Json -Depth 8 -Compress
    # Make the API request to replace the tag authorization policy.
    Invoke-RestMethod -Method Put -Uri $url.TrimEnd('/') -Authentication Bearer `
        -Token $token -ContentType 'application/json' -Body $body
    # Retrieve the fresh policy after the replacement to ensure the changes were applied.
    $freshPolicy = Get-AutoPilotTagPolicy `
        -ManagementUrl $url `
        -ApiApplicationIdUri $audience `
        -TenantId $resolvedTenantId
    return $freshPolicy
}

function Get-AutoPilotTagPolicyManager {
    <#
    .NOTES
    Uses ARM application settings rather than the policy HTTP endpoint.
    Missing deployment coordinates are discovered from the configured hostname
    and cached for later calls. The installer and additional principals are
    projected separately; malformed manager JSON is an explicit error.

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

    # Ensure that the required client commands are available before proceeding.
    Assert-ClientCommand -Name 'Get-AzWebApp', 'Set-AzContext'
    # Resolve the client configuration using the provided configuration path and any explicitly supplied parameters.
    $configuration = Resolve-ClientConfiguration $ConfigPath @{
        subscriptionId = $SubscriptionId; tenantId = $TenantId
        resourceGroupName = $ResourceGroupName; functionAppName = $FunctionAppName
    }
    # Identify any missing deployment values that are required for the Function App.
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
    # Throw an error if any required deployment values are missing.
    if ($missingDeploymentValues.Count -gt 0) {
        $configuredFunctionUrl = [string] $configuration['functionUrl']
        $configuredTenantId = Get-ConfigurationValue `
            $configuration tenantId 'TenantId'
        # Throw an error if the Function App URL is not configured.
        if ([string]::IsNullOrWhiteSpace($configuredFunctionUrl)) {
            throw "Azure deployment details required by manager-policy commands are missing: $($missingDeploymentValues -join ', '). Pass -SubscriptionId, -ResourceGroupName, and -FunctionAppName explicitly."
        }
        # Resolve the deployment details for the Function App using the configured URL.
        $deployment = Resolve-ClientFunctionAppFromUrl `
            -FunctionUrl $configuredFunctionUrl `
            -TenantId $configuredTenantId `
            -SubscriptionId ([string] $configuration['subscriptionId'])
        $configuration['subscriptionId'] = $deployment.SubscriptionId
        $configuration['resourceGroupName'] = $deployment.ResourceGroupName
        $configuration['functionAppName'] = $deployment.FunctionAppName
        # Save the resolved deployment details back to the configuration.
        Save-ClientDeploymentConfiguration `
            -Configuration $configuration `
            -Deployment $deployment
    }
    # Retrieve the resolved deployment details from the configuration for further use.
    # Get the subscription ID, tenant ID, resource group name, and function app name from the configuration.
    $resolvedSubscriptionId = Get-ConfigurationValue `
        $configuration subscriptionId 'SubscriptionId'
    $resolvedTenantId = Get-ConfigurationValue `
        $configuration tenantId 'TenantId'
    $resolvedResourceGroup = Get-ConfigurationValue `
        $configuration resourceGroupName 'ResourceGroupName'
    $resolvedFunctionName = Get-ConfigurationValue `
        $configuration functionAppName 'FunctionAppName'

    # Acquire an access token for the Azure management API using the resolved tenant ID and subscription ID.
    [void](Get-ClientAccessToken `
        $resolvedTenantId `
        'https://management.azure.com/' `
        $resolvedSubscriptionId)
    # Set the Azure context to the resolved tenant ID and subscription ID.
    Set-AzContext `
        -Tenant $resolvedTenantId `
        -Subscription $resolvedSubscriptionId `
        -WhatIf:$false | Out-Null
    # Retrieve the Function App using the resolved resource group and function app name.
    $functionApp = Get-AzWebApp `
        -ResourceGroupName $resolvedResourceGroup `
        -Name $resolvedFunctionName
    if (-not $functionApp) {
        throw "Function App '$resolvedFunctionName' was not found."
    }
    # Retrieve the existing manager authorization policy from the Function App's app settings.
    $managerPolicySetting = @($functionApp.SiteConfig.AppSettings |
        Where-Object Name -eq 'MANAGER_AUTHORIZATION_POLICY' |
        Select-Object -First 1)
    if ($managerPolicySetting.Count -eq 0) {
        throw "Function App '$resolvedFunctionName' does not contain MANAGER_AUTHORIZATION_POLICY."
    }
    # Parse the manager authorization policy JSON and extract the installer and additional principal IDs.
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
    .NOTES
    Resolves the signed-in principal from the ARM token and checks effective
    Owner/Contributor assignments against the Function resource before writing.
    Uses the authenticated management API so browser and client mutations share
    permanent backend auditing. Expected-policy checks detect stale manager
    lists; external ARM app-setting writes are not transactionally protected.

    .SYNOPSIS
    Adds and removes explicit Group Tag managers through the audited API.

    .DESCRIPTION
    Updates the MANAGER_AUTHORIZATION_POLICY application setting of an existing
    Autopilot Import Function App. The command preserves the installing user and
    existing Intune Role Administrator flag, and verifies that the caller
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
    # Convert the provided principal IDs to strings and ensure at least one ID is specified for addition or removal.
    Assert-ClientCommand -Name 'Get-AzWebApp', 'Get-AzRoleAssignment', 'Set-AzContext'
    # Ensure that the required client commands are available before proceeding.
    $addIds = @($AddPrincipalId | Where-Object { $null -ne $_ } |
        ForEach-Object { $_.ToString() })
    # Convert the principal IDs to strings for consistent processing.
    $removeIds = @($RemovePrincipalId | Where-Object { $null -ne $_ } |
        ForEach-Object { $_.ToString() })
    # Ensure that at least one principal ID is specified for addition or removal.
    if ($addIds.Count -eq 0 -and $removeIds.Count -eq 0) {
        throw 'Specify at least one principal ID to add or remove.'
    }
    # Resolve the client configuration using the provided configuration path and deployment details.
    $configuration = Resolve-ClientConfiguration $ConfigPath @{
        subscriptionId = $SubscriptionId; tenantId = $TenantId
        resourceGroupName = $ResourceGroupName; functionAppName = $FunctionAppName
    }
    # Check for any missing deployment values in the resolved configuration.
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
        # Retrieve the configured function URL and tenant ID from the resolved configuration.
        $configuredFunctionUrl = [string] $configuration['functionUrl']
        $configuredTenantId = Get-ConfigurationValue `
            $configuration tenantId 'TenantId'
        # If the function URL is missing, throw an error indicating the required deployment details are missing.
        if ([string]::IsNullOrWhiteSpace($configuredFunctionUrl)) {
            throw "Azure deployment details required by manager-policy commands are missing: $($missingDeploymentValues -join ', '). Pass -SubscriptionId, -ResourceGroupName, and -FunctionAppName explicitly."
        }
        Write-Verbose "Discovering Azure Function App deployment details for '$configuredFunctionUrl'."
        # Resolve the client function app deployment details from the function URL.
        $deployment = Resolve-ClientFunctionAppFromUrl `
            -FunctionUrl $configuredFunctionUrl `
            -TenantId $configuredTenantId `
            -SubscriptionId ([string] $configuration['subscriptionId'])
        # Update the configuration with the resolved deployment details.
        $configuration['subscriptionId'] = $deployment.SubscriptionId
        $configuration['resourceGroupName'] = $deployment.ResourceGroupName
        $configuration['functionAppName'] = $deployment.FunctionAppName
        # Save the updated client deployment configuration.
        Save-ClientDeploymentConfiguration `
            -Configuration $configuration `
            -Deployment $deployment
    }
    # Retrieve the resolved deployment details from the configuration for subsequent operations.
    $resolvedSubscriptionId = Get-ConfigurationValue $configuration subscriptionId 'SubscriptionId'
    $resolvedTenantId = Get-ConfigurationValue $configuration tenantId 'TenantId'
    $resolvedResourceGroup = Get-ConfigurationValue $configuration resourceGroupName 'ResourceGroupName'
    $resolvedFunctionName = Get-ConfigurationValue $configuration functionAppName 'FunctionAppName'

    # Acquire an access token for the Azure management API using the resolved tenant and subscription.
    [void](Get-ClientAccessToken $resolvedTenantId 'https://management.azure.com/' $resolvedSubscriptionId)
    # Set the Azure context to the resolved tenant and subscription.
    Set-AzContext -Tenant $resolvedTenantId -Subscription $resolvedSubscriptionId -WhatIf:$false | Out-Null
    # Retrieve the function app instance using the resolved resource group and function app name.
    $functionApp = Get-AzWebApp -ResourceGroupName $resolvedResourceGroup -Name $resolvedFunctionName
    if (-not $functionApp) { throw "Function App '$resolvedFunctionName' was not found." }
    # Acquire an access token for the Azure management API to interact with the function app.

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
    # Import the core module to access shared functions and utilities.
    if (-not (Test-TagManagerPolicyAdministratorRole $assignments $functionApp.Id)) {
        throw "Only an Owner or Contributor of Function App '$resolvedFunctionName' may change its Group Tag managers."
    }

    # Retrieve the current application settings from the function app.
    $appSettings = @{}
    # Initialize an empty hashtable to store the application settings.
    foreach ($setting in @($functionApp.SiteConfig.AppSettings)) {
        $appSettings[[string] $setting.Name] = [string] $setting.Value
    }
    # Ensure that the MANAGER_AUTHORIZATION_POLICY setting exists in the application settings.
    if (-not $appSettings.ContainsKey('MANAGER_AUTHORIZATION_POLICY')) {
        throw "Function App '$resolvedFunctionName' does not contain MANAGER_AUTHORIZATION_POLICY."
    }
    # Attempt to parse the existing MANAGER_AUTHORIZATION_POLICY from the application settings.
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
    # Construct the updated policy object with the installer and additional principal IDs.
    $updatedPolicy = [ordered]@{
        installerPrincipalId = $installerId
        additionalPrincipalIds = $updatedIds
        allowIntuneRoleAdministrators = [bool] $currentPolicy.allowIntuneRoleAdministrators
    }
    # If the user confirms the action, proceed to update the policy on the function app.
    if ($PSCmdlet.ShouldProcess("$resolvedResourceGroup/$resolvedFunctionName", 'Update Group Tag managers')) {
        $audience = [string] $appSettings['API_AUDIENCE']
        if ($audience -notmatch '^api://') { throw 'Function API_AUDIENCE is required for audited manager changes.' }
        $apiToken = Get-ClientAccessToken $resolvedTenantId $audience $resolvedSubscriptionId
        $uri = "https://$resolvedFunctionName.azurewebsites.net/api/management/policy-managers"
        $response = Invoke-RestMethod -Method Put -Uri $uri -Authentication Bearer -Token $apiToken `
            -Headers @{ 'x-autopilot-arm-token' = $plainToken } -ContentType 'application/json' `
            -Body (ConvertTo-Json -InputObject @{
                additionalPrincipalIds = $updatedIds
                expectedPolicy = $appSettings.MANAGER_AUTHORIZATION_POLICY
            } -Depth 8 -Compress) -ErrorAction Stop
        $updatedPolicy = $response.policy
    }
    # Return the updated policy object along with the function app name.
    [pscustomobject]@{ FunctionAppName = $resolvedFunctionName; ManagerPolicy = $updatedPolicy }
}

function Add-AutoPilotTagPolicyManager {
    <#
    .NOTES
    Delegates authorization, merge and persistence to
    Update-AutoPilotTagPolicyManager. Forwards explicitly bound parameters and
    common WhatIf/Confirm behavior rather than duplicating app-setting writes.

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
    # Prepare the parameters for the Update-AutoPilotTagPolicyManager call, including any explicitly bound optional connection parameters.
    $parameters = @{ AddPrincipalId = $PrincipalId; Confirm = $false }
    # Iterate over the optional connection parameters and add any that were explicitly bound to the parameters hashtable.
    foreach ($name in @(
            'SubscriptionId', 'TenantId', 'ResourceGroupName',
            'FunctionAppName', 'ConfigPath'
        )) {
        if ($PSBoundParameters.ContainsKey($name)) {
            $parameters[$name] = $PSBoundParameters[$name]
        }
    }
    # If the WhatIf preference is set, include it in the parameters to preview the changes.
    if ($WhatIfPreference) {
        $parameters.WhatIf = $true
    }
    # Call the Update-AutoPilotTagPolicyManager function with the prepared parameters.
    Update-AutoPilotTagPolicyManager @parameters
}

function Remove-AutoPilotTagPolicyManager {
    <#
    .NOTES
    Delegates to Update-AutoPilotTagPolicyManager so installer protection and
    the effective Azure-role check cannot diverge between add/remove commands.
    Only explicitly bound optional connection parameters are forwarded.

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
    # Prepare the parameters for the Update-AutoPilotTagPolicyManager call, including any explicitly bound optional connection parameters.
    $parameters = @{ RemovePrincipalId = $PrincipalId; Confirm = $false }
    # Iterate over the optional connection parameters and add any that were explicitly bound to the parameters hashtable.
    foreach ($name in @(
            'SubscriptionId', 'TenantId', 'ResourceGroupName',
            'FunctionAppName', 'ConfigPath'
        )) {
        if ($PSBoundParameters.ContainsKey($name)) {
            $parameters[$name] = $PSBoundParameters[$name]
        }
    }
    # If the WhatIf preference is set, include it in the parameters to preview the changes.
    if ($WhatIfPreference) {
        $parameters.WhatIf = $true
    }
    # Call the Update-AutoPilotTagPolicyManager function with the prepared parameters.
    Update-AutoPilotTagPolicyManager @parameters
}

function Get-ClientConfigurationBackupContext {
    <#
    .SYNOPSIS
    Resolves the backup endpoint and both caller authentication tokens.
    .DESCRIPTION
    Loads client settings and overrides, validates the target HTTPS URL and
    acquires API and delegated ARM tokens. Custom hostnames are retained.
    .PARAMETER ManagementUrl
    Explicit site, UI or management URL overriding client settings.
    .PARAMETER ApiApplicationIdUri
    Explicit Function API audience overriding client settings.
    .PARAMETER TenantId
    Explicit Entra tenant overriding client settings.
    .PARAMETER ConfigPath
    Optional client.settings.json path.
    .OUTPUTS
    Hashtable of Invoke-RestMethod endpoint, authentication and error parameters.
    #>
    param(
        [string] $ManagementUrl,
        [string] $ApiApplicationIdUri,
        [string] $TenantId,
        [string] $ConfigPath
    )
    # Resolve the client configuration and prepare the backup context for the AutoPilot configuration export.
    $configuration = Resolve-ClientConfiguration $ConfigPath @{
        managementUrl = $ManagementUrl; apiApplicationIdUri = $ApiApplicationIdUri; tenantId = $TenantId
    }
    # Extract the management URL, API audience, and tenant ID from the resolved configuration.
    $url = if ($ManagementUrl) { $ManagementUrl } else {
        Get-ConfigurationValue $configuration managementUrl 'ManagementUrl'
    }
    # Convert the management URL to a URI object for validation and further processing.
    $audience = Get-ConfigurationValue $configuration apiApplicationIdUri 'ApiApplicationIdUri'
    $resolvedTenantId = Get-ConfigurationValue $configuration tenantId 'TenantId'
    $uri = [uri] $url
    # Validate that the URI is absolute, uses HTTPS, and does not contain user info, query, or fragment components.
    # Also ensure the path matches the expected API structure for site, UI, or management endpoints.
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
        $uri.AbsolutePath -notmatch '^/(?:api/(?:ui(?:/.*)?|management(?:/(?:tag-policy|policy-managers))?))?/?$') {
        throw 'ManagementUrl must be an HTTPS site, UI, or supported management endpoint without query parameters.'
    }
    $apiToken = Get-ClientAccessToken $resolvedTenantId $audience
    $armToken = Get-ClientAccessToken $resolvedTenantId 'https://management.azure.com/'
    $plainArmToken = if ($armToken -is [Security.SecureString]) {
        ConvertFrom-SecureString $armToken -AsPlainText
    } else { [string] $armToken }
    @{
        Uri = "$($uri.GetLeftPart([UriPartial]::Authority))/api/management/policy-managers?backup=true"
        Authentication = 'Bearer'
        Token = $apiToken
        Headers = @{ 'x-autopilot-arm-token' = $plainArmToken }
        ErrorAction = 'Stop'
    }
}

function Export-AutoPilotConfiguration {
    <#
    .SYNOPSIS
    Exports all rules and the policy-manager configuration to a JSON file.
    .DESCRIPTION
    Uses the delegated Owner/Contributor-protected backup API. The versioned
    JSON contains tenant/source metadata, normalized rules with stable IDs and
    the manager policy, not credentials, app settings, devices or audit history.
    Existing files are never overwritten unless Force is supplied.
    .PARAMETER Path
    Destination JSON file in an existing filesystem directory.
    .PARAMETER Force
    Allows overwriting an existing backup file.
    .PARAMETER ManagementUrl
    HTTPS Function site, UI or management URL; defaults to client settings.
    .PARAMETER ApiApplicationIdUri
    Function API audience; defaults to client settings.
    .PARAMETER TenantId
    Entra tenant for API and delegated ARM sign-in.
    .PARAMETER ConfigPath
    Optional client.settings.json path.
    .EXAMPLE
    Export-AutoPilotConfiguration -Path '.\autopilot-backup.json'
    .OUTPUTS
    System.IO.FileInfo for the exported JSON file, unless WhatIf is specified.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Path,
        [switch] $Force,
        [ValidatePattern('^https://')][string] $ManagementUrl,
        [ValidatePattern('^api://')][string] $ApiApplicationIdUri,
        [string] $TenantId,
        [string] $ConfigPath
    )
    # Resolve the destination path for the backup JSON file and check for existing files if -Force is not specified.
    $destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    # Ensure the directory for the destination path exists.
    if (-not $Force -and [IO.File]::Exists($destination)) { throw "Backup file already exists: $destination. Use -Force to replace it." }
    if ($PSCmdlet.ShouldProcess($destination, 'Export rules and policy managers as JSON')) {
        $context = Get-ClientConfigurationBackupContext -ManagementUrl $ManagementUrl `
            -ApiApplicationIdUri $ApiApplicationIdUri -TenantId $TenantId -ConfigPath $ConfigPath
        $response = Invoke-RestMethod @context -Method Get |
            ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($response -isnot [Collections.IDictionary] -or $response['backup'] -isnot [Collections.IDictionary] -or
            $response['backup']['format'] -cne 'autopilot-importer-configuration' -or
            $response['backup']['schemaVersion'] -ne 1 -or $response['backup']['rules'] -isnot [array] -or
            $response['backup']['managerPolicy'] -isnot [Collections.IDictionary]) {
            throw 'The server did not return a supported configuration backup.'
        }
        $json = ConvertTo-Json -InputObject $response['backup'] -Depth 30
        $mode = if ($Force) { [IO.FileMode]::Create } else { [IO.FileMode]::CreateNew }
        $stream = [IO.File]::Open($destination, $mode, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
            $stream.Write($bytes, 0, $bytes.Length)
        } finally { $stream.Dispose() }
        Get-Item -LiteralPath $destination
    }
}

function Restore-AutoPilotConfiguration {
    <#
    .SYNOPSIS
    Replaces rules and additional policy managers from a JSON backup.
    .DESCRIPTION
    Supports other installations in the same tenant, retaining the destination
    installer. Reads fresh destination concurrency values before PUT. Requires
    delegated Azure Owner/Contributor access, not only policy-manager rights.
    Storage and app-setting writes are not atomic. An error may mean a partial
    restore or missing audit confirmation; inspect configuration/history before
    retrying. Updating managers can restart the Function App. WhatIf performs
    no network requests or writes and does not validate directory objects.
    .PARAMETER Path
    JSON file created by Export-AutoPilotConfiguration.
    .PARAMETER ManagementUrl
    Target HTTPS site, UI or management URL; defaults to client settings.
    .PARAMETER ApiApplicationIdUri
    Target API audience; defaults to client settings.
    .PARAMETER TenantId
    Entra tenant for API and delegated ARM sign-in.
    .PARAMETER ConfigPath
    Optional target client.settings.json path.
    .EXAMPLE
    Restore-AutoPilotConfiguration -Path '.\autopilot-backup.json' -WhatIf
    .EXAMPLE
    Restore-AutoPilotConfiguration -Path '.\autopilot-backup.json'
    .OUTPUTS
    Hashtable containing confirmed restore states and the server correlation ID.
    No success object is returned for WhatIf or unconfirmed/partial restores.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string] $Path,
        [ValidatePattern('^https://')][string] $ManagementUrl,
        [ValidatePattern('^api://')][string] $ApiApplicationIdUri,
        [string] $TenantId,
        [string] $ConfigPath
    )
    # Read the backup JSON file and validate its structure before proceeding with the restore operation.
    $backup = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    # Validate that the backup content is a hashtable with the expected format, schema version, rules array, and manager policy dictionary.
    if ($backup -isnot [Collections.IDictionary] -or
        $backup['format'] -cne 'autopilot-importer-configuration' -or $backup['schemaVersion'] -ne 1 -or
        $backup['rules'] -isnot [array] -or $backup['managerPolicy'] -isnot [Collections.IDictionary]) {
        throw 'The file is not a supported configuration backup.'
    }
    # Determine the target for the restore operation, using the management URL if provided, or a default description otherwise.
    $target = if ($ManagementUrl) { $ManagementUrl } else { 'configured Function App' }
    # Prompt for confirmation and proceed with the restore operation if approved.
    if ($PSCmdlet.ShouldProcess($target, 'Replace all rules and additional policy managers from backup')) {
        $context = Get-ClientConfigurationBackupContext -ManagementUrl $ManagementUrl `
            -ApiApplicationIdUri $ApiApplicationIdUri -TenantId $TenantId -ConfigPath $ConfigPath
        $current = Invoke-RestMethod @context -Method Get |
            ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($current -isnot [Collections.IDictionary] -or $current['expectedRules'] -isnot [array] -or
            $current['expectedPolicy'] -isnot [string]) {
            throw 'The target did not return configuration concurrency values.'
        }
        # Prepare the request body for the restore operation, including the backup content and the expected concurrency values.
        $body = ConvertTo-Json -InputObject @{
            backup = $backup
            expectedRules = @($current['expectedRules'])
            expectedPolicy = $current['expectedPolicy']
        } -Depth 30 -Compress
        # Invoke the REST method to perform the restore operation and capture the result.
        $result = Invoke-RestMethod @context -Method Put -ContentType 'application/json; charset=utf-8' `
            -Body ([Text.Encoding]::UTF8.GetBytes($body)) |
            ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        # Validate the result of the restore operation to ensure it was successful and all rules and managers were applied.
        if ($result -isnot [Collections.IDictionary] -or $result['restored'] -ne $true -or
            $result['rulesState'] -ne 'applied' -or $result['managersState'] -ne 'applied') {
            throw 'The target did not confirm a complete restore. Reload configuration and management history before retrying.'
        }
        $result
    }
}

Export-ModuleMember -Function @(
    'New-AutoPilotImporterClientConfiguration',
    'Get-AutoPilotImporterClientConfiguration',
    'Import-AutoPilotDevice',
    'Get-AutoPilotDeviceTagAssignment',
    'Set-AutoPilotDeviceGroupTag',
    'Get-AutoPilotImportStatus',
    'Get-AutoPilotImportHistory',
    'Get-AutoPilotTagPolicy',
    'Get-AutoPilotTagPolicyHistory',
    'Add-AutoPilotTagPolicy',
    'Remove-AutoPilotTagPolicy',
    'Set-AutoPilotTagPolicy',
    'Get-AutoPilotTagPolicyManager',
    'Update-AutoPilotTagPolicyManager',
    'Add-AutoPilotTagPolicyManager',
    'Remove-AutoPilotTagPolicyManager',
    'Export-AutoPilotConfiguration',
    'Restore-AutoPilotConfiguration'
)
