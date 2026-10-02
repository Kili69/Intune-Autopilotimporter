#Requires -Version 7.2
# Project-Version: 1.3.20261002.2
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
.SYNOPSIS
Creates synthetic Autopilot CSV files for client and API testing.

.DESCRIPTION
Creates one CSV file per synthetic device. Serial numbers and Base64 payloads
are deterministic and explicitly identify themselves as test data. The payloads
are not real Windows Autopilot hardware hashes and must not be used for an
actual device registration.

.PARAMETER OutputPath
Directory in which the generated CSV files are created.

.PARAMETER Count
Number of single-device CSV files to create.

.OUTPUTS
System.IO.FileInfo for each generated CSV file.
#>

[CmdletBinding()]
param(
    [string] $OutputPath = (Join-Path $PSScriptRoot '..\test-data\autopilot-csv'),

    [ValidateRange(1, 10000)]
    [int] $Count = 100
)

$resolvedOutputPath = [IO.Path]::GetFullPath($OutputPath)
[void] (New-Item -Path $resolvedOutputPath -ItemType Directory -Force)

for ($index = 1; $index -le $Count; $index++) {
    $identifier = 'SYNTHETIC-AUTOPILOT-TEST-{0:D3}' -f $index
    $hardwareHash = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($identifier)
    )
    $csvPath = Join-Path $resolvedOutputPath ('autopilot-test-{0:D3}.csv' -f $index)

    [pscustomobject]@{
        'Device Serial Number' = $identifier
        'Hardware Hash'        = $hardwareHash
    } | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8NoBOM

    Get-Item -LiteralPath $csvPath
}