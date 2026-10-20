# Project-Version: 1.4.20261020.12
# Author: andreas.lucas@outlook.com (aka Kili)

# Copyright 2026 Andreas Lucas
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the project root for license information.

<#
.SYNOPSIS
Processes an authenticated Autopilot device import HTTP request.

.DESCRIPTION
Azure Functions PowerShell HTTP-trigger entry point. It validates the Easy Auth
client principal and requested Group Tag against the configured Entra group
policy. It then validates the device payload and uses
the Function managed identity to create an imported Windows Autopilot device
identity through Microsoft Graph.

.PARAMETER Request
Azure Functions HTTP request object. The JSON body must contain serialNumber,
hardwareIdentifier, and groupTag. Easy Auth must provide the Base64-encoded
x-ms-client-principal header.

.PARAMETER TriggerMetadata
Metadata supplied by the Azure Functions PowerShell worker for the invocation.

.INPUTS
None. Azure Functions binds Request and TriggerMetadata at runtime.

.OUTPUTS
An Azure Functions HTTP output binding. Successful requests return HTTP 202
with importId, serialNumber, groupTag, status, and correlationId. Error
responses include a stable error code and correlationId.

.NOTES
Reads the group-to-tag policy from the private configuration blob. The legacy
TAG_AUTHORIZATION_POLICY application setting is used only as an upgrade
fallback. profile.ps1 must authenticate the system-assigned managed identity
before this handler requests a Microsoft Graph token.
#>

using namespace System.Net

param($Request, $TriggerMetadata, $TagPolicyBlob)

$modulePath = Join-Path $PSScriptRoot '..\src\AutopilotImport\AutopilotImport.psm1'
Import-Module $modulePath -Force

# Keep the original arrival time for the asynchronous audit timeline and use
# one correlation ID across this request's responses, logs and queued work.
$requestReceivedAtUtc = [datetime]::UtcNow.ToString('o')
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

    # The Functions host sends this binding as the HTTP response. The caller
    # must return separately when no further processing should take place.
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $StatusCode
        Headers    = $responseHeaders
        Body       = ($Body | ConvertTo-Json -Depth 8 -Compress)
    })
}

# Prefer the centrally managed blob policy; the application setting supports
# deployments that have not yet migrated their policy into Blob Storage.
$tagAuthorizationPolicyJson = ConvertFrom-BlobBindingContent -Value $TagPolicyBlob

if ([string]::IsNullOrWhiteSpace($tagAuthorizationPolicyJson)) {
    $tagAuthorizationPolicyJson = $env:TAG_AUTHORIZATION_POLICY
}
if ([string]::IsNullOrWhiteSpace($tagAuthorizationPolicyJson)) {
    Write-Error "[$correlationId] Required application settings are missing."
    Send-JsonResponse -StatusCode InternalServerError -Body @{
        error         = 'serviceNotConfigured'
        correlationId = $correlationId
    }
    return
}

try {
    # Retain array semantics even when JSON contains only one policy rule.
    $tagAuthorizationPolicy = ConvertTo-TagAuthorizationPolicy -Rules @($tagAuthorizationPolicyJson | ConvertFrom-Json -ErrorAction Stop) -AllowEmpty
}
catch {
    # Preserve the legacy invalid-JSON fallback, but a valid empty blob must
    # not reactivate old rules from the application setting.
    try {
        if ([string]::IsNullOrWhiteSpace($env:TAG_AUTHORIZATION_POLICY)) {
            throw 'Tag authorization policy is missing.'
        }
        $tagAuthorizationPolicy = ConvertTo-TagAuthorizationPolicy -Rules @($env:TAG_AUTHORIZATION_POLICY | ConvertFrom-Json -ErrorAction Stop) -AllowEmpty
    }
    catch {
        Write-Error "[$correlationId] Tag authorization policy is invalid: $($_.Exception.Message)"
        Send-JsonResponse -StatusCode InternalServerError -Body @{
            error         = 'serviceNotConfigured'
            correlationId = $correlationId
        }
        return
    }
}

# Easy Auth validates the user token upstream and injects this trusted header.
# The worker decodes the principal; this is not a replacement for Easy Auth.
$principalHeader = $Request.Headers['x-ms-client-principal']
if ([string]::IsNullOrWhiteSpace($principalHeader)) {
    Send-JsonResponse -StatusCode Unauthorized -Body @{
        error         = 'authenticationRequired'
        correlationId = $correlationId
    }
    return
}

try {
    $principal = ConvertFrom-ClientPrincipalHeader -HeaderValue $principalHeader
}
catch {
    Send-JsonResponse -StatusCode Unauthorized -Body @{
        error         = 'invalidPrincipal'
        correlationId = $correlationId
    }
    return
}

# GET polls an existing import; it must never fall through to POST creation.
# A valid ID identifies the imported Graph record, not an entire import batch.
if ([string] $Request.Method -eq 'GET') {
    $importId = [string] $Request.Query.importId
    $parsedImportId = [guid]::Empty
    if (-not [guid]::TryParse($importId, [ref] $parsedImportId)) {
        Send-JsonResponse -StatusCode BadRequest -Body @{
            error         = 'invalidImportId'
            correlationId = $correlationId
        }
        return
    }

    try {
        # Graph requests run as the Function identity. Normalize Az.Accounts
        # token types to the SecureString expected by the Graph calls/helpers.
        $tokenResult = Get-AzAccessToken `
            -ResourceUrl 'https://graph.microsoft.com/' `
            -ErrorAction Stop
        $graphToken = if ($tokenResult.Token -is [Security.SecureString]) {
            $tokenResult.Token
        }
        else {
            ConvertTo-SecureString ([string] $tokenResult.Token) -AsPlainText -Force
        }
        # Recheck current policy-group memberships instead of trusting group
        # claims that may be stale since the caller's token was issued.
        $principal = Get-CurrentPolicyPrincipal `
            -Principal $principal `
            -Policy $tagAuthorizationPolicy `
            -AccessToken $graphToken
        $graphResponse = Invoke-RestMethod `
            -Method Get `
            -Uri "https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities/$parsedImportId" `
            -Authentication Bearer `
            -Token $graphToken `
            -ErrorAction Stop
        # Knowing an import ID is not sufficient: the caller must currently
        # be allowed to use the Group Tag on the retrieved Graph record.
        $authorizedGroupTag = Resolve-AuthorizedGroupTag `
            -Principal $principal `
            -Policy $tagAuthorizationPolicy `
            -RequestedGroupTag ([string] $graphResponse.groupTag)

        # Intune import completion and downstream Entra updates are separate
        # stages; a completed Graph import does not finish the whole workflow.
        $intuneStatus = ([string] $graphResponse.state.deviceImportStatus).ToLowerInvariant()
        $extensionAttribute = if ([string]::IsNullOrWhiteSpace(
                $env:DEVICE_TAG_EXTENSION_ATTRIBUTE)) {
            'extensionAttribute1'
        }
        else {
            $env:DEVICE_TAG_EXTENSION_ATTRIBUTE
        }
        $extensionAttributeStatus = if ($intuneStatus -eq 'error') {
            'notApplicable'
        }
        else {
            'pending'
        }
        $extensionAttributeValue = $null
        $entraDeviceId = $null
        $processingFailure = $null
        $audit = $null
        # Legacy policies map the tag to one configured extension attribute.
        # Explicit policy actions can replace that expectation with several
        # attribute/value pairs, all of which must match on the Entra device.
        $actions = Get-DevicePolicyActions -Policy $tagAuthorizationPolicy -GroupTag $authorizedGroupTag
        $expectedAttributes = [ordered]@{ $extensionAttribute = $authorizedGroupTag }
        if ($actions.PSObject.Properties['extensionAttributes']) {
            $expectedAttributes = $actions.extensionAttributes | ConvertTo-Json -Depth 4 | ConvertFrom-Json -AsHashtable
        }

        if ($intuneStatus -eq 'complete') {
            try {
                # Follow imported identity -> registered Autopilot identity ->
                # Entra device. These objects may appear at different times.
                $registrationId = Get-AutoPilotDeviceRegistrationId `
                    -ImportedDevice $graphResponse
                $registeredDevice = Invoke-RestMethod `
                    -Method Get `
                    -Uri "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$registrationId" `
                    -Authentication Bearer `
                    -Token $graphToken `
                    -ErrorAction Stop
                $parsedEntraDeviceId = [guid]::Empty
                if (-not [guid]::TryParse(
                        [string] $registeredDevice.azureActiveDirectoryDeviceId,
                        [ref] $parsedEntraDeviceId)) {
                    throw 'The Entra device is not available yet.'
                }
                $entraDeviceId = $parsedEntraDeviceId.ToString()
                # deviceId is the Entra device's alternate key, not its
                # directory object ID; query it explicitly with devices(...).
                $entraDevice = Invoke-RestMethod `
                    -Method Get `
                    -Uri "https://graph.microsoft.com/v1.0/devices(deviceId='$entraDeviceId')?`$select=deviceId,extensionAttributes" `
                    -Authentication Bearer `
                    -Token $graphToken `
                    -ErrorAction Stop
                $deviceAttributes = $entraDevice.extensionAttributes
                $extensionProperty = if ($null -ne $deviceAttributes) {
                    $deviceAttributes.PSObject.Properties[$extensionAttribute]
                } else { $null }
                if ($extensionProperty) {
                    $extensionAttributeValue = [string] $extensionProperty.Value
                }
                # Missing attributes or case-sensitive value differences keep
                # the workflow pending until every expected value is present.
                $attributesMatch = $true
                foreach ($key in $expectedAttributes.Keys) {
                    $actual = if ($null -ne $deviceAttributes) { $deviceAttributes.PSObject.Properties[$key] } else { $null }
                    if (-not $actual -or [string] $actual.Value -cne [string] $expectedAttributes[$key]) {
                        $attributesMatch = $false
                    }
                }
                if ($attributesMatch) {
                    $extensionAttributeStatus = 'complete'
                }
            }
            catch {
                # Entra resolution/read failures do not invalidate the Intune
                # status. Leave attributes pending and allow subsequent polls.
                Write-Information "[$correlationId] Extension attribute status is still pending for import '$parsedImportId': $($_.Exception.Message)"
            }
        }
        if ($actions.PSObject.Properties['groupTag']) {
            # Policies with a Group Tag action additionally require the queue
            # worker's completion marker; matching attributes alone do not
            # prove that downstream policy processing has finished.
            $audit = (Get-ImportAuditRecords -ImportId $parsedImportId -AccessToken (Get-ImportAuditAccessToken))[[string] $parsedImportId]
            if (-not $audit -or -not $audit.PSObject.Properties['processingCompletedAtUtc'] -or -not $audit.processingCompletedAtUtc) {
                $extensionAttributeStatus = 'pending'
            }
            if (Test-ProcessingFailed -AuditRecord $audit) {
                $extensionAttributeStatus = 'error'
                $processingFailure = $audit
            }
        }
        else {
            # Without a Group Tag action the audit record only adds progress
            # details, so an unavailable audit store must not fail the poll.
            try {
                $audit = (Get-ImportAuditRecords -ImportId $parsedImportId -AccessToken (Get-ImportAuditAccessToken))[[string] $parsedImportId]
            }
            catch {
                Write-Information "[$correlationId] Import progress details are unavailable for '$parsedImportId': $($_.Exception.Message)"
            }
        }
    }
    catch [System.UnauthorizedAccessException] {
        # Distinguish a definitive authorization denial from an unavailable
        # Graph/Storage lookup, which follows the generic 502 error path.
        Send-JsonResponse -StatusCode Forbidden -Body @{
            error         = 'importStatusNotAllowed'
            correlationId = $correlationId
        }
        return
    }
    catch {
        Write-Error "[$correlationId] Import status lookup failed for '$parsedImportId': $($_.Exception.Message)"
        Send-JsonResponse -StatusCode BadGateway -Body @{
            error         = 'importStatusLookupFailed'
            correlationId = $correlationId
        }
        return
    }

    # A Graph import error takes precedence. Otherwise report complete only
    # when both Intune and the downstream attribute check are complete.
    $workflowStatus = if ($intuneStatus -eq 'error' -or $extensionAttributeStatus -eq 'error') {
        'error'
    }
    elseif ($intuneStatus -eq 'complete' -and
        $extensionAttributeStatus -eq 'complete') {
        'complete'
    }
    else {
        'pending'
    }
    $statusBody = [ordered]@{
        importId                = $graphResponse.id
        serialNumber            = $graphResponse.serialNumber
        groupTag                = $authorizedGroupTag
        status                  = $graphResponse.state.deviceImportStatus
        workflowStatus          = $workflowStatus
        deviceErrorCode         = $graphResponse.state.deviceErrorCode
        deviceErrorName         = $graphResponse.state.deviceErrorName
        extensionAttributeName  = $extensionAttribute
        extensionAttributeStatus = $extensionAttributeStatus
        extensionAttributeValue = $extensionAttributeValue
        expectedExtensionAttributes = $expectedAttributes
        entraDeviceId           = $entraDeviceId
        processingError         = if ($processingFailure) { [string] $processingFailure.processingError } else { $null }
        processingErrorStep     = if ($processingFailure) { [string] $processingFailure.processingErrorStep } else { $null }
        processingStage         = if ($audit) { Get-TagChangeProcessingStage -AuditRecord $audit } else { $null }
        correlationId           = $correlationId
    }
    # Step timestamps let clients show which stage a pending import is in.
    foreach ($name in @(
            'requestReceivedAtUtc', 'graphImportCreatedAtUtc', 'queuedAtUtc',
            'processingStartedAtUtc', 'graphImportCompletedAtUtc',
            'autopilotGroupTagUpdatedAtUtc', 'entraDeviceResolvedAtUtc',
            'extensionAttributeUpdatedAtUtc', 'deviceGroupsUpdatedAtUtc',
            'administrativeUnitAssignedAtUtc', 'processingErrorAtUtc',
            'processingCompletedAtUtc'
        )) {
        $statusBody[$name] = if ($audit -and $audit.PSObject.Properties[$name]) {
            ConvertTo-AuditTimestamp $audit.$name
        } else { $null }
    }
    $statusBody['processingAttempt'] = if ($audit -and $audit.PSObject.Properties['processingAttempt'] -and
        $audit.processingAttempt) { [int] $audit.processingAttempt } else { $null }
    Send-JsonResponse -StatusCode OK -Body $statusBody
    return
}

# POST creation starts here after the GET branch has returned. Refresh the
# caller's memberships before using the requested tag to authorize any write.
try {
    $tokenResult = Get-AzAccessToken `
        -ResourceUrl 'https://graph.microsoft.com/' `
        -ErrorAction Stop
    $graphToken = if ($tokenResult.Token -is [Security.SecureString]) {
        $tokenResult.Token
    }
    else {
        ConvertTo-SecureString ([string] $tokenResult.Token) -AsPlainText -Force
    }
    $principal = Get-CurrentPolicyPrincipal `
        -Principal $principal `
        -Policy $tagAuthorizationPolicy `
        -AccessToken $graphToken
}
catch {
    Write-Error "[$correlationId] Current group membership lookup failed: $($_.Exception.Message)"
    Send-JsonResponse -StatusCode BadGateway -Body @{
        error         = 'groupMembershipLookupFailed'
        correlationId = $correlationId
    }
    return
}

try {
    # The worker may provide either raw JSON or an already decoded body.
    $requestBody = if ($Request.Body -is [string]) {
        $Request.Body | ConvertFrom-Json
    }
    else {
        $Request.Body
    }

    # Resolve the permitted tag with its configured casing, then derive the
    # administrative-unit target from policy rather than trusting client input.
    $groupTag = Resolve-AuthorizedGroupTag `
        -Principal $principal `
        -Policy $tagAuthorizationPolicy `
        -RequestedGroupTag ([string] $requestBody.groupTag)
    $administrativeUnitName = `
        Resolve-AdministrativeUnitName `
            -Policy $tagAuthorizationPolicy `
            -GroupTag $groupTag `
            -Principal $principal
}
catch [System.UnauthorizedAccessException] {
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

try {
    # Delegate payload validation and Graph field mapping to the shared helper.
    # Use the authorized tag, not the unchecked value from the request body.
    $graphPayload = ConvertTo-AutoPilotImportPayload `
        -RequestBody $requestBody `
        -GroupTag $groupTag
}
catch {
    Send-JsonResponse -StatusCode BadRequest -Body @{
        error         = 'invalidRequest'
        message       = $_.Exception.Message
        correlationId = $correlationId
    }
    return
}

# Capture caller identity for audit attribution. The Function identity performs
# the Graph write, so Graph authentication alone would not identify this user.
$actorId = @($principal.claims | Where-Object {
    $_.typ -in @('oid', 'http://schemas.microsoft.com/identity/claims/objectidentifier')
} | Select-Object -First 1).val
$actorUserPrincipalName = @($principal.claims | Where-Object {
    $_.typ -in @(
        'preferred_username'
        'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn'
        'email'
    )
} | Select-Object -First 1).val
$actorDisplayName = @($principal.claims | Where-Object {
    $_.typ -in @(
        'name'
        'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name'
    )
} | Select-Object -First 1).val

try {
    # Creating the imported identity starts Intune's asynchronous import.
    # A successful Graph POST does not yet mean the device is fully processed.
    $graphResponse = Invoke-RestMethod `
        -Method Post `
        -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities' `
        -Authentication Bearer `
        -Token $graphToken `
        -ContentType 'application/json' `
        -Body ($graphPayload | ConvertTo-Json -Depth 8 -Compress) `
        -ErrorAction Stop
}
catch {
    Write-Error "[$correlationId] Graph import failed for serial '$($graphPayload.serialNumber)' requested by '$actorId': $($_.Exception.Message)"
    Send-JsonResponse -StatusCode BadGateway -Body @{
        error         = 'graphImportFailed'
        correlationId = $correlationId
    }
    return
}

# Carry the initial audit snapshot into queued processing so later steps can
# retain request identity and timing even if the first Storage write fails.
$graphImportCreatedAtUtc = [datetime]::UtcNow.ToString('o')
$queuedAtUtc = [datetime]::UtcNow.ToString('o')
$auditProperties = [ordered]@{
    actorObjectId             = [string] $actorId
    actorUserPrincipalName    = [string] $actorUserPrincipalName
    actorDisplayName          = [string] $actorDisplayName
    requestReceivedAtUtc      = $requestReceivedAtUtc
    graphImportCreatedAtUtc   = $graphImportCreatedAtUtc
    queuedAtUtc               = $queuedAtUtc
    correlationId             = $correlationId
    batchImportId             = [string] $graphResponse.importId
    serialNumber              = [string] $graphPayload.serialNumber
    groupTag                  = [string] $groupTag
    administrativeUnitName    = [string] $administrativeUnitName
    # Keep the hardware hash in the internal audit snapshot; the SHA-256 index
    # supports history lookups without sending that raw hash as a filter.
    deviceHash                = [string] $graphPayload.hardwareIdentifier
    deviceHashSha256          = Get-DeviceHashSha256 `
        -DeviceHash ([string] $graphPayload.hardwareIdentifier)
}
try {
    # The individual Graph record ID is the audit key; its importId property
    # above is the separate batch identifier.
    Set-ImportAuditRecord `
        -ImportId ([guid] $graphResponse.id) `
        -Properties $auditProperties `
        -AccessToken (Get-ImportAuditAccessToken)
}
catch {
    # Graph has already accepted the import. Preserve the queued retry path
    # instead of reporting this initial audit-write failure as an import failure.
    Write-Warning "[$correlationId] Initial audit record for import '$($graphResponse.id)' could not be written and will be retried by queued processing: $($_.Exception.Message)"
}

Write-Information "[$correlationId] Autopilot import '$($graphResponse.id)' created for serial '$($graphPayload.serialNumber)' by '$actorId'."
# Hand off to ProcessDeviceAttribute through the queue output binding. The
# message includes the audit snapshot needed to resume downstream processing.
Push-OutputBinding -Name DeviceAttributeUpdate -Value (@{
    importId = [string] $graphResponse.id
    groupTag = $groupTag
    administrativeUnitName = `
        $administrativeUnitName
    audit = $auditProperties
} | ConvertTo-Json -Compress)
# HTTP 202 acknowledges accepted work, not completion. The caller can poll
# this endpoint with GET and the returned importId to follow workflow status.
Send-JsonResponse -StatusCode Accepted -Body @{
    importId      = $graphResponse.id
    serialNumber  = $graphResponse.serialNumber
    groupTag      = $graphResponse.groupTag
    status        = $graphResponse.state.deviceImportStatus
    correlationId = $correlationId
}