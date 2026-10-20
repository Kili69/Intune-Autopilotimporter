#Requires -Version 7.2
# Project-Version: 1.4.20261020.15
# Author: andreas.lucas@outlook.com (aka Kili)

<#
.SYNOPSIS
Opens dev-fix synchronization PRs without modifying development branches.
.DESCRIPTION
Uses the current protected dev SHA, never code from a target branch. Creates
an isolated sync ref per target and dev commit, so conflicts can be resolved
there without editing dev or overwriting existing conflict resolutions.
Reruns reuse the same ref and PR. No merge, force push or version change occurs.
GH_TOKEN needs repository contents and pull-request write permissions.
.PARAMETER Repository
GitHub owner/repository name.
.OUTPUTS
Created or existing synchronization PR URLs. Already synchronized branches are
reported as verbose output. Any failed target makes the overall run fail.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string] $Repository
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Ensure that the required environment variable and API headers are set up correctly.
if (-not $env:GH_TOKEN) { throw 'GH_TOKEN is required for development-branch synchronization.' }
$api = "https://api.github.com/repos/$Repository"
# Set up the necessary headers for GitHub API requests.
$headers = @{
    Authorization = "Bearer $env:GH_TOKEN"
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}
function Invoke-SyncApi {
    <#
    .SYNOPSIS
    Invokes a GitHub API request for the synchronization process.

    .DESCRIPTION
    Constructs and sends an HTTP request to the GitHub API using the specified path, method, and body.
    Handles JSON serialization and includes the necessary authentication headers.

    .PARAMETER Path
    The relative path of the GitHub API endpoint.

    .PARAMETER Method
    The HTTP method to use for the request. Defaults to 'GET'.

    .PARAMETER Body
    The request body for POST or other methods that require it.
    #>
    param([string] $Path, [string] $Method = 'GET', [object] $Body)
    $parameters = @{ Uri = "$api/$Path"; Method = $Method; Headers = $headers; ErrorAction = 'Stop' }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = ConvertTo-Json -InputObject $Body -Depth 10 -Compress
    }
    Invoke-RestMethod @parameters
}
function Get-SyncPages {
    <#
    .SYNOPSIS
    Retrieves all paginated results from a GitHub API endpoint.

    .DESCRIPTION
    Iterates through paginated responses from the specified GitHub API path, collecting all items.

    .PARAMETER Path
    The relative path of the GitHub API endpoint.
    #>
    param([string] $Path)
    # Initialize the page counter and begin iterating through paginated results.
    for ($page = 1; ; $page++) {
        $separator = if ($Path.Contains('?')) { '&' } else { '?' }
        $response = Invoke-SyncApi "$Path${separator}per_page=100&page=$page"
        $items = @($response | ForEach-Object { $_ })
        $items
        if ($items.Count -lt 100) { break }
    }
}
# Retrieve the SHA of the dev branch to use as the source for synchronization.
$devSha = [string] (Invoke-SyncApi 'git/ref/heads/dev').object.sha
# Validate that the retrieved dev SHA is in the correct format.
if ($devSha -notmatch '^[0-9a-f]{40}$') { throw 'GitHub returned an invalid dev commit.' }
# Retrieve the list of target branches to synchronize with dev, excluding main, dev, and existing sync branches.
$targets = @(Get-SyncPages 'branches' | Where-Object {
    $_.name -notin @('main', 'dev') -and $_.name -notlike 'sync/dev/*' -and
    $_.name -notlike 'sync/dev-to-*'
})
# Initialize a list to track any synchronization failures.
$failures = [Collections.Generic.List[string]]::new()
foreach ($target in $targets) {
    try {
        # Extract the SHA of the target branch and validate its format.
        $targetSha = [string] $target.commit.sha
        # Ensure that the target SHA is a valid 40-character hexadecimal string.
        if ($targetSha -notmatch '^[0-9a-f]{40}$') { throw 'GitHub returned an invalid target commit.' }
        # Compare the dev and target branches to determine if synchronization is necessary.
        $comparison = Invoke-SyncApi "compare/$devSha...$targetSha"
        # The comparison object contains the status of the dev branch relative to the target branch.
        # If the dev branch is ahead or identical to the target, no synchronization is needed.
        if ($comparison.status -in @('ahead', 'identical')) {
            Write-Verbose "$($target.name) already includes dev $devSha."
            continue
        }
        # If the dev branch is behind or has diverged from the target, synchronization is required.
        if ($comparison.status -notin @('behind', 'diverged')) { throw 'Unexpected GitHub comparison result.' }
        # Generate a unique sync branch name based on the target branch and dev SHA.
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes([string] $target.name))).ToLowerInvariant().Substring(0, 16)
        $syncBranch = "sync/dev/$hash/$devSha"
        try {
            $null = Invoke-SyncApi "git/ref/heads/$syncBranch"
        } catch {
            if ([int] $_.Exception.Response.StatusCode -ne 404) { throw }
            $null = Invoke-SyncApi 'git/refs' POST @{ ref = "refs/heads/$syncBranch"; sha = $devSha }
        }
        # Encode the target and head branch names for use in the GitHub API query.
        $encodedTarget = [uri]::EscapeDataString([string] $target.name)
        $encodedHead = [uri]::EscapeDataString("$($Repository.Split('/')[0]):$syncBranch")
        $existing = @(Get-SyncPages "pulls?state=all&base=$encodedTarget&head=$encodedHead")
        if ($existing.Count) {
            $existing | ForEach-Object { $_.html_url }
            continue
        }
        # If no existing pull request is found, create a new one for the sync branch.
        $pr = Invoke-SyncApi 'pulls' POST @{
            base = [string] $target.name
            head = $syncBranch
            title = "Sync dev changes into $($target.name)"
            body = "Includes protected dev commit $devSha. Resolve conflicts on this sync branch, never on dev. Preserve the target's newer version line, consolidate same-day history, update version metadata and rebuild the frontend when needed. Merge deliberately; nothing is auto-merged. New dev commits get separate sync PRs so manual conflict resolutions are never overwritten."
        }
        $pr.html_url
    } catch {
        # Record the failure and continue with the next target branch.
        $failures.Add([string] $target.name)
        Write-Error "Cannot synchronize '$($target.name)': $($_.Exception.Message)" -ErrorAction Continue
    }
}
if ($failures.Count) { throw "Synchronization failed for: $($failures -join ', ')." }
