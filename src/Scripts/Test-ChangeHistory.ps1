#Requires -Version 7.2
# Project-Version: 1.3.20261007.4
# Author: andreas.lucas@outlook.com (aka Kili)

<#
.SYNOPSIS
Verifies the changelog, change history, and version in every commit in a range.

.DESCRIPTION
Checks every first-parent commit after BaseCommit through HeadCommit and fails
when CHANGELOG.md, History.md, or VERSION is not part of a commit, or when the
version date has more than one changelog or history section. Both sections for
that date must use the current VERSION in their headings. Automation commits
whose message contains [skip ci] are ignored.

.PARAMETER BaseCommit
Commit before the range to validate. An all-zero Git SHA validates HeadCommit
only, as used for the first push of a branch.

.PARAMETER HeadCommit
Last commit in the range to validate. The default is HEAD.

.EXAMPLE
.\src\Scripts\Test-ChangeHistory.ps1 `
    -BaseCommit 'HEAD~2' `
    -HeadCommit 'HEAD'

Validates the last two commits.

.OUTPUTS
System.String confirming how many commits were checked. The script throws a
terminating error when at least one commit is invalid.

.NOTES
Run from a Git working tree. Azure Pipelines uses this script to reject commits
without changelog, change history, and version updates.
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
    <#
    .SYNOPSIS
    Runs git and converts a nonzero exit code into a terminating error.

    .DESCRIPTION
    Git reports failures through its exit code rather than a PowerShell error.
    This helper makes every failed call fail the validation immediately instead
    of silently continuing with empty output.

    .PARAMETER ArgumentList
    Arguments passed to git.

    .OUTPUTS
    String array containing the output lines of the command.
    #>
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
    # Git reports an all-zero SHA as the base when a branch is pushed for the
    # first time. There is no predecessor to compare against, so only the head
    # commit is validated.
    if ($BaseCommit -match '^0{40}$') {
        $HeadCommit
    }
    else {
        Invoke-GitCommand -ArgumentList @(
            'rev-parse', '--verify', $BaseCommit
        ) | Out-Null
        # --first-parent evaluates merge commits as a single change and skips
        # the individual commits of a merged branch, which were already
        # validated on that branch.
        Invoke-GitCommand -ArgumentList @(
            'rev-list', '--reverse', '--first-parent',
            "$BaseCommit..$HeadCommit"
        )
    }
)

# Collect all violations instead of stopping at the first one, so a single run
# reports every invalid commit.
$invalidCommits = @(
    foreach ($commit in $commits) {
        $message = Invoke-GitCommand -ArgumentList @(
            'show', '--no-patch', '--format=%B', $commit
        )
        # Pipeline commits, for example an automated version bump, carry no
        # separate change history entry.
        if (($message -join [Environment]::NewLine) -match '\[skip ci\]') {
            continue
        }

        # --root also lists the files of an initial commit, which has no parent.
        $changedPaths = @(
            Invoke-GitCommand -ArgumentList @(
                'diff-tree', '--root', '--no-commit-id', '--name-only',
                '-r', '-m', $commit
            )
        )
        $missingFiles = @(
            'CHANGELOG.md', 'History.md', 'VERSION' | Where-Object {
                $changedPaths -notcontains $_
            }
        )
        $issues = @(
            if ($missingFiles.Count -gt 0) {
                "missing: $($missingFiles -join ', ')"
            }
            else {
                $version = ((Invoke-GitCommand -ArgumentList @(
                            'show', "${commit}:VERSION"
                        )) -join [Environment]::NewLine).Trim()
                $versionMatch = [regex]::Match(
                    $version,
                    '^(?<major>\d+)\.(?<minor>\d+)\.(?<date>\d{8})\.(?<counter>\d+)$'
                )
                if (-not $versionMatch.Success) {
                    "invalid VERSION: $version"
                }
                else {
                    # Read VERSION and History.md from the commit itself, not
                    # from the working tree, so each commit is validated in the
                    # state in which it was created.
                    $versionDate = [datetime]::ParseExact(
                        $versionMatch.Groups['date'].Value,
                        'yyyyMMdd',
                        [Globalization.CultureInfo]::InvariantCulture
                    ).ToString('yyyy-MM-dd')
                    $expectedHeading = "## ``$version`` - $versionDate"
                    $historyHeadings = @(
                        Invoke-GitCommand -ArgumentList @(
                            'show', "${commit}:History.md"
                        ) | Where-Object { $_.StartsWith('## ') }
                    )
                    $dateHeadings = @(
                        $historyHeadings | Where-Object {
                            $_.EndsWith(" - $versionDate")
                        }
                    )
                    # Several same-day changes belong in one section. Its
                    # heading must carry the current version.
                    if ($dateHeadings.Count -ne 1) {
                        "History.md must contain exactly one section for $versionDate"
                    }
                    elseif ($dateHeadings[0] -cne $expectedHeading) {
                        "history heading must be: $expectedHeading"
                    }

                    $expectedChangelogHeading = "## [$version] - $versionDate"
                    $changelogHeadings = @(
                        Invoke-GitCommand -ArgumentList @(
                            'show', "${commit}:CHANGELOG.md"
                        ) | Where-Object { $_.StartsWith('## [') }
                    )
                    $changelogDateHeadings = @(
                        $changelogHeadings | Where-Object {
                            $_.EndsWith("] - $versionDate")
                        }
                    )
                    # Keep one condensed public release summary per date and
                    # move its heading to the current same-day version.
                    if ($changelogDateHeadings.Count -ne 1) {
                        "CHANGELOG.md must contain exactly one section for $versionDate"
                    }
                    elseif ($changelogDateHeadings[0] -cne
                        $expectedChangelogHeading) {
                        "changelog heading must be: $expectedChangelogHeading"
                    }
                }
            }
        )
        if ($issues.Count -gt 0) {
            $shortCommit = Invoke-GitCommand -ArgumentList @(
                'show', '--no-patch', '--format=%h %s', $commit
            )
            "$($shortCommit -join ' ') ($($issues -join '; '))"
        }
    }
)

if ($invalidCommits.Count -gt 0) {
    throw "Every commit must update CHANGELOG.md, History.md, and VERSION and use one changelog and history section per version date. Invalid commits:$([Environment]::NewLine)$($invalidCommits -join [Environment]::NewLine)"
}

Write-Output "CHANGELOG.md, History.md, and VERSION were valid in all $($commits.Count) checked commit(s)."