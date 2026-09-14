# Project-Version: 1.1.20260914.1
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
.SYNOPSIS
Returns recent Autopilot import operations to an authorized manager.

.DESCRIPTION
Validates the Easy Auth principal against the configured manager policy and
returns imported Windows Autopilot device identities from Microsoft Graph.
Sensitive import payload fields such as hardware identifiers and product keys
are not returned.
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

$managerPolicyJson = $env:MANAGER_AUTHORIZATION_POLICY
if ([string]::IsNullOrWhiteSpace($managerPolicyJson)) {
    Send-JsonResponse -StatusCode InternalServerError -Body @{
        error         = 'serviceNotConfigured'
        correlationId = $correlationId
    }
    return
}

try {
    $managerPolicy = $managerPolicyJson | ConvertFrom-Json
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

$isManager = Test-TagPolicyManagerPrincipal `
    -Principal $principal `
    -ManagerPolicy $managerPolicy
if (-not $isManager -and $managerPolicy.allowIntuneRoleAdministrators) {
    try {
        $isManager = Test-IntuneRoleAdministrator -Principal $principal
    }
    catch {
        Write-Error "[$correlationId] Intune RBAC lookup failed: $($_.Exception.Message)"
        Send-JsonResponse -StatusCode ServiceUnavailable -Body @{
            error         = 'authorizationServiceUnavailable'
            correlationId = $correlationId
        }
        return
    }
}
if (-not $isManager) {
    Send-JsonResponse -StatusCode Forbidden -Body @{
        error         = 'importHistoryForbidden'
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
    $tokenResult = Get-AzAccessToken `
        -ResourceUrl 'https://graph.microsoft.com/' `
        -ErrorAction Stop
    $accessToken = if ($tokenResult.Token -is [Security.SecureString]) {
        ConvertFrom-SecureString -SecureString $tokenResult.Token -AsPlainText
    }
    else {
        [string] $tokenResult.Token
    }
    $headers = @{ Authorization = "Bearer $accessToken" }
    $imports = [Collections.Generic.List[object]]::new()
    $requestUri = 'https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities?$select=id,importId,serialNumber,groupTag,state&$top=100'

    while ($requestUri -and $imports.Count -lt $top) {
        $graphResponse = Invoke-RestMethod `
            -Method Get `
            -Uri $requestUri `
            -Headers $headers `
            -ErrorAction Stop
        foreach ($importedDevice in @($graphResponse.value)) {
            if ($imports.Count -ge $top) {
                break
            }
            $imports.Add([pscustomobject][ordered]@{
                importId        = [string] $importedDevice.id
                batchImportId   = [string] $importedDevice.importId
                serialNumber    = [string] $importedDevice.serialNumber
                groupTag        = [string] $importedDevice.groupTag
                status          = [string] $importedDevice.state.deviceImportStatus
                deviceErrorCode = $importedDevice.state.deviceErrorCode
                deviceErrorName = [string] $importedDevice.state.deviceErrorName
            })
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
    Write-Error "[$correlationId] Import history lookup failed: $($_.Exception.Message)"
    Send-JsonResponse -StatusCode BadGateway -Body @{
        error         = 'importHistoryLookupFailed'
        correlationId = $correlationId
    }
    return
}

Send-JsonResponse -StatusCode OK -Body @{
    imports       = @($imports)
    count         = $imports.Count
    correlationId = $correlationId
}
