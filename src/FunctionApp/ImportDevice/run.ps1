# Project-Version: 1.1.20260912.2
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
DISCLAIMER:
This sample script is not supported under any Microsoft standard support program or service.
The sample script is provided AS IS without warranty of any kind. Microsoft further disclaims
all implied warranties including, without limitation, any implied warranties of merchantability
or of fitness for a particular purpose. The entire risk arising out of the use or performance of
the sample scripts and documentation remains with you. In no event shall Microsoft, its authors,
or anyone else involved in the creation, production, or delivery of the scripts be liable for any
damages whatsoever (including, without limitation, damages for loss of business profits, business
interruption, loss of business information, or other pecuniary loss) arising out of the use of or
inability to use the sample scripts or documentation, even if Microsoft has been advised of the
possibility of such damages.
#>

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
    $tagAuthorizationPolicy = @($tagAuthorizationPolicyJson | ConvertFrom-Json)
    if ($tagAuthorizationPolicy.Count -eq 0) {
        throw 'Tag authorization policy is empty.'
    }
}
catch {
    try {
        $tagAuthorizationPolicy = @($env:TAG_AUTHORIZATION_POLICY | ConvertFrom-Json)
        if ($tagAuthorizationPolicy.Count -eq 0) {
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
        $tokenResult = Get-AzAccessToken `
            -ResourceUrl 'https://graph.microsoft.com/' `
            -ErrorAction Stop
        $accessToken = if ($tokenResult.Token -is [Security.SecureString]) {
            ConvertFrom-SecureString -SecureString $tokenResult.Token -AsPlainText
        }
        else {
            [string] $tokenResult.Token
        }
        $graphResponse = Invoke-RestMethod `
            -Method Get `
            -Uri "https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities/$parsedImportId" `
            -Authentication Bearer `
            -Token (ConvertTo-SecureString $accessToken -AsPlainText -Force) `
            -ErrorAction Stop
        $authorizedGroupTag = Resolve-AuthorizedGroupTag `
            -Principal $principal `
            -Policy $tagAuthorizationPolicy `
            -RequestedGroupTag ([string] $graphResponse.groupTag)

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

        if ($intuneStatus -eq 'complete') {
            try {
                $registrationId = Get-AutopilotDeviceRegistrationId `
                    -ImportedDevice $graphResponse
                $registeredDevice = Invoke-RestMethod `
                    -Method Get `
                    -Uri "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$registrationId" `
                    -Authentication Bearer `
                    -Token (ConvertTo-SecureString $accessToken -AsPlainText -Force) `
                    -ErrorAction Stop
                $parsedEntraDeviceId = [guid]::Empty
                if (-not [guid]::TryParse(
                        [string] $registeredDevice.azureActiveDirectoryDeviceId,
                        [ref] $parsedEntraDeviceId)) {
                    throw 'The Entra device is not available yet.'
                }
                $entraDeviceId = $parsedEntraDeviceId.ToString()
                $entraDevice = Invoke-RestMethod `
                    -Method Get `
                    -Uri "https://graph.microsoft.com/v1.0/devices(deviceId='$entraDeviceId')?`$select=deviceId,extensionAttributes" `
                    -Authentication Bearer `
                    -Token (ConvertTo-SecureString $accessToken -AsPlainText -Force) `
                    -ErrorAction Stop
                $extensionProperty = $entraDevice.extensionAttributes.PSObject.Properties[
                    $extensionAttribute
                ]
                if ($extensionProperty) {
                    $extensionAttributeValue = [string] $extensionProperty.Value
                }
                if ($extensionAttributeValue -ceq $authorizedGroupTag) {
                    $extensionAttributeStatus = 'complete'
                }
            }
            catch {
                Write-Information "[$correlationId] Extension attribute status is still pending for import '$parsedImportId': $($_.Exception.Message)"
            }
        }
    }
    catch [System.UnauthorizedAccessException] {
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

    $workflowStatus = if ($intuneStatus -eq 'error') {
        'error'
    }
    elseif ($intuneStatus -eq 'complete' -and
        $extensionAttributeStatus -eq 'complete') {
        'complete'
    }
    else {
        'pending'
    }
    Send-JsonResponse -StatusCode OK -Body @{
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
        entraDeviceId           = $entraDeviceId
        correlationId           = $correlationId
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

    $groupTag = Resolve-AuthorizedGroupTag `
        -Principal $principal `
        -Policy $tagAuthorizationPolicy `
        -RequestedGroupTag ([string] $requestBody.groupTag)
    $restrictedManagementAdministrativeUnitName = `
        Resolve-RestrictedManagementAdministrativeUnitName `
            -Policy $tagAuthorizationPolicy `
            -GroupTag $groupTag
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
    $graphPayload = ConvertTo-AutopilotImportPayload `
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

$actorId = @($principal.claims | Where-Object {
    $_.typ -in @('oid', 'http://schemas.microsoft.com/identity/claims/objectidentifier')
} | Select-Object -First 1).val

try {
    $tokenResult = Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com/' -ErrorAction Stop
    $accessToken = if ($tokenResult.Token -is [Security.SecureString]) {
        ConvertFrom-SecureString -SecureString $tokenResult.Token -AsPlainText
    }
    else {
        [string] $tokenResult.Token
    }

    $graphResponse = Invoke-RestMethod `
        -Method Post `
        -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities' `
        -Authentication Bearer `
        -Token (ConvertTo-SecureString $accessToken -AsPlainText -Force) `
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

Write-Information "[$correlationId] Autopilot import '$($graphResponse.id)' created for serial '$($graphPayload.serialNumber)' by '$actorId'."
Push-OutputBinding -Name DeviceAttributeUpdate -Value (@{
    importId = [string] $graphResponse.id
    groupTag = $groupTag
    restrictedManagementAdministrativeUnitName = `
        $restrictedManagementAdministrativeUnitName
} | ConvertTo-Json -Compress)
Send-JsonResponse -StatusCode Accepted -Body @{
    importId      = $graphResponse.id
    serialNumber  = $graphResponse.serialNumber
    groupTag      = $graphResponse.groupTag
    status        = $graphResponse.state.deviceImportStatus
    correlationId = $correlationId
}