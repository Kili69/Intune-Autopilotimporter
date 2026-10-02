# Project-Version: 1.3.20261002.2
# Author: andreas.lucas@microsoft.com (aka Kili)

using namespace System.Net

param($Request, $TriggerMetadata, $TagPolicyBlob)

$modulePath = Join-Path $PSScriptRoot '..\src\AutopilotImport\AutopilotImport.psm1'
Import-Module $modulePath -Force

$versionMatch = [regex]::Match(
    ((Get-Content -LiteralPath $PSCommandPath -TotalCount 2) -join "`n"),
    '(?m)^# Project-Version:\s*(\S+)\s*$'
)
$functionVersion = if ($versionMatch.Success) {
    $versionMatch.Groups[1].Value
}
else {
    'unknown'
}
$correlationId = [guid]::NewGuid().ToString()
$responseHeaders = @{
    'Content-Type'              = 'application/json'
    'X-AutopilotImport-Version' = $functionVersion
    'X-Correlation-Id'          = $correlationId
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

function Get-SubmittedTagPolicyRules {
    param(
        [AllowNull()]
        [object] $Body
    )

    if ($null -eq $Body) {
        return
    }
    if ($Body -is [Collections.IDictionary]) {
        if ($Body.Contains('policy')) {
            return $Body['policy']
        }
        if ($Body.Contains('rules')) {
            return $Body['rules']
        }
        return
    }
    if ($Body.PSObject.Properties['policy']) {
        return $Body.policy
    }
    if ($Body.PSObject.Properties['rules']) {
        return $Body.rules
    }
}

function ConvertTo-SubmittedTagPolicy {
    param(
        [Parameter(Mandatory)]
        [object[]] $Rules
    )

    $policy = ConvertTo-TagAuthorizationPolicy -Rules $Rules
    foreach ($rule in $policy) {
        $rule
    }
}

function Assert-SubmittedAdministrativeUnitsExist {
    param(
        [Parameter(Mandatory)]
        [object[]] $Policy,

        [Parameter(Mandatory)]
        [Security.SecureString] $AccessToken
    )

    $administrativeUnitNames = @($Policy | ForEach-Object {
        if ($_.PSObject.Properties[
                'administrativeUnitName'] -and
            -not [string]::IsNullOrWhiteSpace(
                [string] $_.administrativeUnitName)) {
            ([string] $_.administrativeUnitName).Trim()
        }
    } | Sort-Object -Unique)

    foreach ($administrativeUnitName in $administrativeUnitNames) {
        Resolve-EntraAdministrativeUnit `
            -AdministrativeUnitName $administrativeUnitName `
            -AccessToken $AccessToken | Out-Null
    }
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
        policy          = $currentPolicy
        functionVersion = $functionVersion
        correlationId   = $correlationId
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
    $submittedRules = @(Get-SubmittedTagPolicyRules -Body $requestBody)
    $updatedPolicy = @(ConvertTo-SubmittedTagPolicy -Rules $submittedRules)
    $configuredAdministrativeUnits = @($updatedPolicy | Where-Object {
        $_.PSObject.Properties[
            'administrativeUnitName'] -and
        -not [string]::IsNullOrWhiteSpace(
            [string] $_.administrativeUnitName)
    })
    if ($configuredAdministrativeUnits.Count -gt 0) {
        $tokenResult = Get-AzAccessToken `
            -ResourceUrl 'https://graph.microsoft.com/' `
            -ErrorAction Stop
        $graphToken = if ($tokenResult.Token -is [Security.SecureString]) {
            $tokenResult.Token
        }
        else {
            ConvertTo-SecureString ([string] $tokenResult.Token) `
                -AsPlainText `
                -Force
        }
        Assert-SubmittedAdministrativeUnitsExist `
            -Policy $updatedPolicy `
            -AccessToken $graphToken
    }
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
    policy          = $updatedPolicy
    functionVersion = $functionVersion
    correlationId   = $correlationId
}