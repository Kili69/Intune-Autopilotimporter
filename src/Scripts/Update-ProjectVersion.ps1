#Requires -Version 7.2
# Project-Version: 1.1.20260913.1
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
DISCLAIMER:
This sample script is not supported under any Microsoft standard support program or service.
The sample script is provided AS IS without warranty of any kind. Microsoft further disclaims
all implied warranties including, without limitation, any implied warranties of merchantability
or of fitness for a particular purpose. The entire risk arising out of the use or performance of
the sample scripts and documentation remains with you. In no event shall Microsoft, its authors,
or anyone else involved in the creation, production, or delivery of the scripts be liable for any
damages whatsoever (including, without limitation, damages for loss of business profits, business
interruption, loss of business information, or other pecuniary loss) arising out of the use of or
inability to use the sample scripts or documentation, even if Microsoft has been advised of the
possibility of such damages.
#>

<#
.SYNOPSIS
Increments and synchronizes the project version.

.DESCRIPTION
Reads the current version from VERSION, creates a version in the format
1.1.yyyyMMdd.counter, and updates the Project-Version marker in every PowerShell
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
$markerPattern = '(?m)^# Project-Version: \d+\.\d+\.\d{8}\.\d+\r?$'
$moduleVersionPattern = "(?m)^(\s*ModuleVersion\s*=\s*)'\d+\.\d+\.\d{8}\.\d+'"
$scriptInfoVersionPattern = `
    '(?m)^(\.VERSION\s+)\d+\.\d+\.\d{8}\.\d+\r?$'

$currentVersion = (Get-Content -LiteralPath $versionPath -Raw).Trim()
if ($currentVersion -notmatch $versionPattern) {
    throw "VERSION contains '$currentVersion', which does not match 1.1.yyyyMMdd.counter."
}
if ($Matches.major -ne '1' -or $Matches.minor -ne '1') {
    throw "VERSION must use the 1.1 major and minor version prefix."
}

$versionDate = $Date.ToUniversalTime().ToString('yyyyMMdd')
$counter = if ($Matches.date -eq $versionDate) {
    [int] $Matches.counter + $IncrementBy
}
else {
    $IncrementBy
}
$newVersion = "1.1.$versionDate.$counter"

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

if ($PSCmdlet.ShouldProcess($versionPath, "Set project version to $newVersion")) {
    Set-Content -LiteralPath $versionPath -Value $newVersion
}

$newVersion
