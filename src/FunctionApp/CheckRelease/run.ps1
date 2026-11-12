# Project-Version: 1.4.20261112.1
# Author: andreas.lucas@outlook.com (aka Kili)

<#
.SYNOPSIS
Checks the latest published installation release once daily at 00:00 UTC.

.DESCRIPTION
The monitored Azure timer coordinates execution across Function instances.
Persists public release metadata for all browsers in private configuration
Storage. A failed GitHub lookup replaces the result with an explicit failure;
no credentials, device information or user data are sent to GitHub.
#>
param($Timer, $TriggerMetadata)

$ErrorActionPreference = 'Stop'
$repository = 'Kili69/Intune-Autopilotimporter'
$result = [ordered]@{
    status = 'unavailable'
    checkedAtUtc = [datetime]::UtcNow.ToString('o')
    version = $null
    releaseUrl = $null
}

try {
    $response = Invoke-WebRequest `
        -Uri "https://api.github.com/repos/$repository/releases/latest" `
        -Headers @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'Intune-Autopilotimporter'; 'X-GitHub-Api-Version' = '2022-11-28' } `
        -TimeoutSec 30 -SkipHttpErrorCheck -ErrorAction Stop
    if ($response.StatusCode -eq 404) {
        $result.status = 'noRelease'
    }
    else {
        if ($response.StatusCode -ne 200) {
            throw "GitHub release lookup returned HTTP $($response.StatusCode)."
        }
        $release = $response.Content | ConvertFrom-Json -ErrorAction Stop
        if ($release.draft -or $release.prerelease -or
            [string] $release.tag_name -cnotmatch '^v(?<version>\d+\.\d+\.\d{8}\.\d+)$') {
            throw 'GitHub did not return a stable, versioned project release.'
        }
        $version = $Matches.version
        $assetName = "Intune-autopilotImporter-main$version.zip"
        $assetUrl = "https://github.com/$repository/releases/download/v$version/$assetName"
        $assets = @($release.assets | Where-Object {
            $_.name -ceq $assetName -and $_.state -eq 'uploaded' -and
            $_.size -gt 0 -and $_.browser_download_url -ceq $assetUrl
        })
        if ($assets.Count -ne 1) {
            throw 'The latest release has no completed main installation ZIP.'
        }
        $result.status = 'available'
        $result.version = $version
        $result.releaseUrl = "https://github.com/$repository/releases/tag/v$version"
    }
}
catch {
    Write-Warning "Daily release check failed: $($_.Exception.Message)"
}

Push-OutputBinding -Name ReleaseStatus -Value ($result | ConvertTo-Json -Compress)
