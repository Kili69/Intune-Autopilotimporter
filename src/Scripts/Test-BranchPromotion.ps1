#Requires -Version 7.2
# Project-Version: 1.4.20261020.14
# Author: andreas.lucas@outlook.com (aka Kili)

<#
.SYNOPSIS
Validates branch routes and release-line changes using Git objects only.
.DESCRIPTION
Run the trusted protected-dev copy for pull requests. No code from the source
branch is executed. ResultCommit is GitHub's prospective merge commit.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SourceBranch,
    [Parameter(Mandatory)][string] $TargetBranch,
    [Parameter(Mandatory)][string] $SourceRepository,
    [Parameter(Mandatory)][string] $TargetRepository,
    [Parameter(Mandatory)][string] $BaseCommit,
    [Parameter(Mandatory)][string] $HeadCommit,
    [Parameter(Mandatory)][string] $DevCommit,
    [Parameter(Mandatory)][string] $ResultCommit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ProjectVersion([string] $Commit) {
    $value = & git show "${Commit}:VERSION"
    if ($LASTEXITCODE -ne 0) { throw "Cannot read VERSION at $Commit." }
    $value = ($value -join "`n").Trim()
    if ($value -notmatch '^\d+\.\d+\.\d{8}\.\d+$') {
        throw "Invalid VERSION at ${Commit}: $value"
    }
    return [version] $value
}

if ($TargetBranch -eq 'main' -and
    ($SourceBranch -ne 'dev' -or $SourceRepository -ne $TargetRepository)) {
    throw 'main may only be updated from dev in this repository.'
}

if ($TargetBranch -notin 'main', 'dev') { return }

$baseVersion = Get-ProjectVersion $BaseCommit
$resultVersion = Get-ProjectVersion $ResultCommit
if ($resultVersion -lt $baseVersion) { throw 'A merge must not decrease VERSION.' }

switch ($TargetBranch) {
    'main' {
        if ($resultVersion -le $baseVersion) {
            throw 'Promotion to main requires a higher VERSION in dev before merging.'
        }
    }
    'dev' {
        & git merge-base --is-ancestor $DevCommit $HeadCommit
        if ($LASTEXITCODE -eq 1) {
            throw 'Sync the latest dev changes into the development branch before promotion.'
        }
        if ($LASTEXITCODE -ne 0) { throw 'Cannot verify dev ancestry.' }
    }
}

'Branch route and project version are valid.'
