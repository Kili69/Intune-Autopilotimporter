# Project-Version: 1.3.20261006.5
# Author: andreas.lucas@outlook.com (aka Kili)

<#
.SYNOPSIS
Reads or replaces the Autopilot Group Tag authorization policy.

.DESCRIPTION
Implements the GET and PUT operations for /api/management/tag-policy. The
function requires an authenticated Microsoft Entra principal that is authorized
by MANAGER_AUTHORIZATION_POLICY or, when enabled by that policy, has the Intune
Role Administrator role.

GET returns the complete normalized policy. PUT accepts the replacement rules
in either a top-level "policy" or "rules" property, normalizes and validates the
rules, verifies referenced administrative units through Microsoft Graph, and
writes the resulting JSON to configuration/tag-authorization-policy.json.

The current policy is read from the blob input binding. If the blob is empty,
TAG_AUTHORIZATION_POLICY is used as the fallback for reads. Responses include
the function version and a correlation ID for diagnostics. Errors are returned
as JSON with an HTTP status appropriate to authentication, authorization,
configuration, validation, or dependency failures.

.PARAMETER Request
Azure Functions HTTP request. Supported methods are GET and PUT. PUT request
bodies must contain the complete replacement policy in a "policy" or "rules"
property.

.PARAMETER TriggerMetadata
Metadata supplied by the Azure Functions PowerShell worker. The function does
not currently read this value directly.

.PARAMETER TagPolicyBlob
String content supplied by the input blob binding for
configuration/tag-authorization-policy.json.

.OUTPUTS
Writes an HTTP response to the Response output binding. Successful responses
contain "policy", "functionVersion", and "correlationId". A successful PUT also
writes the normalized policy JSON to the UpdatedTagPolicyBlob output binding.

.NOTES
The HTTP trigger uses anonymous function-level authentication because Microsoft
Entra authentication is enforced by the Function App authentication platform.
Manager authorization is additionally enforced in this function.
#>

using namespace System.Net

param($Request, $TriggerMetadata, $TagPolicyBlob)

$modulePath = Join-Path $PSScriptRoot '..\src\AutopilotImport\AutopilotImport.psm1'
Import-Module $modulePath -Force

# Keep the runtime response version aligned with the version embedded during
# packaging without maintaining a second version value in this function.
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

<#
.SYNOPSIS
Writes a JSON response to the Azure Functions HTTP output binding.

.DESCRIPTION
Serializes the supplied body as compact JSON and combines it with the shared
version and correlation headers for the current request.

.PARAMETER StatusCode
HTTP status code returned to the caller.

.PARAMETER Body
Object serialized as the JSON response body.

.OUTPUTS
None. The function writes an HttpResponseContext to the Response output binding.
#>
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

<#
.SYNOPSIS
Extracts policy rules from a submitted request body.

.DESCRIPTION
Accepts request bodies parsed as either an IDictionary or a PSCustomObject and
returns the value of the "policy" property. The legacy-compatible "rules"
property is used when "policy" is absent.

.PARAMETER Body
Parsed PUT request body. A null body or a body without a supported property
produces no output and is rejected later by policy validation.

.OUTPUTS
System.Object. Returns the submitted rule collection when present.
#>
function Get-SubmittedTagPolicyRules {
    param(
        [AllowNull()]
        [object] $Body
    )

    if ($null -eq $Body) {
        return
    }
    # Azure Functions can provide the JSON body as either a hashtable or a
    # PSCustomObject, depending on the worker and how the request was parsed.
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

<#
.SYNOPSIS
Validates and normalizes submitted Group Tag policy rules.

.DESCRIPTION
Passes the complete submitted rule collection to the shared policy converter
and emits each normalized rule. The converter enforces the canonical policy
schema used by the importer.

.PARAMETER Rules
Complete collection of policy rules supplied by the PUT request.

.OUTPUTS
System.Object. Emits the normalized policy rules.

.NOTES
Validation exceptions from ConvertTo-TagAuthorizationPolicy are intentionally
allowed to propagate to the request-level error handler.
#>
function ConvertTo-SubmittedTagPolicy {
    param(
        [Parameter(Mandatory)]
        [object[]] $Rules
    )

    # The shared converter validates rule structure and produces the canonical
    # representation used by all policy consumers.
    $policy = ConvertTo-TagAuthorizationPolicy -Rules $Rules
    foreach ($rule in $policy) {
        $rule
    }
}

<#
.SYNOPSIS
Verifies administrative units referenced by a submitted policy.

.DESCRIPTION
Collects distinct, non-empty administrative-unit names and resolves each one
through Microsoft Graph. This prevents a policy containing missing or ambiguous
administrative units from being persisted.

.PARAMETER Policy
Normalized replacement policy to validate.

.PARAMETER AccessToken
Microsoft Graph access token obtained by the Function App managed identity.

.OUTPUTS
None.

.NOTES
Resolution errors are intentionally allowed to propagate so the complete PUT
request fails before the blob output binding is written.
#>
function Assert-SubmittedAdministrativeUnitsExist {
    param(
        [Parameter(Mandatory)]
        [object[]] $Policy,

        [Parameter(Mandatory)]
        [Security.SecureString] $AccessToken
    )

    # Resolve each distinct name once so invalid or ambiguous administrative
    # units reject the complete update before anything is persisted.
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
    # App Service Authentication validates the token and forwards the decoded
    # principal in this trusted platform header.
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

# Intune Role Administrator lookup is an optional authorization path because it
# depends on Intune RBAC being reachable at request time.
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
    # Preserve the deployment-provided policy until the first successful PUT
    # creates the persistent blob.
    $currentPolicyJson = $env:TAG_AUTHORIZATION_POLICY
}

# GET is read-only and returns the policy exactly as stored or deployed.
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
    # PUT replaces the whole policy rather than merging individual rules.
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
        # Az.Accounts versions differ in whether Token is already a
        # SecureString; downstream Graph helpers consistently require one.
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

# Bind the blob only after the complete policy and all external references have
# passed validation, preventing partial or unusable configuration updates.
Push-OutputBinding -Name UpdatedTagPolicyBlob -Value $updatedPolicyJson
Send-JsonResponse -StatusCode OK -Body @{
    policy          = $updatedPolicy
    functionVersion = $functionVersion
    correlationId   = $correlationId
}