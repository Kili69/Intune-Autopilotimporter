# Project-Version: 1.1.20260921.2
# Author: andreas.lucas@microsoft.com (aka Kili)

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
        Body       = ($Body | ConvertTo-Json -Depth 6 -Compress)
    })
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
    $tags = @(Get-AuthorizedGroupTags -Principal $principal -Policy $policy)
}
catch [System.ArgumentException] {
    Send-JsonResponse -StatusCode Unauthorized -Body @{
        error         = 'invalidPrincipal'
        correlationId = $correlationId
    }
    return
}
catch {
    Write-Error "[$correlationId] Authorized tag lookup failed: $($_.Exception.Message)"
    Send-JsonResponse -StatusCode InternalServerError -Body @{
        error         = 'serviceNotConfigured'
        correlationId = $correlationId
    }
    return
}

Send-JsonResponse -StatusCode OK -Body @{
    tags          = $tags
    correlationId = $correlationId
}
