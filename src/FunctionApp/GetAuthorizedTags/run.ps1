# Project-Version: 1.4.20261020.13
# Author: andreas.lucas@outlook.com (aka Kili)

<#
.SYNOPSIS
Returns the Group Tags and named policies currently authorized for the caller.

.DESCRIPTION
Azure Functions HTTP entry point for GET /api/devices/tags. The HTTP trigger
uses authLevel anonymous because App Service Authentication (Easy Auth)
authenticates requests before they reach the worker. This script trusts the
x-ms-client-principal header supplied by Easy Auth; it does not validate a
bearer token itself. Request bodies and query parameters are not used.

The shared AutopilotImport module decodes the Base64-encoded UTF-8 principal
and converts the TagPolicyBlob input binding to JSON text. A nonblank blob
value takes precedence over TAG_AUTHORIZATION_POLICY. The environment setting
is used only when the binding content is blank, not when blob JSON is invalid.
The resulting policy must contain at least one rule. Rules associate an Entra
groupId with tags and may include a display name and other policy metadata.

The Function obtains a Microsoft Graph application token through the current
Az context. Both SecureString and plain-text token results are supported;
plain-text results are converted to SecureString before use. In Azure, the
worker profile establishes this context using the Function's managed identity.

Get-CurrentPolicyPrincipal checks the caller's current membership in the
configured policy groups through Microsoft Graph
POST /v1.0/users/{objectId}/checkMemberGroups, in batches of up to 20 group IDs.
It replaces token group claims with the current matching memberships while
retaining other principal claims. Authorization therefore does not rely on
potentially stale group claims in the incoming token.

The response contains two complementary views of matching policy rules:
- tags: the combined allowed tags, with blank values removed, surrounding
  whitespace trimmed, and duplicates removed; values are sorted by tag name.
- policies: one name/tags object per matching rule, in policy order. A missing
  name property produces "Policy <groupId>". Each rule's tags are returned
  as configured, without the normalization applied to the combined tags list.
  Group IDs, administrative-unit bindings and other rule properties are not
  included in these policy objects.

An authenticated caller without a matching policy receives HTTP 200 with empty
tags and policies arrays, not HTTP 403. This endpoint is read-only: it does not
import devices, change policies or modify group memberships.

.PARAMETER Request
HTTP trigger input supplied by the Functions worker. Headers must contain the
trusted x-ms-client-principal value injected by Easy Auth, including claims
with a valid Entra user object ID (oid or its fully qualified claim type).

.PARAMETER TriggerMetadata
Trigger metadata supplied by the Functions worker. Accepted for the standard
Function entry-point signature but not read by this implementation.

.PARAMETER TagPolicyBlob
Blob input binding for configuration/tag-authorization-policy.json, using the
AzureWebJobsStorage connection. The binding declares string data; the shared
converter also supports bytes, streams and worker content wrappers.

.INPUTS
Azure Functions HTTP request, trigger metadata and blob binding data. This
entry point is invoked by the Functions host, not through pipeline input.

.OUTPUTS
An HttpResponseContext written to the Response output binding. The body is
compressed JSON (serialization depth 6). Every response produced by this
script includes Content-Type application/json, Cache-Control no-store, and an
X-Correlation-Id header whose GUID is repeated in the JSON correlationId field.

HTTP 200: { "tags": [...], "policies": [{ "name": "...", "tags": [...] }],
            "correlationId": "..." }
HTTP 401: { "error": "authenticationRequired", "correlationId": "..." }
          Returned when the client-principal header is missing or blank.
HTTP 401: { "error": "invalidPrincipal", "correlationId": "..." }
          Returned for any ArgumentException raised inside the lookup block,
          including invalid principal encoding/claims, a missing or invalid
          caller object ID, or an invalid policy group ID.
HTTP 500: { "error": "serviceNotConfigured", "correlationId": "..." }
          Returned for other exceptions inside the lookup block, such as
          policy parsing, token acquisition or Graph failures.

.EXAMPLE
$headers = @{ Authorization = "Bearer $accessToken" }
Invoke-RestMethod -Method Get `
    -Uri 'https://<function-app>.azurewebsites.net/api/devices/tags' `
    -Headers $headers

Calls the deployed endpoint with a user access token accepted by Easy Auth.
For a caller authorized by one policy, a response can look like:
{
  "tags": ["BG-Default", "BG-VIP"],
  "policies": [
    { "name": "Standard devices", "tags": ["BG-Default", "BG-VIP"] }
  ],
  "correlationId": "11111111-1111-1111-1111-111111111111"
}

.NOTES
Requires the sibling shared AutopilotImport module, Az.Accounts token support,
the Functions Response output binding, a readable policy blob or configured
TAG_AUTHORIZATION_POLICY fallback, and Microsoft Graph application permissions
for the current policy-membership lookup. Function bindings and the HTTP route
are defined in function.json; host.json sets an empty HTTP route prefix.

The managed identity is used for Graph access, not the caller's delegated
Graph token. Keep Easy Auth enabled and protect the principal-header trust
boundary; authLevel anonymous does not provide authentication by itself.

Unexpected lookup errors are logged with the correlation ID and exception
message; the HTTP body does not expose exception details. Missing headers and
ArgumentException responses are not logged here. Module import occurs before
the lookup try/catch, so module-loading failures are handled by the host rather
than by this script's JSON error mapping. Binding failures may likewise occur
before invocation. Easy Auth can reject requests before this script executes.
#>

using namespace System.Net

param($Request, $TriggerMetadata, $TagPolicyBlob)

$modulePath = Join-Path $PSScriptRoot '..\src\AutopilotImport\AutopilotImport.psm1'
Import-Module $modulePath -Force

# Use the same ID in HTTP responses and error logs to trace one invocation.
# Authorization results must not be reused from a browser or proxy cache.
$correlationId = [guid]::NewGuid().ToString()
$responseHeaders = @{
    'Content-Type'     = 'application/json'
    'X-Correlation-Id' = $correlationId
    'Cache-Control'    = 'no-store'
}

function Send-JsonResponse {
    <#
    .SYNOPSIS
    Writes one JSON HTTP response to the Function's Response output binding.

    .DESCRIPTION
    Serializes Body with ConvertTo-Json at depth 6 in compressed form and
    combines it with StatusCode and the invocation's script-scoped
    responseHeaders. The caller supplies the correlationId in Body; this helper
    does not add it automatically. It does not end script execution, so error
    branches must return after calling it to avoid further processing.

    .PARAMETER StatusCode
    HTTP status code for the response, such as OK, Unauthorized or
    InternalServerError.

    .PARAMETER Body
    Response payload to serialize. Success and error callers provide their
    respective response envelopes.

    .OUTPUTS
    An HttpResponseContext sent through Push-OutputBinding, not returned as a
    pipeline object.
    #>
    param(
        [Parameter(Mandatory)]
        [HttpStatusCode] $StatusCode,

        [Parameter(Mandatory)]
        [object] $Body
    )

    # The Functions host sends the response from this binding; returning a
    # PowerShell object alone would not create the HTTP response.
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $StatusCode
        Headers    = $responseHeaders
        Body       = ($Body | ConvertTo-Json -Depth 6 -Compress)
    })
}

# Easy Auth validates the user token upstream and supplies this trusted header.
# Do not accept a caller-supplied principal as a substitute for Easy Auth.
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
    # Prefer the centrally stored policy. Only absent/blank binding content
    # permits the environment fallback; invalid blob JSON must fail visibly.
    $policyJson = ConvertFrom-BlobBindingContent -Value $TagPolicyBlob
    if ([string]::IsNullOrWhiteSpace($policyJson)) {
        $policyJson = $env:TAG_AUTHORIZATION_POLICY
    }
    # An explicit empty array is valid before the first rule is configured.
    if ([string]::IsNullOrWhiteSpace($policyJson)) {
        throw 'Tag authorization policy is missing.'
    }
    $policy = ConvertTo-TagAuthorizationPolicy -Rules @($policyJson | ConvertFrom-Json -ErrorAction Stop) -AllowEmpty
    # Use the Function's Azure identity for Graph, not the user's API token.
    $tokenResult = Get-AzAccessToken `
        -ResourceUrl 'https://graph.microsoft.com/' `
        -ErrorAction Stop
    # Az.Accounts versions expose different token types; the shared Graph
    # helper requires SecureString in both cases.
    $graphToken = if ($tokenResult.Token -is [Security.SecureString]) {
        $tokenResult.Token
    }
    else {
        ConvertTo-SecureString ([string] $tokenResult.Token) -AsPlainText -Force
    }
    # Replace potentially stale token group claims with current Graph
    # memberships, limited to groups referenced by the policy.
    $principal = Get-CurrentPolicyPrincipal `
        -Principal $principal `
        -Policy $policy `
        -AccessToken $graphToken
    $tags = @(Get-AuthorizedGroupTags -Principal $principal -Policy $policy)
    # Read the refreshed principal, accepting both supported group-claim names.
    $callerGroups = @($principal.claims | Where-Object {
        $_.typ -in 'groups', 'http://schemas.microsoft.com/ws/2008/06/identity/claims/groups'
    } | ForEach-Object { [string] $_.val })
    # Keep matching rules separate for policy selection in the frontend.
    # Unlike the combined tag list, these per-rule tags remain unnormalized.
    $namedPolicies = @($policy | Where-Object { $_.groupId -in $callerGroups } | ForEach-Object {
        [pscustomobject]@{
            # Older rules may lack a name; retain a stable label for them.
            name = if ($_.PSObject.Properties['name']) { [string] $_.name } else { "Policy $($_.groupId)" }
            tags = @($_.tags)
        }
    })
}
catch [System.ArgumentException] {
    # This mapping also covers invalid policy group IDs raised by the shared
    # membership helper, not only malformed caller claims.
    Send-JsonResponse -StatusCode Unauthorized -Body @{
        error         = 'invalidPrincipal'
        correlationId = $correlationId
    }
    return
}
catch {
    # Keep diagnostic details in the server log; expose only a generic error
    # and its correlation ID to the caller.
    Write-Error "[$correlationId] Authorized tag lookup failed: $($_.Exception.Message)"
    Send-JsonResponse -StatusCode InternalServerError -Body @{
        error         = 'serviceNotConfigured'
        correlationId = $correlationId
    }
    return
}

# No matching memberships is a successful lookup with empty arrays, not a
# forbidden request. Array wrappers above keep zero/one/many results consistent.
Send-JsonResponse -StatusCode OK -Body @{
    tags          = $tags
    policies      = $namedPolicies
    correlationId = $correlationId
}
