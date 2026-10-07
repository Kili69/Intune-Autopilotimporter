# Project-Version: 1.3.20261007.3
# Author: andreas.lucas@outlook.com (aka Kili)

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
        Body       = ($Body | ConvertTo-Json -Depth 10 -Compress)
    })
}

function Get-ActorClaim {
    param(
        [Parameter(Mandatory)]
        [object] $Principal,

        [Parameter(Mandatory)]
        [string[]] $ClaimType
    )

    return [string] (@($Principal.claims | Where-Object {
        $_.typ -in $ClaimType
    } | Select-Object -First 1).val)
}

function Get-GraphCollection {
    param(
        [Parameter(Mandatory)]
        [string] $Uri,

        [Parameter(Mandatory)]
        [Security.SecureString] $AccessToken
    )

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
    $principalHeader = $Request.Headers['x-ms-client-principal']
    if ([string]::IsNullOrWhiteSpace($principalHeader)) {
        throw [UnauthorizedAccessException]::new('Authentication is required.')
    }
    $principal = ConvertFrom-ClientPrincipalHeader -HeaderValue $principalHeader
    $policyJson = ConvertFrom-BlobBindingContent -Value $TagPolicyBlob
    if ([string]::IsNullOrWhiteSpace($policyJson)) {
        $policyJson = $env:TAG_AUTHORIZATION_POLICY
    }
    $policy = @($policyJson | ConvertFrom-Json)
    if ($policy.Count -eq 0) {
        throw 'Tag authorization policy is empty.'
    }
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
    Write-Error "[$correlationId] Device Tag management initialization failed: $($_.Exception.Message)"
    Send-JsonResponse -StatusCode InternalServerError -Body @{
        error         = 'serviceNotConfigured'
        correlationId = $correlationId
    }
    return
}

$actorObjectId = Get-ActorClaim `
    -Principal $principal `
    -ClaimType @(
        'oid'
        'http://schemas.microsoft.com/identity/claims/objectidentifier'
    )

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
        if (-not $record -or
            [string] $record.operationType -ne 'tagChange') {
            Send-JsonResponse -StatusCode NotFound -Body @{
                error         = 'operationNotFound'
                correlationId = $correlationId
            }
            return
        }
        if ([string] $record.actorObjectId -ne $actorObjectId) {
            Send-JsonResponse -StatusCode Forbidden -Body @{
                error         = 'operationNotAllowed'
                correlationId = $correlationId
            }
            return
        }
        $workflowStatus = if (-not [string]::IsNullOrWhiteSpace(
                [string] $record.processingCompletedAtUtc)) {
            'complete'
        }
        else {
            'pending'
        }
        Send-JsonResponse -StatusCode OK -Body @{
            operationId   = $operationId
            serialNumber  = [string] $record.serialNumber
            groupTag      = [string] $record.groupTag
            status        = $workflowStatus
            workflowStatus = $workflowStatus
            correlationId = $correlationId
        }
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
        $autopilotDevices = @(Get-GraphCollection `
            -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?$top=100' `
            -AccessToken $graphToken)
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
                $entraDevice = Invoke-RestMethod `
                    -Method Get `
                    -Uri "https://graph.microsoft.com/v1.0/devices(deviceId='$entraDeviceId')?`$select=id" `
                    -Authentication Bearer `
                    -Token $graphToken `
                    -ErrorAction Stop
                $memberships = @(Get-GraphCollection `
                    -Uri "https://graph.microsoft.com/v1.0/devices/$($entraDevice.id)/memberOf?`$select=id,displayName" `
                    -AccessToken $graphToken)
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
            [pscustomobject][ordered]@{
                id                  = [string] $autopilotDevice.id
                serialNumber        = [string] $autopilotDevice.serialNumber
                groupTag            = [string] $autopilotDevice.groupTag
                groups              = $groups
                administrativeUnits = $administrativeUnits
            }
        } | Sort-Object serialNumber)
        Send-JsonResponse -StatusCode OK -Body @{
            devices       = $visibleDevices
            count         = $visibleDevices.Count
            correlationId = $correlationId
        }
    }
    catch {
        Write-Error "[$correlationId] Autopilot device lookup failed: $($_.Exception.Message)"
        Send-JsonResponse -StatusCode BadGateway -Body @{
            error         = 'deviceLookupFailed'
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
    $registeredDeviceId = [guid]::Empty
    if (-not [guid]::TryParse(
            [string] $requestBody.deviceId,
            [ref] $registeredDeviceId)) {
        throw [ArgumentException]::new('deviceId is invalid.')
    }
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
    if ([string] $device.enrollmentState -ine 'notContacted') {
        throw [InvalidOperationException]::new(
            'The device is no longer eligible for a Group Tag change.')
    }
    if ([string] $device.groupTag -ieq $groupTag) {
        throw [ArgumentException]::new(
            'The selected Group Tag is already assigned to the device.')
    }
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
    previousGroupTag          = [string] $device.groupTag
    groupTag                  = $groupTag
    administrativeUnitName    = [string] $administrativeUnitName
}
try {
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

Push-OutputBinding -Name DeviceAttributeUpdate -Value (@{
    operationId           = $operationId.ToString()
    registeredDeviceId    = $registeredDeviceId.ToString()
    groupTag              = $groupTag
    administrativeUnitName = $administrativeUnitName
    audit                 = $auditProperties
} | ConvertTo-Json -Depth 6 -Compress)
Send-JsonResponse -StatusCode Accepted -Body @{
    operationId   = $operationId
    serialNumber  = [string] $device.serialNumber
    groupTag      = $groupTag
    status        = 'queued'
    correlationId = $correlationId
}
