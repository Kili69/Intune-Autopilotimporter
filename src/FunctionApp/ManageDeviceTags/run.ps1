# Project-Version: 1.4.20261020.2
# Author: andreas.lucas@outlook.com (aka Kili)

<#
.SYNOPSIS
Lists eligible Autopilot devices and queues authorized Group Tag changes.

.DESCRIPTION
HTTP entry point for GET and POST /api/devices/tags/assignments.

GET without operationId returns registered Autopilot devices whose
enrollmentState is notContacted, provided the caller has at least one
authorized tag. It does not restrict devices by their current Group Tag.
Results include device ID, serial number, current tag, and available Entra
group/administrative-unit display names, sorted by serial number. Because
Intune reports a changed Autopilot groupTag only after a propagation delay,
tag changes completed within the last 60 minutes are applied from their
audit records while Autopilot still returns the previous tag.

POST requires deviceId (registered Autopilot identity GUID) and groupTag in
the JSON body. The destination tag must be authorized for the caller's current
policy-group memberships. The device must still be notContacted and its
current tag must differ from the destination. The administrative-unit target
is resolved from policy, not supplied by the caller.

Before queuing work, the handler writes a tagChange audit record with a new
operationId, caller identity, previous/destination tags and timestamps.
ProcessDeviceAttribute applies the changes asynchronously using the shared
device-attribute-updates queue. This handler does not update the device itself.

GET with operationId reads that operation's audit record. Only its original
requester may view the status. A processingCompletedAtUtc value means complete;
otherwise the returned status is pending.

.PARAMETER Request
Functions HTTP request object. Easy Auth must provide x-ms-client-principal.
GET optionally accepts the operationId query parameter; POST accepts a JSON
object containing deviceId and groupTag. The body may be text or an object
already deserialized by the worker.

.PARAMETER TriggerMetadata
Metadata supplied by the Functions worker. Not read by this implementation.

.PARAMETER TagPolicyBlob
Input binding for configuration/tag-authorization-policy.json through the
AzureWebJobsStorage connection. Blank binding content falls back to
TAG_AUTHORIZATION_POLICY. Invalid policy JSON fails initialization; an empty
policy grants no device access.

.INPUTS
None through the PowerShell pipeline. The Functions host supplies parameters.

.OUTPUTS
HttpResponseContext written to the Response output binding. All JSON responses
include correlationId, with the same value in X-Correlation-Id, and
Cache-Control no-store.

HTTP 200, device list: devices array and count.
HTTP 200, operation status: operationId, serialNumber, groupTag,
previousGroupTag, status and workflowStatus (pending, complete or error),
processingStage (queued, processing, complete or error) and the ISO 8601 UTC
step timestamps recorded so far (null when not reached). Error responses also
include processingError and processingErrorStep from the queue worker.
HTTP 202, queued change: operationId, serialNumber, groupTag and status queued.
Successful POST also writes a JSON message to DeviceAttributeUpdate.

.EXAMPLE
Invoke-RestMethod -Method Get `
    -Uri 'https://<function-app>.azurewebsites.net/api/devices/tags/assignments' `
    -Headers @{ Authorization = "Bearer $accessToken" }

Lists eligible devices using a user API token accepted by Easy Auth.

.EXAMPLE
$uri = 'https://<function-app>.azurewebsites.net/api/devices/tags/assignments'
$operation = Invoke-RestMethod -Method Post -Uri $uri `
    -Headers @{ Authorization = "Bearer $accessToken" } `
    -ContentType 'application/json' `
    -Body (@{ deviceId = $autopilotDeviceId; groupTag = 'BG-Default' } |
        ConvertTo-Json -Compress)
Invoke-RestMethod -Method Get -Uri "$uri`?operationId=$($operation.operationId)" `
    -Headers @{ Authorization = "Bearer $accessToken" }

Queues a change and polls its status once. HTTP 202 does not mean that the
worker has finished; subsequent polls may still return pending.

.NOTES
Requires Easy Auth, the shared AutopilotImport module, an authenticated Az
context (normally the Function managed identity established by profile.ps1),
Microsoft Graph permissions for device/membership reads, and Storage access
for audit records and queue output. function.json defines bindings and route.

The trigger uses authLevel anonymous because Easy Auth handles authentication
upstream; protect the trusted principal-header boundary. Graph membership
checks refresh the caller's policy groups before any of the three modes runs.

Error mapping:
401 authenticationRequired: UnauthorizedAccessException during initialization.
500 serviceNotConfigured: other initialization failures, including principal
decoding, policy parsing, token acquisition or membership lookup failures.
400 invalidOperationId: status query contains a non-GUID operation ID.
404 operationNotFound: audit record missing or not a tagChange operation.
403 operationNotAllowed: operation belongs to another requester.
502 operationStatusLookupFailed: operation-status lookup failed.
502 deviceLookupFailed: device listing or membership enrichment failed.
403 groupTagNotAllowed: destination-tag authorization denied.
400 invalidRequest: other change-validation failures; includes a message.
502 operationQueueFailed: audit write failed; no work is queued by this path.

Unexpected initialization, lookup and audit-write failures are logged with
the correlation ID. Module import and output-binding failures are outside
these explicit error mappings and may be handled by the Functions host.
#>

using namespace System.Net

param($Request, $TriggerMetadata, $TagPolicyBlob)

$modulePath = Join-Path $PSScriptRoot '..\src\AutopilotImport\AutopilotImport.psm1'
Import-Module $modulePath -Force

# Correlate HTTP responses with server logs. Device visibility and operation
# status depend on current authorization, so responses must not be cached.
$correlationId = [guid]::NewGuid().ToString()
$responseHeaders = @{
    'Content-Type'     = 'application/json'
    'X-Correlation-Id' = $correlationId
    'Cache-Control'    = 'no-store'
}

function Send-JsonResponse {
    <#
    .SYNOPSIS
    Writes a JSON HTTP response through the Functions Response output binding.

    .DESCRIPTION
    Builds an HttpResponseContext using the supplied status and body together
    with the invocation's script-scoped responseHeaders. Serializes the body
    as compressed JSON at depth 10. The body must already contain correlationId;
    this helper does not add envelope properties or end script execution.

    .PARAMETER StatusCode
    System.Net.HttpStatusCode to send to the caller.

    .PARAMETER Body
    Success or error payload to serialize as the HTTP response body.

    .INPUTS
    None through the pipeline. Values are supplied by named parameters.

    .OUTPUTS
    HttpResponseContext written to Response via Push-OutputBinding rather than
    returned as a pipeline object.

    .EXAMPLE
    Send-JsonResponse -StatusCode OK -Body @{
        devices = @(); count = 0; correlationId = $correlationId
    }

    Writes a successful empty device-list response.

    .NOTES
    Requires the Functions worker output-binding command and responseHeaders
    from the enclosing invocation. Serialization/binding errors propagate.
    Callers must return separately when processing should stop.
    #>
    param(
        [Parameter(Mandatory)]
        [HttpStatusCode] $StatusCode,

        [Parameter(Mandatory)]
        [object] $Body
    )

    # The Functions host sends this binding as the HTTP response. Depth 10
    # preserves nested response data; callers return separately when finished.
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $StatusCode
        Headers    = $responseHeaders
        Body       = ($Body | ConvertTo-Json -Depth 10 -Compress)
    })
}

function Get-ActorClaim {
    <#
    .SYNOPSIS
    Returns the first caller claim matching any supported claim type.

    .DESCRIPTION
    Searches the decoded principal's claims collection for a typ value in
    ClaimType and converts the first matching claim's val to a string.
    Selection follows claim order in Principal, not priority in ClaimType.
    Alternative names support short and fully qualified Easy Auth claim types.

    .PARAMETER Principal
    Decoded Easy Auth principal with a claims collection containing typ and val
    properties. The caller is responsible for decoding/trusting the principal.

    .PARAMETER ClaimType
    Accepted claim-type names, such as oid and the fully qualified object-ID
    claim type. PowerShell's default case-insensitive membership comparison
    is used.

    .INPUTS
    None through the pipeline. Supply Principal and ClaimType explicitly.

    .OUTPUTS
    System.String. The first matching value, or an empty string when no claim
    matches or its value is null. This helper does not validate GUIDs or UPNs.

    .EXAMPLE
    $principal = [pscustomobject]@{
        claims = @([pscustomobject]@{ typ = 'oid'; val = 'user-object-id' })
    }
    Get-ActorClaim -Principal $principal -ClaimType @('oid')

    Returns user-object-id as a string.
    #>
    param(
        [Parameter(Mandatory)]
        [object] $Principal,

        [Parameter(Mandatory)]
        [string[]] $ClaimType
    )

    # Accept alternative Easy Auth claim names and take the first matching
    # claim in principal order. An absent value becomes an empty string.
    return [string] (@($Principal.claims | Where-Object {
        $_.typ -in $ClaimType
    } | Select-Object -First 1).val)
}

function Get-GraphCollection {
    <#
    .SYNOPSIS
    Retrieves every page of a Microsoft Graph collection.

    .DESCRIPTION
    Sends authenticated GET requests starting at Uri, accumulating each
    response's value entries and following @odata.nextLink until it is absent
    or blank. Uses the same token for all pages and follows Graph's returned
    continuation URL unchanged.

    .PARAMETER Uri
    Initial absolute Microsoft Graph collection URL, optionally including
    query parameters such as $select or $top. Expects a collection response
    with value entries, not a single-resource response.

    .PARAMETER AccessToken
    SecureString Microsoft Graph bearer token. The caller obtains it from the
    Function's Azure context and must provide permissions for the collection.

    .INPUTS
    None through the pipeline. Supply Uri and AccessToken explicitly.

    .OUTPUTS
    Collection entries emitted to the PowerShell pipeline after all pages are
    retrieved. Callers use @() to retain array semantics for zero or one item.
    No entries are emitted when the collection is empty.

    .EXAMPLE
    $devices = @(Get-GraphCollection `
        -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?$top=100' `
        -AccessToken $graphToken)

    Retrieves all registered Autopilot identities, including subsequent pages.

    .NOTES
    Any REST request failure terminates this helper and propagates to the
    caller; accumulated partial results are not returned. There is no retry,
    page limit, filtering or deduplication in this helper. Uri and continuation
    URLs must originate from trusted application code/Microsoft Graph.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Uri,

        [Parameter(Mandatory)]
        [Security.SecureString] $AccessToken
    )

    # Graph limits each page independently. Follow its supplied nextLink until
    # exhausted so device and membership lists are not limited to page one.
    $items = @()
    $nextUri = $Uri
    while (-not [string]::IsNullOrWhiteSpace($nextUri)) {
        $response = Invoke-RestMethod `
            -Method Get `
            -Uri $nextUri `
            -Authentication Bearer `
            -Token $AccessToken `
            -ErrorAction Stop
        $items += @($response.value)
        $nextUri = if ($response.PSObject.Properties['@odata.nextLink']) {
            [string] $response.'@odata.nextLink'
        }
        else {
            $null
        }
    }
    return $items
}

try {
    # Easy Auth validates the user's token upstream and injects this trusted
    # principal header; the anonymous Function binding is not authentication.
    $principalHeader = $Request.Headers['x-ms-client-principal']
    if ([string]::IsNullOrWhiteSpace($principalHeader)) {
        throw [UnauthorizedAccessException]::new('Authentication is required.')
    }
    $principal = ConvertFrom-ClientPrincipalHeader -HeaderValue $principalHeader
    # Prefer the central blob policy. Only blank binding content triggers the
    # legacy setting fallback; invalid JSON follows the initialization error path.
    $policyJson = ConvertFrom-BlobBindingContent -Value $TagPolicyBlob
    if ([string]::IsNullOrWhiteSpace($policyJson)) {
        $policyJson = $env:TAG_AUTHORIZATION_POLICY
    }
    if ([string]::IsNullOrWhiteSpace($policyJson)) {
        throw 'Tag authorization policy is missing.'
    }
    $policy = ConvertTo-TagAuthorizationPolicy -Rules @($policyJson | ConvertFrom-Json -ErrorAction Stop) -AllowEmpty
    # Graph calls use the Function's Azure identity, not the caller's token.
    # Normalize old/plain-text and newer/SecureString Az.Accounts results.
    $tokenResult = Get-AzAccessToken `
        -ResourceUrl 'https://graph.microsoft.com/' `
        -ErrorAction Stop
    $graphToken = if ($tokenResult.Token -is [Security.SecureString]) {
        $tokenResult.Token
    }
    else {
        ConvertTo-SecureString ([string] $tokenResult.Token) -AsPlainText -Force
    }
    # Replace potentially stale group claims with current policy-group
    # memberships before deriving the tags the caller may assign.
    $principal = Get-CurrentPolicyPrincipal `
        -Principal $principal `
        -Policy $policy `
        -AccessToken $graphToken
    $authorizedTags = @(Get-AuthorizedGroupTags `
        -Principal $principal `
        -Policy $policy)
}
catch [UnauthorizedAccessException] {
    Send-JsonResponse -StatusCode Unauthorized -Body @{
        error         = 'authenticationRequired'
        correlationId = $correlationId
    }
    return
}
catch {
    # Keep initialization diagnostics in the log, exposing only a stable
    # service error and correlation ID to the client.
    Write-Error "[$correlationId] Device Tag management initialization failed: $($_.Exception.Message)"
    Send-JsonResponse -StatusCode InternalServerError -Body @{
        error         = 'serviceNotConfigured'
        correlationId = $correlationId
    }
    return
}

# Attribute queued changes to the initiating user and use that same object ID
# to restrict operation-status polling to the original requester.
$actorObjectId = Get-ActorClaim `
    -Principal $principal `
    -ClaimType @(
        'oid'
        'http://schemas.microsoft.com/identity/claims/objectidentifier'
    )

# GET with operationId polls a queued tag change; GET without it lists devices.
# The operation ID identifies an audit record, not an Autopilot device.
if ([string] $Request.Method -eq 'GET' -and
    -not [string]::IsNullOrWhiteSpace(
        [string] $Request.Query.operationId)) {
    $operationId = [guid]::Empty
    if (-not [guid]::TryParse(
            [string] $Request.Query.operationId,
            [ref] $operationId)) {
        Send-JsonResponse -StatusCode BadRequest -Body @{
            error         = 'invalidOperationId'
            correlationId = $correlationId
        }
        return
    }
    try {
        $record = (Get-ImportAuditRecords `
                -ImportId $operationId `
                -AccessToken (Get-ImportAuditAccessToken))[
                    $operationId.ToString()]
        # Audit Storage is shared with imports. An existing record is usable
        # here only when it represents a tagChange operation.
        if (-not $record -or
            [string] $record.operationType -ne 'tagChange') {
            Send-JsonResponse -StatusCode NotFound -Body @{
                error         = 'operationNotFound'
                correlationId = $correlationId
            }
            return
        }
        # Possessing the operation ID does not grant access to another user's
        # operation, even if both users can assign the same Group Tag.
        if ([string] $record.actorObjectId -ne $actorObjectId) {
            Send-JsonResponse -StatusCode Forbidden -Body @{
                error         = 'operationNotAllowed'
                correlationId = $correlationId
            }
            return
        }
        # The queue worker's completion timestamp is the status signal here.
        # Until it is present, this endpoint reports pending unless the worker
        # recorded a failure that needs administrator action.
        $processingFailed = Test-ProcessingFailed -AuditRecord $record
        $workflowStatus = if ($processingFailed) {
            'error'
        }
        elseif (-not [string]::IsNullOrWhiteSpace(
                [string] $record.processingCompletedAtUtc)) {
            'complete'
        }
        else {
            'pending'
        }
        $processingStage = Get-TagChangeProcessingStage -AuditRecord $record
        $statusBody = [ordered]@{
            operationId   = $operationId
            serialNumber  = [string] $record.serialNumber
            groupTag      = [string] $record.groupTag
            previousGroupTag = [string] $record.previousGroupTag
            status        = $workflowStatus
            workflowStatus = $workflowStatus
            processingStage = $processingStage
            processingError = if ($processingFailed) { [string] $record.processingError } else { $null }
            processingErrorStep = if ($processingFailed) { [string] $record.processingErrorStep } else { $null }
            correlationId = $correlationId
        }
        # Expose the worker's step timestamps so clients can show progress
        # between queuing and completion.
        foreach ($name in @(
                'requestReceivedAtUtc', 'queuedAtUtc', 'processingStartedAtUtc',
                'autopilotGroupTagUpdatedAtUtc', 'entraDeviceResolvedAtUtc',
                'extensionAttributeUpdatedAtUtc', 'deviceGroupsUpdatedAtUtc',
                'administrativeUnitAssignedAtUtc', 'processingErrorAtUtc',
                'processingCompletedAtUtc'
            )) {
            $statusBody[$name] = if ($record.PSObject.Properties[$name]) {
                ConvertTo-AuditTimestamp $record.$name
            } else { $null }
        }
        $statusBody['processingAttempt'] = if ($record.PSObject.Properties['processingAttempt'] -and
            $record.processingAttempt) { [int] $record.processingAttempt } else { $null }
        Send-JsonResponse -StatusCode OK -Body $statusBody
    }
    catch {
        Write-Error "[$correlationId] Tag change status lookup failed: $($_.Exception.Message)"
        Send-JsonResponse -StatusCode BadGateway -Body @{
            error         = 'operationStatusLookupFailed'
            correlationId = $correlationId
        }
    }
    return
}

if ([string] $Request.Method -eq 'GET') {
    try {
        # Fetch registered Autopilot devices, rather than temporary imported
        # identities, and apply the listing eligibility rules locally.
        $autopilotDevices = @(Get-GraphCollection `
            -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?$top=100' `
            -AccessToken $graphToken)
        # Any assignable tag enables listing of notContacted devices. The
        # device's current tag need not be among the caller's authorized tags.
        $visibleDevices = @($autopilotDevices | Where-Object {
            $authorizedTags.Count -gt 0 -and
            [string] $_.enrollmentState -ieq 'notContacted'
        } | ForEach-Object {
            $autopilotDevice = $_
            $groups = @()
            $administrativeUnits = @()
            $entraDeviceId = [guid]::Empty
            if ([guid]::TryParse(
                    [string] $autopilotDevice.azureActiveDirectoryDeviceId,
                    [ref] $entraDeviceId) -and
                $entraDeviceId -ne [guid]::Empty) {
                # The Autopilot record contains an Entra deviceId alternate
                # key. Resolve it to the directory object ID used by memberOf.
                $entraDevice = Invoke-RestMethod `
                    -Method Get `
                    -Uri "https://graph.microsoft.com/v1.0/devices(deviceId='$entraDeviceId')?`$select=id" `
                    -Authentication Bearer `
                    -Token $graphToken `
                    -ErrorAction Stop
                $memberships = @(Get-GraphCollection `
                    -Uri "https://graph.microsoft.com/v1.0/devices/$($entraDevice.id)/memberOf?`$select=id,displayName" `
                    -AccessToken $graphToken)
                # memberOf contains different directory object types. Return
                # separate, deduplicated display-name lists for groups and AUs.
                $groups = @($memberships | Where-Object {
                    [string] $_.'@odata.type' -eq '#microsoft.graph.group'
                } | ForEach-Object {
                    [string] $_.displayName
                } | Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_)
                } | Sort-Object -Unique)
                $administrativeUnits = @($memberships | Where-Object {
                    [string] $_.'@odata.type' -eq
                        '#microsoft.graph.administrativeUnit'
                } | ForEach-Object {
                    [string] $_.displayName
                } | Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_)
                } | Sort-Object -Unique)
            }
            # A device without a valid Entra deviceId still appears in the
            # result, with empty membership lists.
            [pscustomobject][ordered]@{
                id                  = [string] $autopilotDevice.id
                serialNumber        = [string] $autopilotDevice.serialNumber
                groupTag            = [string] $autopilotDevice.groupTag
                groups              = $groups
                administrativeUnits = $administrativeUnits
            }
        } | Sort-Object serialNumber)
        if ($visibleDevices.Count -gt 0) {
            try {
                # Autopilot reports a new groupTag only after a propagation
                # delay. Overlay recently completed changes so the list does
                # not show the previous tag right after a successful change.
                $nowUtc = [datetimeoffset]::UtcNow
                $recentTagChanges = @(Get-ImportAuditHistory `
                    -SinceUtc $nowUtc.AddHours(-24) `
                    -Top 1000 `
                    -AccessToken (Get-ImportAuditAccessToken))
                $visibleDevices = @(Resolve-RecentTagChangeGroupTag `
                    -Device $visibleDevices `
                    -AuditRecord $recentTagChanges `
                    -CompletedAfterUtc $nowUtc.AddMinutes(-60))
            }
            catch {
                Write-Warning "[$correlationId] Recent tag changes could not be applied to the device list: $($_.Exception.Message)"
            }
        }
        Send-JsonResponse -StatusCode OK -Body @{
            devices       = $visibleDevices
            count         = $visibleDevices.Count
            correlationId = $correlationId
        }
    }
    catch {
        # A Graph failure aborts the listing, including membership enrichment;
        # do not return a partial list as if the whole lookup succeeded.
        Write-Error "[$correlationId] Autopilot device lookup failed: $($_.Exception.Message)"
        Send-JsonResponse -StatusCode BadGateway -Body @{
            error         = 'deviceLookupFailed'
            correlationId = $correlationId
        }
    }
    return
}

# Both GET branches return above. POST validates the change here but leaves
# all device mutations to the asynchronous worker.
try {
    $requestBody = if ($Request.Body -is [string]) {
        $Request.Body | ConvertFrom-Json
    }
    else {
        $Request.Body
    }
    # deviceId is the registered Autopilot identity ID, not the Entra deviceId
    # alternate key used while enriching the device list.
    $registeredDeviceId = [guid]::Empty
    if (-not [guid]::TryParse(
            [string] $requestBody.deviceId,
            [ref] $registeredDeviceId)) {
        throw [ArgumentException]::new('deviceId is invalid.')
    }
    # Authorize the destination tag and preserve its configured casing.
    # Authorization is not based on the device's existing tag.
    $groupTag = Resolve-AuthorizedGroupTag `
        -Principal $principal `
        -Policy $policy `
        -RequestedGroupTag ([string] $requestBody.groupTag)
    $device = Invoke-RestMethod `
        -Method Get `
        -Uri "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$registeredDeviceId" `
        -Authentication Bearer `
        -Token $graphToken `
        -ErrorAction Stop
    # Re-read eligibility at submission time: the device may have enrolled
    # since the list was displayed. Also reject a case-insensitive no-op.
    if ([string] $device.enrollmentState -ine 'notContacted') {
        throw [InvalidOperationException]::new(
            'The device is no longer eligible for a Group Tag change.')
    }
    if ([string] $device.groupTag -ieq $groupTag) {
        throw [ArgumentException]::new(
            'The selected Group Tag is already assigned to the device.')
    }
    # Derive the administrative-unit target from the authorized policy,
    # rather than accepting a client-selected administrative unit.
    $administrativeUnitName = Resolve-AdministrativeUnitName `
        -Policy $policy `
        -GroupTag $groupTag `
        -Principal $principal
}
catch [UnauthorizedAccessException] {
    Send-JsonResponse -StatusCode Forbidden -Body @{
        error         = 'groupTagNotAllowed'
        correlationId = $correlationId
    }
    return
}
catch {
    Send-JsonResponse -StatusCode BadRequest -Body @{
        error         = 'invalidRequest'
        message       = $_.Exception.Message
        correlationId = $correlationId
    }
    return
}

# Generate a new tracking ID for each change so multiple operations on the
# same device remain distinguishable in history and status polling.
$operationId = [guid]::NewGuid()
$queuedAtUtc = [datetime]::UtcNow.ToString('o')
$auditProperties = [ordered]@{
    operationType             = 'tagChange'
    actorObjectId             = $actorObjectId
    actorUserPrincipalName    = Get-ActorClaim `
        -Principal $principal `
        -ClaimType @(
            'preferred_username'
            'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn'
            'email'
        )
    actorDisplayName          = Get-ActorClaim `
        -Principal $principal `
        -ClaimType @(
            'name'
            'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name'
        )
    requestReceivedAtUtc      = $queuedAtUtc
    queuedAtUtc               = $queuedAtUtc
    correlationId             = $correlationId
    registeredDeviceId        = $registeredDeviceId.ToString()
    serialNumber              = [string] $device.serialNumber
    # Retain both the source tag and authorized destination for audit history.
    previousGroupTag          = [string] $device.groupTag
    groupTag                  = $groupTag
    administrativeUnitName    = [string] $administrativeUnitName
}
try {
    # Persist the operation before queuing it. Unlike optional enrichment,
    # this write is required so accepted work has a pollable audit record.
    Set-ImportAuditRecord `
        -ImportId $operationId `
        -Properties $auditProperties `
        -AccessToken (Get-ImportAuditAccessToken)
}
catch {
    Write-Error "[$correlationId] Tag change operation could not be recorded: $($_.Exception.Message)"
    Send-JsonResponse -StatusCode BadGateway -Body @{
        error         = 'operationQueueFailed'
        correlationId = $correlationId
    }
    return
}

# Reuse the device-processing queue with operationId and registeredDeviceId
# so the worker can distinguish tag changes from newly imported devices.
Push-OutputBinding -Name DeviceAttributeUpdate -Value (@{
    operationId           = $operationId.ToString()
    registeredDeviceId    = $registeredDeviceId.ToString()
    groupTag              = $groupTag
    administrativeUnitName = $administrativeUnitName
    audit                 = $auditProperties
} | ConvertTo-Json -Depth 6 -Compress)
# HTTP 202 acknowledges queued work, not a completed device update. Poll GET
# with operationId to observe the worker's completion marker.
Send-JsonResponse -StatusCode Accepted -Body @{
    operationId   = $operationId
    serialNumber  = [string] $device.serialNumber
    groupTag      = $groupTag
    status        = 'queued'
    correlationId = $correlationId
}
