# Project-Version: 1.0.20260831.1
# Author: andreas.lucas@microsoft.com (aka Kili)

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

function Test-IntuneRoleAdministrator {
    param(
        [Parameter(Mandatory)]
        [object] $Principal
    )

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

    $roleAssignments = @()
    $requestUri = "https://graph.microsoft.com/v1.0/deviceManagement/roleAssignments?`$expand=roleDefinition(`$select=id,displayName)&`$select=id,members"
    while ($requestUri) {
        $assignmentResponse = Invoke-RestMethod `
            -Method Get `
            -Uri $requestUri `
            -Headers $headers
        $roleAssignments += @($assignmentResponse.value)
        $requestUri = if ($assignmentResponse.PSObject.Properties.Name -contains '@odata.nextLink') {
            [string] $assignmentResponse.'@odata.nextLink'
        }
        else {
            $null
        }
    }

    return Test-IntuneRoleAdministratorAssignment `
        -Principal $Principal `
        -RoleAssignment $roleAssignments
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
        throw [System.UnauthorizedAccessException]::new('Authentication is required.')
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
        error         = 'tagPolicyManagementForbidden'
        correlationId = $correlationId
    }
    return
}

$currentPolicyJson = ConvertFrom-BlobBindingContent -Value $TagPolicyBlob
if ([string]::IsNullOrWhiteSpace($currentPolicyJson)) {
    $currentPolicyJson = $env:TAG_AUTHORIZATION_POLICY
}

if ($Request.Method -ieq 'GET') {
    try {
        $currentPolicy = @($currentPolicyJson | ConvertFrom-Json)
    }
    catch {
        Send-JsonResponse -StatusCode InternalServerError -Body @{
            error         = 'tagPolicyInvalid'
            correlationId = $correlationId
        }
        return
    }
    Send-JsonResponse -StatusCode OK -Body @{
        policy        = $currentPolicy
        correlationId = $correlationId
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
    $updatedPolicy = @(ConvertTo-TagAuthorizationPolicy `
        -Rules @($requestBody.rules) `
        -RestrictedManagementAdministrativeUnitName `
            ([string] $requestBody.restrictedManagementAdministrativeUnitName))
    $updatedPolicyJson = $updatedPolicy | ConvertTo-Json -Depth 4 -Compress
}
catch {
    Send-JsonResponse -StatusCode BadRequest -Body @{
        error         = 'invalidTagPolicy'
        message       = $_.Exception.Message
        correlationId = $correlationId
    }
    return
}

Push-OutputBinding -Name UpdatedTagPolicyBlob -Value $updatedPolicyJson
Send-JsonResponse -StatusCode OK -Body @{
    policy        = $updatedPolicy
    correlationId = $correlationId
}