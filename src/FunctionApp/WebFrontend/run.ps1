# Project-Version: 1.1.20260912.2
# Author: andreas.lucas@microsoft.com (aka Kili)

using namespace System.Net

param($Request, $TriggerMetadata)

$requestedPath = [string] $Request.Params.path
$securityHeaders = @{
    'Content-Security-Policy' = "default-src 'self'; connect-src 'self' https://login.microsoftonline.com; frame-src https://login.microsoftonline.com; img-src 'self' data:; style-src 'self'; script-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    'Referrer-Policy'         = 'no-referrer'
    'X-Content-Type-Options'  = 'nosniff'
    'X-Frame-Options'         = 'DENY'
    'Permissions-Policy'      = 'camera=(), microphone=(), geolocation=()'
}

function Send-Response {
    param(
        [Parameter(Mandatory)]
        [HttpStatusCode] $StatusCode,

        [Parameter(Mandatory)]
        [object] $Body,

        [Parameter(Mandatory)]
        [string] $ContentType,

        [string] $CacheControl = 'public, max-age=3600'
    )

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
    $origin = if ($requestUri -and $requestUri.Scheme -eq 'https') {
        $requestUri.GetLeftPart([UriPartial]::Authority)
    }
    else {
        "https://$($env:WEBSITE_HOSTNAME)"
    }
    Send-Response `
        -StatusCode OK `
        -ContentType 'application/json' `
        -CacheControl 'no-store' `
        -Body (@{
            clientId    = $env:WEB_CLIENT_ID
            authority   = "https://login.microsoftonline.com/$($env:TENANT_ID)"
            scope       = "$($env:API_AUDIENCE)/DeviceHash.Import"
            redirectUri = "$origin/api/ui/index.html"
            importUrl   = "$origin/api/devices/import"
            tagsUrl     = "$origin/api/devices/tags"
        } | ConvertTo-Json -Compress)
    return
}

$webRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'wwwroot'))
$relativePath = if ([string]::IsNullOrWhiteSpace($requestedPath)) {
    'index.html'
}
else {
    $requestedPath.Replace('/', [IO.Path]::DirectorySeparatorChar)
}
$resolvedPath = [IO.Path]::GetFullPath((Join-Path $webRoot $relativePath))
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

$contentTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.js'   = 'text/javascript; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
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
$cacheControl = if ($extension -eq '.html') {
    'no-store'
}
else {
    'public, max-age=31536000, immutable'
}
$textExtensions = @('.html', '.js', '.css', '.svg', '.json')
$body = if ($extension -in $textExtensions) {
    [IO.File]::ReadAllText($resolvedPath, [Text.Encoding]::UTF8)
}
else {
    [IO.File]::ReadAllBytes($resolvedPath)
}

Send-Response `
    -StatusCode OK `
    -ContentType $contentType `
    -CacheControl $cacheControl `
    -Body $body
