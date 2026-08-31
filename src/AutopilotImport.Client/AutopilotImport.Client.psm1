#Requires -Version 7.2
# Project-Version: 1.0.20260831.1
# Author: andreas.lucas@microsoft.com (aka Kili)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-ClientCommand {
    param([Parameter(Mandatory)][string[]] $Name)

    $missing = @($Name | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missing.Count -gt 0) {
        throw "Required PowerShell commands are missing: $($missing -join ', '). Install the corresponding Az modules."
    }
}

function Resolve-ClientConfiguration {
    param(
        [string] $ConfigPath,
        [hashtable] $Overrides = @{}
    )

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $PSScriptRoot 'client.settings.json'
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

    foreach ($name in $Overrides.Keys) {
        if ($null -ne $Overrides[$name] -and
            -not [string]::IsNullOrWhiteSpace([string] $Overrides[$name])) {
            $configuration[$name] = $Overrides[$name]
        }
    }

    $configuration.ConfigPath = $ConfigPath
    return $configuration
}

function Get-ConfigurationValue {
    param(
        [Parameter(Mandatory)][hashtable] $Configuration,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Description
    )

    $value = [string] $Configuration[$Name]
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "$Description is missing. Reinstall the client module, provide -ConfigPath, or pass the value explicitly."
    }
    return $value
}

function Get-ClientApiErrorMessage {
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
    param(
        [Parameter(Mandatory)][string] $TenantId,
        [Parameter(Mandatory)][string] $ResourceUrl,
        [string] $SubscriptionId
    )

    Assert-ClientCommand -Name 'Get-AzContext', 'Connect-AzAccount', 'Get-AzAccessToken'
    $context = Get-AzContext -ErrorAction SilentlyContinue
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
    $plainToken = if ($tokenResult.Token -is [Security.SecureString]) {
        ConvertFrom-SecureString -SecureString $tokenResult.Token -AsPlainText
    }
    else {
        [string] $tokenResult.Token
    }
    return ConvertTo-SecureString $plainToken -AsPlainText -Force
}

function Get-CoreModulePath {
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

function New-AutopilotClientConfiguration {
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
    New-AutopilotClientConfiguration `
        -SubscriptionId '00000000-0000-0000-0000-000000000000' `
        -ResourceGroupName 'rg-autopilot-import' `
        -TenantId '11111111-1111-1111-1111-111111111111' `
        -FunctionAppName 'func-autopilot-import'

    Creates client.settings.json in the current directory.

    .EXAMPLE
    New-AutopilotClientConfiguration `
        -SubscriptionId '00000000-0000-0000-0000-000000000000' `
        -ResourceGroupName 'rg-autopilot-import' `
        -TenantId '11111111-1111-1111-1111-111111111111' `
        -FunctionAppName 'func-autopilot-import' `
        -OutputPath 'C:\AutopilotImport' `
        -Force

    Creates or replaces C:\AutopilotImport\client.settings.json.

    .OUTPUTS
    System.IO.FileInfo. Returns the created client.settings.json file.
    #>
    [CmdletBinding(SupportsShouldProcess)]
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

function Import-AutopilotDevice {
    <#
    .SYNOPSIS
    Imports Windows Autopilot devices from a CSV through the secured Function.

    .PARAMETER CsvPath
    CSV containing Device Serial Number and Hardware Hash columns.

    .PARAMETER GroupTag
    Group Tag requested for every device in the CSV.

    .PARAMETER ValidateOnly
    Validates the CSV without authentication or API calls.
    #>
    [CmdletBinding()]
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

function Get-AutopilotImportStatus {
    <#
    .SYNOPSIS
    Returns the current Intune processing status of an Autopilot import.

    .PARAMETER Wait
    Polls until Intune returns complete or error, or TimeoutSeconds expires.

    .PARAMETER PollIntervalSeconds
    Seconds between requests when Wait is specified. The default is 15.

    .PARAMETER TimeoutSeconds
    Maximum wait time in seconds. The default is 1800 (30 minutes).
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
        if ($stopwatch.Elapsed.TotalSeconds + $PollIntervalSeconds -gt $TimeoutSeconds) {
            throw "Autopilot import '$ImportId' did not reach a final state within $TimeoutSeconds seconds. Last status: $($result.status)."
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    } while ($true)
}

function Get-AutopilotTagPolicy {
    <#
    .SYNOPSIS
    Returns the current group-to-tag policy with Entra group display names.

    .DESCRIPTION
    Retrieves the current policy and resolves each group object ID through
    Microsoft Graph. The default console view shows GroupName and Tags while
    GroupId remains available as an object property for pipeline use.

    .PARAMETER Raw
    Returns the unchanged response from the management API without resolving
    group display names. Use this switch for automation that relies on the
    response envelope and its policy property.
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

        $result = [pscustomobject][ordered]@{
            GroupName = $groupName
            Tags      = @($rule.tags)
            GroupId   = $groupId
        }
        if ($rule.PSObject.Properties['restrictedManagementAdministrativeUnitName']) {
            $result | Add-Member `
                -NotePropertyName RestrictedManagementAdministrativeUnitName `
                -NotePropertyValue ([string] $rule.restrictedManagementAdministrativeUnitName)
        }
        if ($response.PSObject.Properties['correlationId']) {
            $result | Add-Member `
                -NotePropertyName CorrelationId `
                -NotePropertyValue ([string] $response.correlationId)
        }

        $defaultProperties = [Collections.Generic.List[string]]::new()
        $defaultProperties.Add('GroupName')
        $defaultProperties.Add('Tags')
        if ($result.PSObject.Properties['RestrictedManagementAdministrativeUnitName']) {
            $defaultProperties.Add('RestrictedManagementAdministrativeUnitName')
        }
        $displayPropertySet = [Management.Automation.PSPropertySet]::new(
            'DefaultDisplayPropertySet',
            [string[]] $defaultProperties
        )
        $result | Add-Member `
            -MemberType MemberSet `
            -Name PSStandardMembers `
            -Value ([Management.Automation.PSMemberInfo[]] @($displayPropertySet))
        $result
    }
}

function Add-AutopilotTagPolicy {
    <#
    .SYNOPSIS
    Adds an Entra group and its allowed Group Tags to the policy.

    .DESCRIPTION
    Accepts either an Entra group object ID or an exact group display name.
    Existing rules are preserved and tags for an existing group are merged.
    When no restricted management administrative unit is specified, the
    currently configured MAU is preserved.

    .PARAMETER Group
    Entra group object ID or exact display name. If multiple groups have the
    same display name, use the object ID to select one unambiguously.

    .PARAMETER GroupTag
    One or more allowed Autopilot Group Tags for the group.

    .PARAMETER RestrictedManagementAdministrativeUnitName
    Optional display name of the restricted management administrative unit.
    The policy format applies this MAU to all rules. If omitted, the current
    policy value is retained.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Alias('GroupId', 'GroupName')]
        [string] $Group,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Alias('Tag')]
        [string[]] $GroupTag,

        [Alias('Mau')]
        [ValidateLength(1, 256)]
        [string] $RestrictedManagementAdministrativeUnitName,

        [ValidatePattern('^https://')][string] $ManagementUrl,
        [ValidatePattern('^api://')][string] $ApiApplicationIdUri,
        [string] $TenantId,
        [string] $ConfigPath
    )

    $tags = @($GroupTag | ForEach-Object { $_.Trim() } | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    } | Select-Object -Unique)
    if ($tags.Count -eq 0) {
        throw 'Specify at least one Group Tag.'
    }
    foreach ($tag in $tags) {
        if ($tag.Length -gt 128) {
            throw "Group Tag '$tag' must not exceed 128 characters."
        }
        if ($tag.Contains(',')) {
            throw "Group Tag '$tag' must not contain a comma."
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
    $rulesByGroup = [ordered]@{}
    foreach ($rule in $currentPolicy) {
        $currentGroupId = ([guid] $rule.groupId).ToString()
        $rulesByGroup[$currentGroupId] = @($rule.tags)
    }
    $rulesByGroup[$resolvedGroupId] = @(
        @($rulesByGroup[$resolvedGroupId]) + $tags |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) } |
            Select-Object -Unique
    )

    if ($PSBoundParameters.ContainsKey(
            'RestrictedManagementAdministrativeUnitName')) {
        $mauName = $RestrictedManagementAdministrativeUnitName.Trim()
    }
    else {
        $configuredMauNames = @($currentPolicy |
            ForEach-Object {
                if ($_.PSObject.Properties[
                        'restrictedManagementAdministrativeUnitName']) {
                    $_.restrictedManagementAdministrativeUnitName
                }
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) } |
            Select-Object -Unique)
        $mauName = if ($configuredMauNames.Count -gt 0) {
            [string] $configuredMauNames[0]
        }
        else {
            ''
        }
    }
    $rules = @($rulesByGroup.Keys | ForEach-Object {
        "$_=$(@($rulesByGroup[$_]) -join ',')"
    })
    $body = @{
        rules = $rules
        restrictedManagementAdministrativeUnitName = $mauName
    } | ConvertTo-Json -Depth 4 -Compress

    $target = if ([string]::IsNullOrWhiteSpace($groupDisplayName)) {
        $resolvedGroupId
    }
    else {
        "$groupDisplayName ($resolvedGroupId)"
    }
    if (-not $PSCmdlet.ShouldProcess(
            $target,
            "Add Group Tags '$($tags -join ', ')' to the Autopilot policy")) {
        return
    }

    Invoke-RestMethod `
        -Method Put `
        -Uri $url.TrimEnd('/') `
        -Authentication Bearer `
        -Token $apiToken `
        -ContentType 'application/json' `
        -Body $body `
        -ErrorAction Stop
}

function Remove-AutopilotTagPolicy {
    <#
    .SYNOPSIS
    Removes an Entra group from the Group Tag policy.

    .DESCRIPTION
    Accepts either an Entra group object ID or an exact group display name.
    The selected group's complete rule is removed while all other rules and
    the currently configured restricted management administrative unit are
    preserved.

    .PARAMETER Group
    Entra group object ID or exact display name. If multiple groups have the
    same display name, use the object ID to select one unambiguously.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Alias('GroupId', 'GroupName')]
        [string] $Group,

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

    $remainingPolicy = @($currentPolicy | Where-Object {
        ([guid] $_.groupId).ToString() -ne $resolvedGroupId
    })
    if ($remainingPolicy.Count -eq 0) {
        throw 'The last Group Tag policy rule cannot be removed. Use Set-AutopilotTagPolicy to replace the policy.'
    }
    $rules = @($remainingPolicy | ForEach-Object {
        "$(([guid] $_.groupId).ToString())=$(@($_.tags) -join ',')"
    })
    $configuredMauNames = @($remainingPolicy |
        ForEach-Object {
            if ($_.PSObject.Properties[
                    'restrictedManagementAdministrativeUnitName']) {
                $_.restrictedManagementAdministrativeUnitName
            }
        } |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) } |
        Select-Object -Unique)
    $mauName = if ($configuredMauNames.Count -gt 0) {
        [string] $configuredMauNames[0]
    }
    else {
        ''
    }
    $body = @{
        rules = $rules
        restrictedManagementAdministrativeUnitName = $mauName
    } | ConvertTo-Json -Depth 4 -Compress

    $target = if ([string]::IsNullOrWhiteSpace($groupDisplayName)) {
        $resolvedGroupId
    }
    else {
        "$groupDisplayName ($resolvedGroupId)"
    }
    if (-not $PSCmdlet.ShouldProcess(
            $target,
            'Remove the group from the Autopilot Group Tag policy')) {
        return
    }

    Invoke-RestMethod `
        -Method Put `
        -Uri $url.TrimEnd('/') `
        -Authentication Bearer `
        -Token $apiToken `
        -ContentType 'application/json' `
        -Body $body `
        -ErrorAction Stop
}

function Set-AutopilotTagPolicy {
    <# .SYNOPSIS Replaces the complete group-to-tag policy. #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string[]] $TagAuthorizationRule,
        [string] $RestrictedManagementAdministrativeUnitName,
        [ValidatePattern('^https://')][string] $ManagementUrl,
        [ValidatePattern('^api://')][string] $ApiApplicationIdUri,
        [string] $TenantId,
        [string] $ConfigPath
    )

    $configuration = Resolve-ClientConfiguration $ConfigPath @{
        managementUrl = $ManagementUrl; apiApplicationIdUri = $ApiApplicationIdUri; tenantId = $TenantId
    }
    $url = Get-ConfigurationValue $configuration managementUrl 'ManagementUrl'
    $coreModulePath = Get-CoreModulePath
    Import-Module $coreModulePath -Force
    $policy = @(ConvertTo-TagAuthorizationPolicy `
        -Rules $TagAuthorizationRule `
        -RestrictedManagementAdministrativeUnitName `
            $RestrictedManagementAdministrativeUnitName)
    if (-not $PSCmdlet.ShouldProcess($url, "Replace tag authorization policy with $($policy.Count) group rule(s)")) {
        return
    }
    $audience = Get-ConfigurationValue $configuration apiApplicationIdUri 'ApiApplicationIdUri'
    $resolvedTenantId = Get-ConfigurationValue $configuration tenantId 'TenantId'
    $token = Get-ClientAccessToken $resolvedTenantId $audience
    $body = @{
        rules = @($TagAuthorizationRule)
        restrictedManagementAdministrativeUnitName = `
            $RestrictedManagementAdministrativeUnitName
    } | ConvertTo-Json -Depth 4 -Compress
    Invoke-RestMethod -Method Put -Uri $url.TrimEnd('/') -Authentication Bearer `
        -Token $token -ContentType 'application/json' -Body $body
}

function Update-AutopilotTagPolicyManager {
    <# .SYNOPSIS Adds and removes explicit Group Tag managers atomically. #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
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
    $configuration = Resolve-ClientConfiguration $ConfigPath @{
        subscriptionId = $SubscriptionId; tenantId = $TenantId
        resourceGroupName = $ResourceGroupName; functionAppName = $FunctionAppName
    }
    $resolvedSubscriptionId = Get-ConfigurationValue $configuration subscriptionId 'SubscriptionId'
    $resolvedTenantId = Get-ConfigurationValue $configuration tenantId 'TenantId'
    $resolvedResourceGroup = Get-ConfigurationValue $configuration resourceGroupName 'ResourceGroupName'
    $resolvedFunctionName = Get-ConfigurationValue $configuration functionAppName 'FunctionAppName'
    $addIds = @($AddPrincipalId | Where-Object { $null -ne $_ } |
        ForEach-Object { $_.ToString() })
    $removeIds = @($RemovePrincipalId | Where-Object { $null -ne $_ } |
        ForEach-Object { $_.ToString() })
    if ($addIds.Count -eq 0 -and $removeIds.Count -eq 0) {
        throw 'Specify at least one principal ID to add or remove.'
    }

    [void](Get-ClientAccessToken $resolvedTenantId 'https://management.azure.com/' $resolvedSubscriptionId)
    Set-AzContext -Tenant $resolvedTenantId -Subscription $resolvedSubscriptionId -WhatIf:$false | Out-Null
    $functionApp = Get-AzWebApp -ResourceGroupName $resolvedResourceGroup -Name $resolvedFunctionName
    if (-not $functionApp) { throw "Function App '$resolvedFunctionName' was not found." }

    $managementTokenResult = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'
    $plainToken = if ($managementTokenResult.Token -is [Security.SecureString]) {
        ConvertFrom-SecureString $managementTokenResult.Token -AsPlainText
    } else { [string] $managementTokenResult.Token }
    $payload = $plainToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $payload = $payload.PadRight($payload.Length + ((4 - $payload.Length % 4) % 4), '=')
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    $assignments = @(Get-AzRoleAssignment -ObjectId ([guid] $claims.oid) -ExpandPrincipalGroups)

    $coreModulePath = Get-CoreModulePath
    Import-Module $coreModulePath -Force
    if (-not (Test-TagManagerPolicyAdministratorRole $assignments $functionApp.Id)) {
        throw "Only an Owner or Contributor of Function App '$resolvedFunctionName' may change its Group Tag managers."
    }

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
        $appSettings.MANAGER_AUTHORIZATION_POLICY = $updatedPolicy | ConvertTo-Json -Depth 4 -Compress
        Set-AzWebApp -ResourceGroupName $resolvedResourceGroup -Name $resolvedFunctionName `
            -AppSettings $appSettings | Out-Null
    }
    [pscustomobject]@{ FunctionAppName = $resolvedFunctionName; ManagerPolicy = $updatedPolicy }
}

function Add-AutopilotTagPolicyManager {
    <# .SYNOPSIS Adds explicit Group Tag manager users or groups. #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
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
    Update-AutopilotTagPolicyManager @parameters
}

function Remove-AutopilotTagPolicyManager {
    <# .SYNOPSIS Removes explicit Group Tag manager users or groups. #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
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
    Update-AutopilotTagPolicyManager @parameters
}

Export-ModuleMember -Function @(
    'New-AutopilotClientConfiguration',
    'Import-AutopilotDevice',
    'Get-AutopilotImportStatus',
    'Get-AutopilotTagPolicy',
    'Add-AutopilotTagPolicy',
    'Remove-AutopilotTagPolicy',
    'Set-AutopilotTagPolicy',
    'Update-AutopilotTagPolicyManager',
    'Add-AutopilotTagPolicyManager',
    'Remove-AutopilotTagPolicyManager'
)
