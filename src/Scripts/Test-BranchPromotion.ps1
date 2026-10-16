#Requires -Version 7.2
# Project-Version: 1.3.20261016.2
# Author: andreas.lucas@outlook.com (aka Kili)

<#
.SYNOPSIS
Validates branch routes and release-line changes using Git objects only.
.DESCRIPTION
Run the trusted base-branch copy for pull requests. No code from the source
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

function Get-ReleaseLine([version] $Version) {
    return [version] "$($Version.Major).$($Version.Minor)"
}

if ($SourceBranch -eq 'nextversion' -and
    ($TargetBranch -ne 'dev' -or $SourceRepository -ne $TargetRepository)) {
    throw 'nextversion may only be promoted to dev in this repository.'
}
if ($TargetBranch -eq 'main' -and
    ($SourceBranch -ne 'dev' -or $SourceRepository -ne $TargetRepository)) {
    throw 'main may only be updated from dev in this repository.'
}

if ($TargetBranch -notin 'main', 'dev', 'nextversion') { return }

$baseVersion = Get-ProjectVersion $BaseCommit
$resultVersion = Get-ProjectVersion $ResultCommit
$baseLine = Get-ReleaseLine $baseVersion
$resultLine = Get-ReleaseLine $resultVersion
if ($resultVersion -lt $baseVersion) { throw 'A merge must not decrease VERSION.' }

switch ($TargetBranch) {
    'main' {
        if ($resultVersion -le $baseVersion) {
            throw 'Promotion to main requires a higher VERSION in dev before merging.'
        }
    }
    'dev' {
        if ($SourceBranch -eq 'nextversion' -and $SourceRepository -eq $TargetRepository) {
            if ($resultLine -le $baseLine) {
                throw 'nextversion must introduce at least a new minor or major release line.'
            }
            & git merge-base --is-ancestor $DevCommit $HeadCommit
            if ($LASTEXITCODE -eq 1) {
                throw 'Sync the latest dev changes into nextversion before promotion.'
            }
            if ($LASTEXITCODE -ne 0) { throw 'Cannot verify dev ancestry.' }
        }
        elseif ($resultLine -ne $baseLine) {
            throw 'Only nextversion may change the major/minor release line of dev.'
        }
    }
    'nextversion' {
        $devLine = Get-ReleaseLine (Get-ProjectVersion $DevCommit)
        if ($resultLine -le $devLine) {
            throw 'nextversion must be at least one minor or major release ahead of dev. Start the next cycle explicitly after promotion.'
        }
        if ($SourceBranch -like 'sync/dev-to-nextversion*' -or $SourceBranch -eq 'dev') {
            if ($resultLine -ne $baseLine) {
                throw 'A dev sync must preserve the major/minor release line of nextversion.'
            }
            & git merge-base --is-ancestor $DevCommit $HeadCommit
            if ($LASTEXITCODE -ne 0) { throw 'The sync must include the latest dev commit.' }
        }
    }
}

'Branch route and project version are valid.'
