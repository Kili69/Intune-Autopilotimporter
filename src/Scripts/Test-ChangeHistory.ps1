#Requires -Version 7.2
# Project-Version: 1.1.20260913.5
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
.SYNOPSIS
Verifies that every commit in a range updates History.md and VERSION.

.DESCRIPTION
Checks every first-parent commit after BaseCommit through HeadCommit and fails
when History.md or VERSION is not part of a commit. Automation commits whose
message contains [skip ci] are ignored.

.PARAMETER BaseCommit
Commit before the range to validate. An all-zero Git SHA validates HeadCommit
only, as used for the first push of a branch.

.PARAMETER HeadCommit
Last commit in the range to validate. The default is HEAD.

.EXAMPLE
.\src\Scripts\Test-ChangeHistory.ps1 `
    -BaseCommit 'HEAD~2' `
    -HeadCommit 'HEAD'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $BaseCommit,

    [string] $HeadCommit = 'HEAD'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-GitCommand {
    param(
        [Parameter(Mandatory)]
        [string[]] $ArgumentList
    )

    $output = @(& git @ArgumentList 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($ArgumentList -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return $output
}

Invoke-GitCommand -ArgumentList @('rev-parse', '--verify', $HeadCommit) |
    Out-Null

$commits = @(
    if ($BaseCommit -match '^0{40}$') {
        $HeadCommit
    }
    else {
        Invoke-GitCommand -ArgumentList @(
            'rev-parse', '--verify', $BaseCommit
        ) | Out-Null
        Invoke-GitCommand -ArgumentList @(
            'rev-list', '--reverse', '--first-parent',
            "$BaseCommit..$HeadCommit"
        )
    }
)

$invalidCommits = @(
    foreach ($commit in $commits) {
        $message = Invoke-GitCommand -ArgumentList @(
            'show', '--no-patch', '--format=%B', $commit
        )
        if (($message -join [Environment]::NewLine) -match '\[skip ci\]') {
            continue
        }

        $changedPaths = @(
            Invoke-GitCommand -ArgumentList @(
                'diff-tree', '--root', '--no-commit-id', '--name-only',
                '-r', '-m', $commit
            )
        )
        $missingFiles = @(
            'History.md', 'VERSION' | Where-Object {
                $changedPaths -notcontains $_
            }
        )
        if ($missingFiles.Count -gt 0) {
            $shortCommit = Invoke-GitCommand -ArgumentList @(
                'show', '--no-patch', '--format=%h %s', $commit
            )
            "$($shortCommit -join ' ') (missing: $($missingFiles -join ', '))"
        }
    }
)

if ($invalidCommits.Count -gt 0) {
    throw "Every commit must update History.md and VERSION. Invalid commits:$([Environment]::NewLine)$($invalidCommits -join [Environment]::NewLine)"
}

Write-Output "History.md and VERSION were updated by all $($commits.Count) checked commit(s)."