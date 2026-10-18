# Project-Version: 1.4.20261018.4
# Author: andreas.lucas@outlook.com (aka Kili)

<#
.SYNOPSIS
Serves the web frontend's static files and public runtime configuration.

.DESCRIPTION
HTTP entry point for GET /api/ui/{*path}. An empty path serves wwwroot/index.html.
The special path config returns the browser's authentication settings, API
URLs and deployed Function version. All other paths are resolved against the
local wwwroot directory; missing files and paths outside that directory return
404 rather than falling back to the application's index page.

Responses include content-security, referrer, MIME-sniffing, framing and browser
permission headers. auth.html uses a separate restrictive CSP that permits
same-origin framing for the silent authentication redirect. Other pages deny
framing. HTML and configuration responses use no-store; other static files use
a one-year public immutable cache policy.

.PARAMETER Request
Functions HTTP request object. Params.path contains the wildcard route path
relative to /api/ui/. Url supplies the origin for generated configuration URLs
when it is an absolute HTTPS URL. No body or query parameters are read.

.PARAMETER TriggerMetadata
Invocation metadata supplied by the worker. Not read by this implementation.

.INPUTS
None through the pipeline. The Functions host supplies the request parameters.

.OUTPUTS
HttpResponseContext written to the Response output binding.

HTTP 200: requested file as UTF-8 text or raw bytes, or JSON runtime config.
HTTP 404: JSON { "error": "notFound" } for a missing/out-of-root file.
HTTP 500: JSON { "error": "webClientNotConfigured" } when config is requested
and WEB_CLIENT_ID, API_AUDIENCE or TENANT_ID is blank.

.EXAMPLE
Invoke-RestMethod -Uri 'https://<function-app>.azurewebsites.net/api/ui/config'

Returns public client/tenant settings, scope, redirect/API URLs and the Function
version. No client secret or access token is included in this configuration.

.EXAMPLE
Invoke-WebRequest `
    -Uri 'https://<function-app>.azurewebsites.net/api/ui/index.html'

Retrieves the application entry page without browser caching.

.NOTES
function.json defines an anonymous GET trigger and the HTTP output binding.
The deployment allows public frontend access; the separate API endpoints
remain responsible for their own authentication and authorization.

Configuration requires WEB_CLIENT_ID, API_AUDIENCE and TENANT_ID. URLs use the
request's parsed HTTPS authority, preserving custom domains and ports; if it
cannot be used, HTTPS with WEBSITE_HOSTNAME is the fallback. The version is
read from the Project-Version marker in this script's first two lines, with
unknown returned when that marker does not match.

Recognized MIME types cover HTML, JavaScript, CSS, PNG, JPEG, WebP, SVG, ICO and
JSON. Unknown extensions use application/octet-stream. Every non-HTML file
receives immutable caching, not just content-hashed build assets.

Path containment is a lexical full-path/prefix check, not symbolic-link target
validation. Invalid filesystem paths and file-read/binding failures are not
caught here and may be handled by the Functions host.
#>

using namespace System.Net

param($Request, $TriggerMetadata)

# Read the deployed script's marker, not the frontend bundle version: these
# can differ when frontend assets have not changed between backend releases.
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

$requestedPath = [string] $Request.Params.path
# Keep browser capabilities and resource origins restricted on all responses,
# including configuration/errors, rather than relying on the HTML alone.
$securityHeaders = @{
    'Content-Security-Policy' = "default-src 'self'; connect-src 'self' https://login.microsoftonline.com; frame-src https://login.microsoftonline.com; img-src 'self' data:; style-src 'self'; script-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    'Referrer-Policy'         = 'no-referrer'
    'X-Content-Type-Options'  = 'nosniff'
    'X-Frame-Options'         = 'DENY'
    'Permissions-Policy'      = 'camera=(), microphone=(), geolocation=()'
}
if ($requestedPath -ieq 'auth.html') {
    # The silent-auth redirect must be frameable by this app's own origin.
    # Remove DENY, but still disallow scripts, forms and other resource loads.
    $securityHeaders['Content-Security-Policy'] = `
        "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'self'"
    $securityHeaders.Remove('X-Frame-Options')
}

function Send-Response {
    <#
    .SYNOPSIS
    Writes an HTTP response with the invocation's browser security headers.

    .DESCRIPTION
    Copies the script-scoped securityHeaders, adds the requested cache policy,
    and writes an HttpResponseContext through the Response output binding.
    Body is passed through unchanged; JSON serialization happens at call sites.

    .PARAMETER StatusCode
    System.Net.HttpStatusCode to send to the caller.

    .PARAMETER Body
    Text, JSON text or binary byte-array payload. No encoding/conversion is
    performed by this helper.

    .PARAMETER ContentType
    MIME type, including charset where appropriate.

    .PARAMETER CacheControl
    Cache-Control header. Defaults to public, max-age=3600; handler call sites
    explicitly select no-store or the long-lived static-file policy.

    .INPUTS
    None through the pipeline. Supply named parameters.

    .OUTPUTS
    HttpResponseContext sent to the worker's Response binding, not returned as
    a pipeline object.

    .EXAMPLE
    Send-Response -StatusCode NotFound -ContentType 'application/json' `
        -CacheControl 'no-store' -Body '{"error":"notFound"}'

    Sends a non-cacheable JSON error using the current security headers.

    .NOTES
    Requires the Functions worker binding command and the enclosing
    securityHeaders variable. Does not stop script execution; callers return
    separately when needed. Output-binding failures propagate.
    #>
    param(
        [Parameter(Mandatory)]
        [HttpStatusCode] $StatusCode,

        [Parameter(Mandatory)]
        [object] $Body,

        [Parameter(Mandatory)]
        [string] $ContentType,

        [string] $CacheControl = 'public, max-age=3600'
    )

    # Clone before adding response-specific caching so shared security headers
    # are not mutated by this helper.
    $headers = @{} + $securityHeaders
    $headers['Cache-Control'] = $CacheControl
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $StatusCode
        ContentType = $ContentType
        Headers    = $headers
        Body       = $Body
    })
}

if ($requestedPath -ieq 'config') {
    # These are public SPA identifiers, not secrets. Return a clear failure
    # instead of sending incomplete settings that would break browser sign-in.
    if ([string]::IsNullOrWhiteSpace($env:WEB_CLIENT_ID) -or
        [string]::IsNullOrWhiteSpace($env:API_AUDIENCE) -or
        [string]::IsNullOrWhiteSpace($env:TENANT_ID)) {
        Send-Response `
            -StatusCode InternalServerError `
            -ContentType 'application/json' `
            -CacheControl 'no-store' `
            -Body (@{ error = 'webClientNotConfigured' } | ConvertTo-Json -Compress)
        return
    }

    $requestUri = $null
    if ($Request.Url) {
        [void] [uri]::TryCreate(
            [string] $Request.Url,
            [UriKind]::Absolute,
            [ref] $requestUri
        )
    }
    # Preserve the incoming HTTPS custom-domain origin for same-origin API
    # calls and MSAL redirects. Do not construct HTTP authentication redirects.
    $origin = if ($requestUri -and $requestUri.Scheme -eq 'https') {
        $requestUri.GetLeftPart([UriPartial]::Authority)
    }
    else {
        "https://$($env:WEBSITE_HOSTNAME)"
    }
    # Configuration can change independently of built assets and must not be
    # cached across deployment or authentication-setting changes.
    Send-Response `
        -StatusCode OK `
        -ContentType 'application/json' `
        -CacheControl 'no-store' `
        -Body (@{
            clientId         = $env:WEB_CLIENT_ID
            authority        = "https://login.microsoftonline.com/$($env:TENANT_ID)"
            scope            = "$($env:API_AUDIENCE)/DeviceHash.Import"
            redirectUri      = "$origin/api/ui/index.html"
            silentRedirectUri = "$origin/api/ui/auth.html"
            importUrl        = "$origin/api/devices/import"
            tagsUrl          = "$origin/api/devices/tags"
            deviceTagAssignmentsUrl = "$origin/api/devices/tags/assignments"
            importHistoryUrl = "$origin/api/management/imports"
            tagPolicyUrl = "$origin/api/management/tag-policy"
            policyManagersUrl = "$origin/api/management/policy-managers"
            functionVersion   = $functionVersion
        } | ConvertTo-Json -Compress)
    return
}

# Canonicalize both root and requested file before checking containment so
# relative segments such as ".." cannot bypass the directory-prefix check.
$webRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'wwwroot'))
$relativePath = if ([string]::IsNullOrWhiteSpace($requestedPath)) {
    'index.html'
}
else {
    $requestedPath.Replace('/', [IO.Path]::DirectorySeparatorChar)
}
$resolvedPath = [IO.Path]::GetFullPath((Join-Path $webRoot $relativePath))
# Include the directory separator boundary: a sibling named "wwwroot-other"
# must not pass. Leaf-only access excludes directory listings.
if (-not $resolvedPath.StartsWith(
        "$($webRoot.TrimEnd([IO.Path]::DirectorySeparatorChar))$([IO.Path]::DirectorySeparatorChar)",
        [StringComparison]::OrdinalIgnoreCase) -or
    -not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
    Send-Response `
        -StatusCode NotFound `
        -ContentType 'application/json' `
        -CacheControl 'no-store' `
        -Body '{"error":"notFound"}'
    return
}

# Explicit MIME types are required because nosniff prevents the browser from
# guessing executable/text types. WebP and other binary formats stay as bytes.
$contentTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.js'   = 'text/javascript; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.jpeg' = 'image/jpeg'
    '.webp' = 'image/webp'
    '.svg'  = 'image/svg+xml'
    '.ico'  = 'image/x-icon'
    '.json' = 'application/json; charset=utf-8'
}
$extension = [IO.Path]::GetExtension($resolvedPath).ToLowerInvariant()
$contentType = if ($contentTypes.ContainsKey($extension)) {
    $contentTypes[$extension]
}
else {
    'application/octet-stream'
}
# Always fetch current HTML so it references the deployed asset filenames.
# All other files receive immutable caching, including unknown extensions.
$cacheControl = if ($extension -eq '.html') {
    'no-store'
}
else {
    'public, max-age=31536000, immutable'
}
$textExtensions = @('.html', '.js', '.css', '.svg', '.json')
$body = $null
if ($extension -in $textExtensions) {
    # Decode only known text formats; decoding binary image data as UTF-8
    # would corrupt the response even if its Content-Type were correct.
    $body = [IO.File]::ReadAllText(
        $resolvedPath,
        [Text.Encoding]::UTF8
    )
}
else {
    [byte[]] $body = [IO.File]::ReadAllBytes($resolvedPath)
}

Send-Response `
    -StatusCode OK `
    -ContentType $contentType `
    -CacheControl $cacheControl `
    -Body $body
