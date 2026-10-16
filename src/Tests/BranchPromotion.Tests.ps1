# Project-Version: 1.4.20261016.5
# Author: andreas.lucas@outlook.com (aka Kili)

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $policy = Join-Path $root 'src\Scripts\Test-BranchPromotion.ps1'
    $updater = Join-Path $root 'src\Scripts\Update-ProjectVersion.ps1'
    function New-VersionCommit([string] $Version) {
        Set-Content VERSION $Version
        git add VERSION
        git -c user.name=Test -c user.email=test@example.invalid commit -qm $Version
        if ($LASTEXITCODE -ne 0) { throw 'Cannot create version fixture.' }
        return git rev-parse HEAD
    }
}

Describe 'Branch promotion policy' {
    BeforeAll {
        $repo = Join-Path $TestDrive 'policy'
        New-Item $repo -ItemType Directory | Out-Null
        Push-Location $repo
        git init -q
        $base = New-VersionCommit '1.3.20261016.1'
        $revision = New-VersionCommit '1.3.20261016.2'
        $future = New-VersionCommit '1.4.20261016.1'
        $major = New-VersionCommit '2.0.20261016.1'
    }
    AfterAll { Pop-Location }
    BeforeEach {
        $arguments = @{
            SourceBranch = 'feature'
            TargetBranch = 'dev'
            SourceRepository = 'owner/repo'
            TargetRepository = 'owner/repo'
            BaseCommit = $base
            HeadCommit = $revision
            DevCommit = $base
            ResultCommit = $revision
        }
    }

    It 'allows a dev revision without changing the release line' {
        { & $policy @arguments } | Should -Not -Throw
    }
    It 'rejects a premature release-line change in dev' {
        $arguments.ResultCommit = $future
        { & $policy @arguments } | Should -Throw '*Only nextversion*'
    }
    It 'allows minor and major promotions from nextversion' -ForEach @(
        @{ Kind = 'future' }, @{ Kind = 'major' }
    ) {
        $arguments.SourceBranch = 'nextversion'
        $arguments.ResultCommit = Get-Variable $Kind -ValueOnly
        $arguments.HeadCommit = $arguments.ResultCommit
        { & $policy @arguments } | Should -Not -Throw
    }
    It 'rejects nextversion promotions without a new release line' {
        $arguments.SourceBranch = 'nextversion'
        { & $policy @arguments } | Should -Throw '*at least a new minor*'
    }
    It 'rejects nextversion promotions that omit newer dev commits' {
        git checkout -q --detach $base
        $divergent = New-VersionCommit '1.3.20261017.1'
        $arguments.SourceBranch = 'nextversion'
        $arguments.ResultCommit = $future
        $arguments.HeadCommit = $future
        $arguments.DevCommit = $divergent
        { & $policy @arguments } | Should -Throw '*latest dev changes*'
    }
    It 'rejects nextversion targeting main or an unrelated branch' -ForEach @(
        @{ Target = 'main' }, @{ Target = 'feature' }
    ) {
        $arguments.SourceBranch = 'nextversion'
        $arguments.TargetBranch = $Target
        { & $policy @arguments } | Should -Throw '*only be promoted to dev*'
    }
    It 'rejects feature branches and forks targeting main' -ForEach @(
        @{ Source = 'feature'; Repository = 'owner/repo' }
        @{ Source = 'dev'; Repository = 'fork/repo' }
    ) {
        $arguments.TargetBranch = 'main'
        $arguments.SourceBranch = $Source
        $arguments.SourceRepository = $Repository
        { & $policy @arguments } | Should -Throw '*only be updated from dev*'
    }
    It 'requires a higher full version for main' {
        $arguments.TargetBranch = 'main'
        $arguments.SourceBranch = 'dev'
        $arguments.ResultCommit = $base
        { & $policy @arguments } | Should -Throw '*higher VERSION*'
        $arguments.ResultCommit = $revision
        { & $policy @arguments } | Should -Not -Throw
    }
    It 'preserves the nextversion release line during a dev sync' {
        $arguments.TargetBranch = 'nextversion'
        $arguments.SourceBranch = 'sync/dev-to-nextversion'
        $arguments.BaseCommit = $future
        $arguments.ResultCommit = $future
        $arguments.HeadCommit = $future
        { & $policy @arguments } | Should -Not -Throw
        $arguments.ResultCommit = $major
        { & $policy @arguments } | Should -Throw '*preserve*'
    }
    It 'rejects a downgrade during sync' {
        $arguments.TargetBranch = 'nextversion'
        $arguments.BaseCommit = $future
        { & $policy @arguments } | Should -Throw '*decrease*'
    }
    It 'requires nextversion to stay ahead of dev for a new cycle' {
        $arguments.TargetBranch = 'nextversion'
        $arguments.BaseCommit = $future
        $arguments.ResultCommit = $future
        $arguments.DevCommit = $future
        { & $policy @arguments } | Should -Throw '*ahead of dev*'
    }
}

Describe 'Version updater release lines' {
    BeforeEach {
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $scripts = New-Item (Join-Path $fixture 'src\Scripts') -ItemType Directory -Force
        $manifest = Join-Path $fixture 'src\AutopilotImport.Client'
        New-Item $manifest -ItemType Directory -Force | Out-Null
        Copy-Item $updater $scripts
        $fixtureUpdater = Join-Path $scripts 'Update-ProjectVersion.ps1'
        Set-Content (Join-Path $fixture 'VERSION') '1.4.20261016.2'
        Set-Content (Join-Path $manifest 'AutopilotImport.Client.psd1') (
            "# Project-" + "Version: 1.4.20261016.2`n@{`n    ModuleVersion = '1.4.20261016.2'`n}"
        )
    }
    It 'preserves a future minor and increments the same-day counter' {
        & $fixtureUpdater -Date ([datetime]'2026-10-16T00:00:00Z') |
            Should -Be '1.4.20261016.3'
    }
    It 'starts a new counter on the next UTC date' {
        & $fixtureUpdater -Date ([datetime]'2026-10-17T00:00:00Z') |
            Should -Be '1.4.20261017.1'
    }
    It 'supports an explicit major version' {
        & $fixtureUpdater -Major 2 -Minor 0 -Date ([datetime]'2026-10-16T00:00:00Z') |
            Should -Be '2.0.20261016.1'
    }
    It 'supports an explicit minor version' {
        & $fixtureUpdater -Minor 5 -Date ([datetime]'2026-10-16T00:00:00Z') |
            Should -Be '1.5.20261016.1'
    }
    It 'rejects release-line and date downgrades without updating VERSION' {
        { & $fixtureUpdater -Minor 3 } | Should -Throw '*must not decrease*'
        { & $fixtureUpdater -Date ([datetime]'2026-10-15T00:00:00Z') } |
            Should -Throw '*must not move backwards*'
        (Get-Content (Join-Path $fixture 'VERSION') -Raw).Trim() |
            Should -Be '1.4.20261016.2'
    }
}
