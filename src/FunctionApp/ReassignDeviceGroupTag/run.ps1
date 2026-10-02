# Project-Version: 1.3.20261002.3
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
.SYNOPSIS
Lists eligible Autopilot devices or changes an existing device's Group Tag.

.DESCRIPTION
Authorizes the requested target Group Tag against the caller's current Entra
group memberships, updates the registered Windows Autopilot device through
Microsoft Graph, and queues the existing Entra post-processing workflow.
GET returns every registered device whose enrollmentState is notContacted.

.PARAMETER Request
Azure Functions HTTP request. The JSON body must contain groupTag and exactly
one of deviceId or serialNumber.

.PARAMETER TagPolicyBlob
Current Group Tag authorization policy from private blob storage.
#>

using namespace System.Net

param($Request, $TriggerMetadata, $TagPolicyBlob)

$modulePath = Join-Path $PSScriptRoot '..\src\AutopilotImport\AutopilotImport.psm1'
Import-Module $modulePath -Force

$correlationId = [guid]::NewGuid().ToString()
$responseHeaders = @{
    'Content-Type'     = 'application/json'
    'X-Correlation-Id' = $correlationId
    'Cache-Control'    = 'no-store'
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

function Get-AutopilotDevices {
    param(
        [Parameter(Mandatory)]
        [object] $AccessToken
    )

    $requestUri = 'https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities'
    $devices = @()
    while (-not [string]::IsNullOrWhiteSpace($requestUri)) {
        $graphResponse = Invoke-RestMethod `
            -Method Get `
            -Uri $requestUri `
            -Authentication Bearer `
            -Token $AccessToken `
            -ErrorAction Stop
        $devices += @($graphResponse.value)
        $requestUri = if (
            $graphResponse.PSObject.Properties.Name -contains
            '@odata.nextLink') {
            [string] $graphResponse.'@odata.nextLink'
        }
        else {
            $null
        }
    }
    return $devices
}

$policyJson = ConvertFrom-BlobBindingContent -Value $TagPolicyBlob
if ([string]::IsNullOrWhiteSpace($policyJson)) {
    $policyJson = $env:TAG_AUTHORIZATION_POLICY
}
try {
    $policy = @($policyJson | ConvertFrom-Json)
    if ($policy.Count -eq 0) {
        throw 'Tag authorization policy is empty.'
    }
}
catch {
    Write-Error "[$correlationId] Tag authorization policy is invalid: $($_.Exception.Message)"
    Send-JsonResponse -StatusCode InternalServerError -Body @{
        error         = 'serviceNotConfigured'
        correlationId = $correlationId
    }
    return
}

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

$actorObjectId = [string] (@($principal.claims | Where-Object {
    $_.typ -in @(
        'oid'
        'http://schemas.microsoft.com/identity/claims/objectidentifier'
    )
} | Select-Object -First 1).val)
$actorUserPrincipalName = [string] (@($principal.claims | Where-Object {
    $_.typ -in @(
        'preferred_username'
        'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn'
        'email'
    )
} | Select-Object -First 1).val)

if ([string] $Request.Method -eq 'GET') {
    $requestedOperationId = [string] $Request.Query.operationId
    if (-not [string]::IsNullOrWhiteSpace($requestedOperationId)) {
        $operationId = [guid]::Empty
        if (-not [guid]::TryParse(
                $requestedOperationId,
                [ref] $operationId)) {
            Send-JsonResponse -StatusCode BadRequest -Body @{
                error         = 'invalidOperationId'
                correlationId = $correlationId
            }
            return
        }
        try {
            $records = Get-ImportAuditRecords `
                -ImportId $operationId `
                -AccessToken (Get-ImportAuditAccessToken) `
                -PartitionKey reassignments
            $record = $records[$operationId.ToString()]
            if (-not $record) {
                Send-JsonResponse -StatusCode NotFound -Body @{
                    error         = 'operationNotFound'
                    correlationId = $correlationId
                }
                return
            }
            if (-not [string]::Equals(
                    [string] $record.actorObjectId,
                    $actorObjectId,
                    [StringComparison]::OrdinalIgnoreCase)) {
                Send-JsonResponse -StatusCode Forbidden -Body @{
                    error         = 'operationNotAllowed'
                    correlationId = $correlationId
                }
                return
            }
            Send-JsonResponse -StatusCode OK -Body @{
                operationId          = $operationId
                workflowStatus       = [string] $record.workflowStatus
                status               = [string] $record.status
                serialNumber         = [string] $record.serialNumber
                groupTag             = [string] $record.groupTag
                failureReason        = [string] $record.failureReason
                processingStartedAtUtc = `
                    [string] $record.processingStartedAtUtc
                processingCompletedAtUtc = `
                    [string] $record.processingCompletedAtUtc
                correlationId        = $correlationId
            }
        }
        catch {
            Write-Error "[$correlationId] Reassignment status lookup failed: $($_.Exception.Message)"
            Send-JsonResponse -StatusCode BadGateway -Body @{
                error         = 'operationStatusLookupFailed'
                correlationId = $correlationId
            }
        }
        return
    }

    try {
        $tokenResult = Get-AzAccessToken `
            -ResourceUrl 'https://graph.microsoft.com/' `
            -ErrorAction Stop
        $graphToken = if ($tokenResult.Token -is [Security.SecureString]) {
            $tokenResult.Token
        }
        else {
            ConvertTo-SecureString `
                ([string] $tokenResult.Token) `
                -AsPlainText `
                -Force
        }
        $principal = Get-CurrentPolicyPrincipal `
            -Principal $principal `
            -Policy $policy `
            -AccessToken $graphToken
        if (@(Get-AuthorizedGroupTags `
                    -Principal $principal `
                    -Policy $policy).Count -eq 0) {
            Send-JsonResponse -StatusCode Forbidden -Body @{
                error         = 'groupTagNotAllowed'
                correlationId = $correlationId
            }
            return
        }
        $devices = @(
            Get-AutopilotDevices -AccessToken $graphToken |
            Where-Object {
                [string]::Equals(
                    [string] $_.enrollmentState,
                    'notContacted',
                    [StringComparison]::OrdinalIgnoreCase
                )
            } |
            ForEach-Object {
                [pscustomobject]@{
                    deviceId        = [string] $_.id
                    serialNumber    = [string] $_.serialNumber
                    groupTag        = [string] $_.groupTag
                    enrollmentState = [string] $_.enrollmentState
                }
            }
        )

        Send-JsonResponse -StatusCode OK -Body @{
            devices      = @($devices | Sort-Object serialNumber, deviceId)
            count        = $devices.Count
            correlationId = $correlationId
        }
    }
    catch {
        $graphError = if (
            -not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)
        ) {
            $_.ErrorDetails.Message
        }
        else {
            $_.Exception.Message
        }
        Write-Error "[$correlationId] Autopilot device list failed: $graphError"
        Send-JsonResponse -StatusCode BadGateway -Body @{
            error         = 'deviceListFailed'
            correlationId = $correlationId
        }
    }
    return
}

try {
    $requestBody = if ($Request.Body -is [string]) {
        $Request.Body | ConvertFrom-Json
    }
    else {
        $Request.Body
    }
    if ($null -eq $requestBody) {
        throw [ArgumentException]::new('Request body is required.')
    }

    $deviceId = [string] $requestBody.deviceId
    $serialNumber = [string] $requestBody.serialNumber
    $hasDeviceId = -not [string]::IsNullOrWhiteSpace($deviceId)
    $hasSerialNumber = -not [string]::IsNullOrWhiteSpace($serialNumber)
    if ($hasDeviceId -eq $hasSerialNumber) {
        throw [ArgumentException]::new(
            'Specify exactly one of deviceId or serialNumber.'
        )
    }
    if ($hasDeviceId) {
        $parsedDeviceId = [guid]::Empty
        if (-not [guid]::TryParse($deviceId, [ref] $parsedDeviceId)) {
            throw [ArgumentException]::new('deviceId must be a GUID.')
        }
        $deviceId = $parsedDeviceId.ToString()
    }
    else {
        $serialNumber = $serialNumber.Trim()
        if ($serialNumber.Length -gt 128) {
            throw [ArgumentException]::new(
                'serialNumber must not exceed 128 characters.'
            )
        }
    }
}
catch [ArgumentException] {
    Send-JsonResponse -StatusCode BadRequest -Body @{
        error         = 'invalidRequest'
        message       = $_.Exception.Message
        correlationId = $correlationId
    }
    return
}

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
        -Policy $policy `
        -AccessToken $graphToken
    $groupTag = Resolve-AuthorizedGroupTag `
        -Principal $principal `
        -Policy $policy `
        -RequestedGroupTag ([string] $requestBody.groupTag)
    $administrativeUnitName = Resolve-AdministrativeUnitName `
        -Policy $policy `
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
catch [ArgumentException] {
    Send-JsonResponse -StatusCode BadRequest -Body @{
        error         = 'invalidRequest'
        message       = $_.Exception.Message
        correlationId = $correlationId
    }
    return
}
catch {
    Write-Error "[$correlationId] Authorization failed: $($_.Exception.Message)"
    Send-JsonResponse -StatusCode BadGateway -Body @{
        error         = 'groupMembershipLookupFailed'
        correlationId = $correlationId
    }
    return
}

try {
    if ($hasDeviceId) {
        $registeredDevice = Invoke-RestMethod `
            -Method Get `
            -Uri "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$deviceId" `
            -Authentication Bearer `
            -Token $graphToken `
            -ErrorAction Stop
    }
    else {
        $matchingDevices = @(
            Get-AutopilotDevices -AccessToken $graphToken |
            Where-Object {
                [string]::Equals(
                    [string] $_.serialNumber,
                    $serialNumber,
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
        )
        if ($matchingDevices.Count -eq 0) {
            Send-JsonResponse -StatusCode NotFound -Body @{
                error         = 'deviceNotFound'
                correlationId = $correlationId
            }
            return
        }
        if ($matchingDevices.Count -gt 1) {
            throw "Serial number '$serialNumber' identifies multiple Autopilot devices."
        }
        $registeredDevice = $matchingDevices[0]
    }
}
catch {
    Write-Error "[$correlationId] Autopilot device lookup failed: $($_.Exception.Message)"
    Send-JsonResponse -StatusCode BadGateway -Body @{
        error         = 'deviceLookupFailed'
        correlationId = $correlationId
    }
    return
}

if ([string]::Equals(
        [string] $registeredDevice.enrollmentState,
        'enrolled',
        [StringComparison]::OrdinalIgnoreCase)) {
    Send-JsonResponse -StatusCode Conflict -Body @{
        error         = 'deviceAlreadyEnrolled'
        deviceId      = $registeredDevice.id
        serialNumber  = $registeredDevice.serialNumber
        correlationId = $correlationId
    }
    return
}

$previousGroupTag = [string] $registeredDevice.groupTag
if ([string]::Equals(
        $previousGroupTag,
        $groupTag,
        [StringComparison]::Ordinal)) {
    Send-JsonResponse -StatusCode OK -Body @{
        deviceId             = $registeredDevice.id
        serialNumber         = $registeredDevice.serialNumber
        previousGroupTag     = $previousGroupTag
        groupTag             = $groupTag
        enrollmentState      = $registeredDevice.enrollmentState
        changed              = $false
        postProcessingStatus = 'notRequired'
        correlationId        = $correlationId
    }
    return
}

$previousAdministrativeUnitNames = @(
    Get-AdministrativeUnitNamesForGroupTag `
        -Policy $policy `
        -GroupTag $previousGroupTag
)
$configuredAdministrativeUnitNames = @($policy | Where-Object {
    $_.PSObject.Properties['administrativeUnitName'] -and
    -not [string]::IsNullOrWhiteSpace(
        [string] $_.administrativeUnitName)
} | ForEach-Object {
    ([string] $_.administrativeUnitName).Trim()
} | Sort-Object -Unique)

if ($configuredAdministrativeUnitNames.Count -gt 0) {
    try {
        $entraDeviceId = [guid]::Empty
        if ([guid]::TryParse(
                [string] $registeredDevice.azureActiveDirectoryDeviceId,
                [ref] $entraDeviceId)) {
            $entraDevice = Invoke-RestMethod `
                -Method Get `
                -Uri "https://graph.microsoft.com/v1.0/devices(deviceId='$entraDeviceId')?`$select=id" `
                -Authentication Bearer `
                -Token $graphToken `
                -ErrorAction Stop
            $deviceObjectId = [guid]::Empty
            if (-not [guid]::TryParse(
                    [string] $entraDevice.id,
                    [ref] $deviceObjectId)) {
                throw "Entra device object ID is unavailable for device '$entraDeviceId'."
            }

            foreach (
                $configuredAdministrativeUnitName in
                $configuredAdministrativeUnitNames) {
                $administrativeUnit = Resolve-EntraAdministrativeUnit `
                    -AdministrativeUnitName `
                        $configuredAdministrativeUnitName `
                    -AccessToken $graphToken
                if (-not [bool] $administrativeUnit.isMemberManagementRestricted) {
                    continue
                }
                $membership = Add-EntraDeviceToAdministrativeUnit `
                    -AdministrativeUnitName `
                        $configuredAdministrativeUnitName `
                    -DeviceObjectId $deviceObjectId `
                    -AccessToken $graphToken `
                    -TestOnly
                if ($membership.IsMember) {
                    Send-JsonResponse -StatusCode Conflict -Body @{
                        error = 'restrictedAdministrativeUnitReassignmentNotSupported'
                        message = 'The device belongs to a restricted management administrative unit and cannot be reassigned because the service has no role scoped to that administrative unit.'
                        administrativeUnitName = `
                            $configuredAdministrativeUnitName
                        correlationId = $correlationId
                    }
                    return
                }
            }
        }
    }
    catch {
        Write-Error "[$correlationId] Restricted administrative unit preflight failed: $($_.Exception.Message)"
        Send-JsonResponse -StatusCode BadGateway -Body @{
            error         = 'deviceProtectionLookupFailed'
            correlationId = $correlationId
        }
        return
    }
}

$operationId = [guid]::NewGuid()
$operationAuditToken = $null
try {
    $operationAuditToken = Get-ImportAuditAccessToken
    Set-ImportAuditRecord `
        -ImportId $operationId `
        -PartitionKey reassignments `
        -Properties ([ordered]@{
            actorObjectId          = $actorObjectId
            actorUserPrincipalName = $actorUserPrincipalName
            requestReceivedAtUtc   = [datetime]::UtcNow.ToString('o')
            workflowStatus         = 'pending'
            status                 = 'queued'
            registrationId         = [string] $registeredDevice.id
            serialNumber           = [string] $registeredDevice.serialNumber
            previousGroupTag       = $previousGroupTag
            groupTag               = $groupTag
            correlationId          = $correlationId
        }) `
        -AccessToken $operationAuditToken
}
catch {
    Write-Error "[$correlationId] Reassignment tracking initialization failed: $($_.Exception.Message)"
    Send-JsonResponse -StatusCode BadGateway -Body @{
        error         = 'operationTrackingFailed'
        correlationId = $correlationId
    }
    return
}

try {
    Invoke-RestMethod `
        -Method Post `
        -Uri "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$($registeredDevice.id)/updateDeviceProperties" `
        -Authentication Bearer `
        -Token $graphToken `
        -ContentType 'application/json' `
        -Body (@{ groupTag = $groupTag } | ConvertTo-Json -Compress) `
        -ErrorAction Stop | Out-Null
}
catch {
    $groupTagUpdateError = $_
    try {
        Set-ImportAuditRecord `
            -ImportId $operationId `
            -PartitionKey reassignments `
            -Properties @{
                workflowStatus = 'error'
                status         = 'groupTagUpdateFailed'
                failureReason  = $groupTagUpdateError.Exception.Message
            } `
            -AccessToken $operationAuditToken
    }
    catch {
        Write-Warning "[$correlationId] Reassignment failure status could not be written: $($_.Exception.Message)"
    }
    Write-Error "[$correlationId] Group Tag update failed for Autopilot device '$($registeredDevice.id)': $($groupTagUpdateError.Exception.Message)"
    Send-JsonResponse -StatusCode BadGateway -Body @{
        error         = 'groupTagUpdateFailed'
        correlationId = $correlationId
    }
    return
}

Push-OutputBinding -Name DeviceAttributeUpdate -Value (@{
    operationId                     = $operationId
    registrationId                  = [string] $registeredDevice.id
    groupTag                        = $groupTag
    administrativeUnitName          = $administrativeUnitName
    previousAdministrativeUnitNames = $previousAdministrativeUnitNames
} | ConvertTo-Json -Depth 6 -Compress)

Write-Information "[$correlationId] Group Tag changed from '$previousGroupTag' to '$groupTag' for Autopilot device '$($registeredDevice.id)'."
Send-JsonResponse -StatusCode Accepted -Body @{
    operationId          = $operationId
    deviceId             = $registeredDevice.id
    serialNumber         = $registeredDevice.serialNumber
    previousGroupTag     = $previousGroupTag
    groupTag             = $groupTag
    enrollmentState      = $registeredDevice.enrollmentState
    changed              = $true
    postProcessingStatus = 'queued'
    correlationId        = $correlationId
}
