# Project-Version: 1.3.20261002.3
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
.SYNOPSIS
Returns retained Autopilot import operations visible to the caller.

.DESCRIPTION
Returns the caller's own 30-day audit history by default. Explicit import IDs,
serial numbers, or DeviceHash indexes can retrieve matching records from any
importer. ShowAll and user-principal-name filters require importer-manager
authorization. Current Intune state is added from Microsoft Graph when
available. DeviceHashes and product keys are not returned.
#>

using namespace System.Net

param($Request, $TriggerMetadata)

$modulePath = Join-Path $PSScriptRoot '..\src\AutopilotImport\AutopilotImport.psm1'
Import-Module $modulePath -Force

$correlationId = [guid]::NewGuid().ToString()
$responseHeaders = @{
    'Content-Type'     = 'application/json'
    'X-Correlation-Id' = $correlationId
}

function Send-JsonResponse {
    param(
        [Parameter(Mandatory)]
        [HttpStatusCode] $StatusCode,

        [Parameter(Mandatory)]
        [object] $Body
    )

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $StatusCode
        Headers    = $responseHeaders
        Body       = ($Body | ConvertTo-Json -Depth 8 -Compress)
    })
}

try {
    $principalHeader = $Request.Headers['x-ms-client-principal']
    if ([string]::IsNullOrWhiteSpace($principalHeader)) {
        throw [System.UnauthorizedAccessException]::new(
            'Authentication is required.')
    }
    $principal = ConvertFrom-ClientPrincipalHeader -HeaderValue $principalHeader
}
catch [System.UnauthorizedAccessException] {
    Send-JsonResponse -StatusCode Unauthorized -Body @{
        error         = 'authenticationRequired'
        correlationId = $correlationId
    }
    return
}
catch {
    Send-JsonResponse -StatusCode InternalServerError -Body @{
        error         = 'serviceNotConfigured'
        correlationId = $correlationId
    }
    return
}

$actorObjectId = [string] (@($principal.claims | Where-Object {
    $_.typ -in @(
        'oid'
        'http://schemas.microsoft.com/identity/claims/objectidentifier'
    )
} | Select-Object -First 1).val)
if ([string]::IsNullOrWhiteSpace($actorObjectId)) {
    Send-JsonResponse -StatusCode Forbidden -Body @{
        error         = 'principalObjectIdUnavailable'
        correlationId = $correlationId
    }
    return
}

$top = 100
$requestedTop = [string] $Request.Query.top
if (-not [string]::IsNullOrWhiteSpace($requestedTop)) {
    $parsedTop = 0
    if (-not [int]::TryParse($requestedTop, [ref] $parsedTop) -or
        $parsedTop -lt 1 -or $parsedTop -gt 1000) {
        Send-JsonResponse -StatusCode BadRequest -Body @{
            error         = 'invalidTop'
            message       = 'top must be an integer between 1 and 1000.'
            correlationId = $correlationId
        }
        return
    }
    $top = $parsedTop
}

try {
    $requestBody = if ([string] $Request.Method -eq 'POST' -and
        $null -ne $Request.Body) {
        if ($Request.Body -is [string]) {
            $Request.Body | ConvertFrom-Json
        }
        else {
            $Request.Body
        }
    }
    else {
        $null
    }

    $showAllValue = if ($requestBody -and
        $requestBody.PSObject.Properties['showAll']) {
        [string] $requestBody.showAll
    }
    else {
        [string] $Request.Query.showAll
    }
    $showAll = $false
    if (-not [string]::IsNullOrWhiteSpace($showAllValue) -and
        -not [bool]::TryParse($showAllValue, [ref] $showAll)) {
        throw [ArgumentException]::new('showAll must be true or false.')
    }

    $importIdValues = @()
    if ($requestBody -and $requestBody.PSObject.Properties['importIds']) {
        $importIdValues += @($requestBody.importIds)
    }
    if (-not [string]::IsNullOrWhiteSpace(
            [string] $Request.Query.importId)) {
        $importIdValues += ([string] $Request.Query.importId).Split(',')
    }
    $requestedImportIds = @($importIdValues | ForEach-Object {
        $parsedImportId = [guid]::Empty
        if (-not [guid]::TryParse([string] $_, [ref] $parsedImportId)) {
            throw [ArgumentException]::new(
                "ImportId '$_' is invalid.")
        }
        $parsedImportId
    } | Select-Object -Unique)

    $serialNumberValues = @()
    if ($requestBody -and $requestBody.PSObject.Properties['serialNumbers']) {
        $serialNumberValues += @($requestBody.serialNumbers)
    }
    $requestedSerialNumbers = @($serialNumberValues | ForEach-Object {
        $serialNumber = ([string] $_).Trim()
        if ([string]::IsNullOrWhiteSpace($serialNumber)) {
            throw [ArgumentException]::new(
                'serialNumbers must not contain empty values.')
        }
        $serialNumber
    } | Select-Object -Unique)

    $userValues = @()
    if ($requestBody -and $requestBody.PSObject.Properties['users']) {
        $userValues += @($requestBody.users)
    }
    $requestedUsers = @($userValues | ForEach-Object {
        $user = ([string] $_).Trim()
        if ([string]::IsNullOrWhiteSpace($user)) {
            throw [ArgumentException]::new(
                'users must not contain empty values.')
        }
        $user
    } | Select-Object -Unique)

    $deviceHashSha256Values = @()
    if ($requestBody -and
        $requestBody.PSObject.Properties['deviceHashSha256']) {
        $deviceHashSha256Values += @($requestBody.deviceHashSha256)
    }
    $requestedDeviceHashSha256 = @($deviceHashSha256Values |
        ForEach-Object {
            $normalizedHash = ([string] $_).Trim().ToLowerInvariant()
            if ($normalizedHash -notmatch '^[0-9a-fA-F]{64}$') {
                throw [ArgumentException]::new(
                    'deviceHashSha256 must contain exactly 64 hexadecimal characters.')
            }
            $normalizedHash
        } | Select-Object -Unique)
    if ($requestedImportIds.Count + $requestedSerialNumbers.Count +
        $requestedDeviceHashSha256.Count + $requestedUsers.Count -gt 50) {
        throw [ArgumentException]::new(
            'At most 50 ImportId, SerialNumber, DeviceHash, and User values may be requested.')
    }
    $hasExplicitFilter = $requestedImportIds.Count -gt 0 -or
        $requestedSerialNumbers.Count -gt 0 -or
        $requestedUsers.Count -gt 0 -or
        $requestedDeviceHashSha256.Count -gt 0
    if ($showAll -and $hasExplicitFilter) {
        throw [ArgumentException]::new(
            'showAll cannot be combined with ImportId, SerialNumber, DeviceHash, or User filters.')
    }
}
catch [ArgumentException] {
    Send-JsonResponse -StatusCode BadRequest -Body @{
        error         = 'invalidHistoryFilter'
        message       = $_.Exception.Message
        correlationId = $correlationId
    }
    return
}
catch {
    Send-JsonResponse -StatusCode BadRequest -Body @{
        error         = 'invalidHistoryFilter'
        correlationId = $correlationId
    }
    return
}

if ($showAll -or $requestedUsers.Count -gt 0) {
    try {
        $managerPolicyJson = $env:MANAGER_AUTHORIZATION_POLICY
        if ([string]::IsNullOrWhiteSpace($managerPolicyJson)) {
            throw 'Manager authorization policy is not configured.'
        }
        $managerPolicy = $managerPolicyJson | ConvertFrom-Json
        $isManager = Test-TagPolicyManagerPrincipal `
            -Principal $principal `
            -ManagerPolicy $managerPolicy
        if (-not $isManager -and
            $managerPolicy.allowIntuneRoleAdministrators) {
            $isManager = Test-IntuneRoleAdministrator -Principal $principal
        }
    }
    catch {
        Write-Error "[$correlationId] Manager authorization lookup failed: $($_.Exception.Message)"
        Send-JsonResponse -StatusCode ServiceUnavailable -Body @{
            error         = 'authorizationServiceUnavailable'
            correlationId = $correlationId
        }
        return
    }
    if (-not $isManager) {
        Send-JsonResponse -StatusCode Forbidden -Body @{
            error         = 'historyAccessForbidden'
            correlationId = $correlationId
        }
        return
    }
}

try {
    $auditParameters = @{
        SinceUtc = Get-ImportAuditRetentionCutoffUtc
        Top = $top
        AccessToken = Get-ImportAuditAccessToken
    }
    if ($requestedImportIds.Count -gt 0) {
        $auditParameters.ImportId = $requestedImportIds
    }
    if ($requestedSerialNumbers.Count -gt 0) {
        $auditParameters.SerialNumber = $requestedSerialNumbers
    }
    if ($requestedUsers.Count -gt 0) {
        $auditParameters.ActorUserPrincipalName = $requestedUsers
    }
    if ($requestedDeviceHashSha256.Count -gt 0) {
        $auditParameters.DeviceHashSha256 = $requestedDeviceHashSha256
    }
    if (-not $showAll -and -not $hasExplicitFilter) {
        $auditParameters.ActorObjectId = $actorObjectId
    }
    $auditRecords = @(Get-ImportAuditHistory @auditParameters)
}
catch {
    Write-Error "[$correlationId] Import audit lookup failed: $($_.Exception.Message)"
    Send-JsonResponse -StatusCode BadGateway -Body @{
        error         = 'importHistoryLookupFailed'
        correlationId = $correlationId
    }
    return
}

$graphRecords = @{}
if ($auditRecords.Count -gt 0) {
    try {
        $tokenResult = Get-AzAccessToken `
            -ResourceUrl 'https://graph.microsoft.com/' `
            -ErrorAction Stop
        $accessToken = if ($tokenResult.Token -is [Security.SecureString]) {
            ConvertFrom-SecureString `
                -SecureString $tokenResult.Token `
                -AsPlainText
        }
        else {
            [string] $tokenResult.Token
        }
        $headers = @{ Authorization = "Bearer $accessToken" }
        $remainingIds = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase)
        foreach ($auditRecord in $auditRecords) {
            [void] $remainingIds.Add([string] $auditRecord.RowKey)
        }
        $requestUri = 'https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities?$select=id,importId,serialNumber,groupTag,state&$top=100'
        while ($requestUri -and $remainingIds.Count -gt 0) {
            $graphResponse = Invoke-RestMethod `
                -Method Get `
                -Uri $requestUri `
                -Headers $headers `
                -ErrorAction Stop
            foreach ($importedDevice in @($graphResponse.value)) {
                $importId = [string] $importedDevice.id
                if ($remainingIds.Remove($importId)) {
                    $graphRecords[$importId] = $importedDevice
                }
            }
            $requestUri = if ($graphResponse.PSObject.Properties.Name -contains
                '@odata.nextLink') {
                [string] $graphResponse.'@odata.nextLink'
            }
            else {
                $null
            }
        }
    }
    catch {
        Write-Warning "[$correlationId] Graph enrichment for import history failed: $($_.Exception.Message)"
    }
}

$history = @($auditRecords | ForEach-Object {
        $audit = $_
        $graphRecord = $graphRecords[[string] $audit.RowKey]
        $requestedBy = if ($audit -and -not [string]::IsNullOrWhiteSpace(
                [string] $audit.actorUserPrincipalName)) {
            [string] $audit.actorUserPrincipalName
        }
        elseif ($audit -and -not [string]::IsNullOrWhiteSpace(
                [string] $audit.actorDisplayName)) {
            [string] $audit.actorDisplayName
        }
        elseif ($audit) {
            [string] $audit.actorObjectId
        }
        else {
            $null
        }
        [pscustomobject][ordered]@{
            importId                         = [string] $audit.RowKey
            batchImportId                    = if ($graphRecord) { [string] $graphRecord.importId } else { [string] $audit.batchImportId }
            serialNumber                     = if ($graphRecord) { [string] $graphRecord.serialNumber } else { [string] $audit.serialNumber }
            groupTag                         = if ($graphRecord) { [string] $graphRecord.groupTag } else { [string] $audit.groupTag }
            status                           = if ($graphRecord) { [string] $graphRecord.state.deviceImportStatus } else { $null }
            deviceHashSha256                 = if ($audit) { [string] $audit.deviceHashSha256 } else { $null }
            deviceErrorCode                  = if ($graphRecord) { $graphRecord.state.deviceErrorCode } else { $null }
            deviceErrorName                  = if ($graphRecord) { [string] $graphRecord.state.deviceErrorName } else { $null }
            requestedBy                      = $requestedBy
            requestedByObjectId              = if ($audit) { [string] $audit.actorObjectId } else { $null }
            requestedByUserPrincipalName     = if ($audit) { [string] $audit.actorUserPrincipalName } else { $null }
            requestedByDisplayName           = if ($audit) { [string] $audit.actorDisplayName } else { $null }
            requestReceivedAtUtc              = if ($audit) { [string] $audit.requestReceivedAtUtc } else { $null }
            graphImportCreatedAtUtc           = if ($audit) { [string] $audit.graphImportCreatedAtUtc } else { $null }
            queuedAtUtc                       = if ($audit) { [string] $audit.queuedAtUtc } else { $null }
            processingStartedAtUtc            = if ($audit) { [string] $audit.processingStartedAtUtc } else { $null }
            entraDeviceResolvedAtUtc          = if ($audit) { [string] $audit.entraDeviceResolvedAtUtc } else { $null }
            extensionAttributeUpdatedAtUtc    = if ($audit) { [string] $audit.extensionAttributeUpdatedAtUtc } else { $null }
            administrativeUnitAssignedAtUtc   = if ($audit) { [string] $audit.administrativeUnitAssignedAtUtc } else { $null }
            processingCompletedAtUtc          = if ($audit) { [string] $audit.processingCompletedAtUtc } else { $null }
        }
    })

Send-JsonResponse -StatusCode OK -Body @{
    imports       = $history
    count         = $history.Count
    correlationId = $correlationId
}
