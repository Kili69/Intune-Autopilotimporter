# Project-Version: 1.4.20261017.6
# Author: andreas.lucas@outlook.com (aka Kili)

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

# Share one ID between the response and diagnostic logs so lookup failures
# can be traced without exposing internal exception details to the caller.
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

    # The Functions host sends this output binding as the HTTP response.
    # Depth 8 preserves nested action details in the history records.
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $StatusCode
        Headers    = $responseHeaders
        Body       = ($Body | ConvertTo-Json -Depth 8 -Compress)
    })
}

try {
    # Easy Auth authenticates the request upstream and supplies this principal.
    # The worker decodes its claims rather than validating a bearer token here.
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
    # Principal decoding failures follow this generic error path; only the
    # explicit missing-header exception above maps to authenticationRequired.
    Send-JsonResponse -StatusCode InternalServerError -Body @{
        error         = 'serviceNotConfigured'
        correlationId = $correlationId
    }
    return
}

# Use the stable Entra object ID for the default "my history" restriction.
# Both short and fully qualified Easy Auth object-ID claim names are supported.
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

# The result limit always comes from the query string, including POST requests.
# Bound it before any Storage or Graph lookup to keep history requests limited.
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
    # POST supports structured filter arrays. Depending on the worker, its
    # body may already be an object or still need JSON deserialization.
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

    # A body property takes precedence over the query-string showAll value,
    # even when the supplied body value is false.
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

    # Import IDs can come from both body arrays and the comma-separated query
    # parameter. Validate GUIDs and deduplicate the combined collection.
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

    # Serial-number and user filters are body-only. Trim values and reject
    # empty entries rather than silently broadening the requested lookup.
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

    # Accept only SHA-256 lookup indexes, not raw hardware hashes. Normalize
    # hexadecimal casing so equivalent indexes do not create duplicate filters.
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
    # Apply one shared limit across all deduplicated filter collections;
    # showAll is a separate lookup mode and cannot be mixed with filters.
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
    # Deliberate validation errors include a useful message. Other parsing
    # failures below return the same error code without internal details.
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

# Broad history access and filtering by another user require manager rights.
# Explicit import-ID, serial-number and hash lookups do not enter this check.
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
        # Check the Intune administrator role only when policy permits it and
        # the caller was not already authorized by the manager policy.
        if (-not $isManager -and
            $managerPolicy.allowIntuneRoleAdministrators) {
            $isManager = Test-IntuneRoleAdministrator -Principal $principal
        }
    }
    catch {
        # An unavailable authorization service is not proof of missing rights:
        # return 503, distinct from the definitive 403 denial below.
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
    # Retention applies to every lookup mode, including manager and explicit
    # device queries. The helper obtains a separate Storage access token.
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
        # Only the unfiltered default view is restricted to the caller's own
        # records; explicit device/import filters can match other importers.
        $auditParameters.ActorObjectId = $actorObjectId
    }
    $auditRecords = @(Get-ImportAuditHistory @auditParameters)
}
catch {
    # Audit Storage is the authoritative history source. If it fails, do not
    # return an empty success response or substitute a Graph-only result.
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
        # Graph enriches existing audit records; an empty history needs no
        # Graph request. Support both Az.Accounts token representations.
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
        # Audit RowKey identifies an individual imported device in Graph.
        # It is not the Graph importId property, which groups a batch.
        $remainingIds = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase)
        foreach ($auditRecord in $auditRecords) {
            [void] $remainingIds.Add([string] $auditRecord.RowKey)
        }
        $requestUri = 'https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities?$select=id,importId,serialNumber,groupTag,state&$top=100'
        # Follow Graph pagination until all requested records are found or the
        # collection ends; retain only devices present in the audit result.
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
        # Graph enrichment is optional: keep the audit history and any records
        # already enriched before the failure, and log the missing live data.
        Write-Warning "[$correlationId] Graph enrichment for import history failed: $($_.Exception.Message)"
    }
}

$history = @($auditRecords | ForEach-Object {
        $audit = $_
        $graphRecord = $graphRecords[[string] $audit.RowKey]
        # Prefer a readable user principal name, then a display name; retain
        # the object ID as a fallback for older or incomplete audit records.
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
        # Workflow steps may complete independently. Use the newest available
        # event or Storage Timestamp, not a fixed step, as the last update.
        $timelineProperties = @(
            'requestReceivedAtUtc'
            'graphImportCreatedAtUtc'
            'graphImportCompletedAtUtc'
            'queuedAtUtc'
            'processingStartedAtUtc'
            'entraDeviceResolvedAtUtc'
            'autopilotGroupTagUpdatedAtUtc'
            'extensionAttributeUpdatedAtUtc'
            'administrativeUnitAssignedAtUtc'
            'processingCompletedAtUtc'
            'deviceGroupsUpdatedAtUtc'
            'Timestamp'
        )
        $lastUpdated = @($timelineProperties | ForEach-Object {
            $property = $audit.PSObject.Properties[$_]
            if ($property -and -not [string]::IsNullOrWhiteSpace(
                    [string] $property.Value)) {
                [datetimeoffset] $property.Value
            }
        } | Sort-Object -Descending | Select-Object -First 1)
        # Structured action details are stored in JSON-valued table columns.
        # NoEnumerate preserves single-item arrays when restoring the payload.
        $actionDetails = @{}
        foreach ($name in @(
                'appliedExtensionAttributes', 'targetDeviceGroupIds',
                'addedDeviceGroupIds', 'removedDeviceGroupIds', 'removedAdministrativeUnits'
            )) {
            $property = $audit.PSObject.Properties["${name}Json"]
            $actionDetails[$name] = if ($property -and $property.Value) {
                ConvertFrom-Json -InputObject ([string] $property.Value) -NoEnumerate
            } else { $null }
        }
        # Project an explicit public response: prefer current Graph values
        # where available and otherwise retain audit values. Missing live
        # status/error fields remain null. Raw hardware hashes and product
        # keys are not exposed; only the SHA-256 lookup index is included.
        # Property guards keep newer optional fields compatible with old rows.
        [pscustomobject][ordered]@{
            importId                         = [string] $audit.RowKey
            operationType                    = if ($audit.PSObject.Properties['operationType']) { [string] $audit.operationType } else { 'import' }
            batchImportId                    = if ($graphRecord) { [string] $graphRecord.importId } else { [string] $audit.batchImportId }
            serialNumber                     = if ($graphRecord) { [string] $graphRecord.serialNumber } else { [string] $audit.serialNumber }
            groupTag                         = if ($graphRecord) { [string] $graphRecord.groupTag } else { [string] $audit.groupTag }
            previousGroupTag                 = if ($audit.PSObject.Properties['previousGroupTag']) { [string] $audit.previousGroupTag } else { $null }
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
            graphImportCompletedAtUtc         = if ($audit.PSObject.Properties['graphImportCompletedAtUtc']) { [string] $audit.graphImportCompletedAtUtc } else { $null }
            queuedAtUtc                       = if ($audit) { [string] $audit.queuedAtUtc } else { $null }
            processingStartedAtUtc            = if ($audit) { [string] $audit.processingStartedAtUtc } else { $null }
            entraDeviceResolvedAtUtc          = if ($audit) { [string] $audit.entraDeviceResolvedAtUtc } else { $null }
            autopilotGroupTagUpdatedAtUtc     = if ($audit.PSObject.Properties['autopilotGroupTagUpdatedAtUtc']) { [string] $audit.autopilotGroupTagUpdatedAtUtc } else { $null }
            extensionAttributeUpdatedAtUtc    = if ($audit) { [string] $audit.extensionAttributeUpdatedAtUtc } else { $null }
            administrativeUnitAssignedAtUtc   = if ($audit) { [string] $audit.administrativeUnitAssignedAtUtc } else { $null }
            processingCompletedAtUtc          = if ($audit) { [string] $audit.processingCompletedAtUtc } else { $null }
            policyName                        = if ($audit.PSObject.Properties['policyName']) { [string] $audit.policyName } else { $null }
            deviceGroupsUpdatedAtUtc          = if ($audit.PSObject.Properties['deviceGroupsUpdatedAtUtc']) { [string] $audit.deviceGroupsUpdatedAtUtc } else { $null }
            entraDeviceId                    = if ($audit.PSObject.Properties['entraDeviceId']) { [string] $audit.entraDeviceId } else { $null }
            appliedExtensionAttributes       = $actionDetails['appliedExtensionAttributes']
            targetDeviceGroupIds             = $actionDetails['targetDeviceGroupIds']
            addedDeviceGroupIds              = $actionDetails['addedDeviceGroupIds']
            removedDeviceGroupIds            = $actionDetails['removedDeviceGroupIds']
            administrativeUnitName           = if ($audit.PSObject.Properties['administrativeUnitName']) { [string] $audit.administrativeUnitName } else { $null }
            removedAdministrativeUnits       = $actionDetails['removedAdministrativeUnits']
            lastUpdatedAtUtc                  = if ($lastUpdated.Count -gt 0) { $lastUpdated[0].ToUniversalTime().ToString('o') } else { $null }
        }
    })

# The array wrapper above keeps imports an array for zero, one or many rows.
# count describes this returned result, not all records retained in Storage.
Send-JsonResponse -StatusCode OK -Body @{
    imports       = $history
    count         = $history.Count
    correlationId = $correlationId
}
