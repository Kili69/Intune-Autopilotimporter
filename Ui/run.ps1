# Project-Version: 1.0.20260911.1
# Author: andreas.lucas@microsoft.com (aka Kili)

using namespace System.Net

param($Request, $TriggerMetadata)

$webRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\WebFrontend\wwwroot'))
$requestedPath = [string] $Request.Params.path
if ([string]::IsNullOrWhiteSpace($requestedPath)) {
    $requestedPath = 'index.html'
}

$relativePath = $requestedPath.Replace('/', [IO.Path]::DirectorySeparatorChar)
$candidatePath = [IO.Path]::GetFullPath((Join-Path $webRoot $relativePath))
$webRootPrefix = $webRoot.TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
) + [IO.Path]::DirectorySeparatorChar

if (-not $candidatePath.StartsWith(
        $webRootPrefix,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::NotFound
        Headers    = @{ 'Cache-Control' = 'no-store' }
        Body       = 'Not found.'
    })
    return
}

$contentType = switch ([IO.Path]::GetExtension($candidatePath).ToLowerInvariant()) {
    '.css'   { 'text/css; charset=utf-8' }
    '.html'  { 'text/html; charset=utf-8' }
    '.ico'   { 'image/x-icon' }
    '.jpeg'  { 'image/jpeg' }
    '.jpg'   { 'image/jpeg' }
    '.js'    { 'text/javascript; charset=utf-8' }
    '.json'  { 'application/json; charset=utf-8' }
    '.png'   { 'image/png' }
    '.svg'   { 'image/svg+xml' }
    '.webp'  { 'image/webp' }
    '.woff'  { 'font/woff' }
    '.woff2' { 'font/woff2' }
    default  { 'application/octet-stream' }
}
$cacheControl = if ($candidatePath.EndsWith(
        'index.html',
        [StringComparison]::OrdinalIgnoreCase
    )) {
    'no-cache'
}
else {
    'public, max-age=31536000, immutable'
}

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Headers    = @{
        'Cache-Control' = $cacheControl
        'Content-Type'  = $contentType
    }
    Body       = [IO.File]::ReadAllBytes($candidatePath)
})