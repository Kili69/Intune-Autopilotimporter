# Project-Version: 1.4.20261112.1
# Author: andreas.lucas@outlook.com (aka Kili)

<#
.SYNOPSIS
Returns centrally cached public release metadata without querying GitHub.

.DESCRIPTION
Before the daily timer first runs, returns pending. Storage/binding failures
are surfaced by the Functions host rather than triggering a GitHub fallback.
#>
using namespace System.Net

param($Request, $TriggerMetadata, $ReleaseStatusBlob)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\AutopilotImport\AutopilotImport.psm1') -Force
$content = ConvertFrom-BlobBindingContent -Value $ReleaseStatusBlob
$body = if ([string]::IsNullOrWhiteSpace($content)) {
    @{ status = 'pending'; checkedAtUtc = $null; version = $null; releaseUrl = $null }
}
else {
    $content | ConvertFrom-Json -ErrorAction Stop
}
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Headers = @{ 'Content-Type' = 'application/json'; 'Cache-Control' = 'no-store' }
    Body = ($body | ConvertTo-Json -Compress)
})
