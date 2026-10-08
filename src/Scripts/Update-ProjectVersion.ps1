#Requires -Version 7.2
# Project-Version: 1.3.20261007.4
# Author: andreas.lucas@outlook.com (aka Kili)

# Copyright 2026 Andreas Lucas
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the project root for license information.

<#
.SYNOPSIS
Increments and synchronizes the project version.

.DESCRIPTION
Reads the current version from VERSION, creates a version in the format
1.3.yyyyMMdd.counter, and updates the Project-Version marker in every PowerShell
script, module, and data file in the repository.

The counter increases by IncrementBy when the existing version date matches
Date. It starts at IncrementBy when the date changes. Run this script locally
before committing changes that require a new project version.

.PARAMETER IncrementBy
Number to add to the current day's counter. The default is 1.

.PARAMETER Date
UTC date used in the version. The default is the current UTC date.

.EXAMPLE
.\src\Scripts\Update-ProjectVersion.ps1

Increments the current day's counter by one.

.EXAMPLE
.\src\Scripts\Update-ProjectVersion.ps1 -IncrementBy 3

Increments the counter by three when a push contains three commits.

.OUTPUTS
System.String. Returns the new project version.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateRange(1, 1000000)]
    [int] $IncrementBy = 1,

    [datetime] $Date = [datetime]::UtcNow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$versionPath = Join-Path $projectRoot 'VERSION'
$versionPattern = '^(?<major>\d+)\.(?<minor>\d+)\.(?<date>\d{8})\.(?<counter>\d+)$'
$targetMajor = 1
$targetMinor = 3
# The version appears in three different notations. Each pattern is anchored to
# the start of a line so that documentation or examples are never rewritten.
$markerPattern = '(?m)^# Project-Version: \d+\.\d+\.\d{8}\.\d+\r?$'
$moduleVersionPattern = "(?m)^(\s*ModuleVersion\s*=\s*)'\d+\.\d+\.\d{8}\.\d+'"
$scriptInfoVersionPattern = `
    '(?m)^(\.VERSION\s+)\d+\.\d+\.\d{8}\.\d+\r?$'

$currentVersion = (Get-Content -LiteralPath $versionPath -Raw).Trim()
if ($currentVersion -notmatch $versionPattern) {
    throw "VERSION contains '$currentVersion', which does not match major.minor.yyyyMMdd.counter."
}

# Continue the counter only within the same major, minor, and date. Any other
# change starts a new day, so the counter restarts at IncrementBy.
$versionDate = $Date.ToUniversalTime().ToString('yyyyMMdd')
$counter = if ([int] $Matches.major -eq $targetMajor -and
    [int] $Matches.minor -eq $targetMinor -and
    $Matches.date -eq $versionDate) {
    [int] $Matches.counter + $IncrementBy
}
else {
    $IncrementBy
}
$newVersion = "$targetMajor.$targetMinor.$versionDate.$counter"

# Generated and external directories are excluded. They contain copies whose
# version must stay tied to the build they were created from.
$powerShellFiles = @(
    Get-ChildItem -LiteralPath $projectRoot -Recurse -File |
        Where-Object {
            $_.Extension -in '.ps1', '.psm1', '.psd1' -and
            $_.FullName -notmatch `
                '[\\/](?:node_modules|InstallationPackage|\.git)[\\/]'
        }
)

foreach ($file in $powerShellFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    # Exactly one marker is required. A missing marker would leave the file at
    # an old version, and several markers would make the result ambiguous.
    $markers = [regex]::Matches($content, $markerPattern)
    if ($markers.Count -ne 1) {
        throw "'$($file.FullName)' must contain exactly one Project-Version marker."
    }

    $updatedContent = [regex]::Replace(
        $content,
        $markerPattern,
        "# Project-Version: $newVersion",
        1
    )
    # Scripts published to the PowerShell Gallery carry their version a second
    # time in the PSScriptInfo block. Both entries must stay identical.
    if ($content -match '(?m)^<#PSScriptInfo\s*$') {
        if ([regex]::Matches(
                $content,
                $scriptInfoVersionPattern).Count -ne 1) {
            throw "'$($file.FullName)' must contain exactly one PSScriptInfo VERSION entry."
        }
        $updatedContent = [regex]::Replace(
            $updatedContent,
            $scriptInfoVersionPattern,
            ('${1}' + $newVersion),
            1
        )
    }
    if ($PSCmdlet.ShouldProcess($file.FullName, "Set project version to $newVersion")) {
        Set-Content -LiteralPath $file.FullName -Value $updatedContent -NoNewline
    }
}

# The client module manifest additionally carries a ModuleVersion. PowerShell
# resolves installed module versions through this value.
$clientManifestPath = Join-Path $projectRoot `
    'src\AutopilotImport.Client\AutopilotImport.Client.psd1'
$clientManifestContent = Get-Content -LiteralPath $clientManifestPath -Raw
if ([regex]::Matches($clientManifestContent, $moduleVersionPattern).Count -ne 1) {
    throw "'$clientManifestPath' must contain exactly one ModuleVersion entry."
}
$updatedManifestContent = [regex]::Replace(
    $clientManifestContent,
    $moduleVersionPattern,
    "`$1'$newVersion'",
    1
)
if ($PSCmdlet.ShouldProcess($clientManifestPath, "Set ModuleVersion to $newVersion")) {
    Set-Content `
        -LiteralPath $clientManifestPath `
        -Value $updatedManifestContent `
        -NoNewline
}

# Write VERSION last, so a failure in an earlier step does not leave the
# canonical version ahead of the files that still carry the old value.
if ($PSCmdlet.ShouldProcess($versionPath, "Set project version to $newVersion")) {
    Set-Content -LiteralPath $versionPath -Value $newVersion
}

$newVersion
