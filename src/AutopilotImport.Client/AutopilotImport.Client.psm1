#Requires -Version 7.2
# Project-Version: 1.0.20260813.2
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
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
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
    <# .SYNOPSIS Returns the current group-to-tag policy. #>
    [CmdletBinding()]
    param(
        [ValidatePattern('^https://')][string] $ManagementUrl,
        [ValidatePattern('^api://')][string] $ApiApplicationIdUri,
        [string] $TenantId,
        [string] $ConfigPath
    )

    $configuration = Resolve-ClientConfiguration $ConfigPath @{
        managementUrl = $ManagementUrl; apiApplicationIdUri = $ApiApplicationIdUri; tenantId = $TenantId
    }
    $url = Get-ConfigurationValue $configuration managementUrl 'ManagementUrl'
    $audience = Get-ConfigurationValue $configuration apiApplicationIdUri 'ApiApplicationIdUri'
    $resolvedTenantId = Get-ConfigurationValue $configuration tenantId 'TenantId'
    $token = Get-ClientAccessToken $resolvedTenantId $audience
    Invoke-RestMethod -Method Get -Uri $url.TrimEnd('/') -Authentication Bearer -Token $token
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
    'Import-AutopilotDevice',
    'Get-AutopilotImportStatus',
    'Get-AutopilotTagPolicy',
    'Set-AutopilotTagPolicy',
    'Update-AutopilotTagPolicyManager',
    'Add-AutopilotTagPolicyManager',
    'Remove-AutopilotTagPolicyManager'
)
