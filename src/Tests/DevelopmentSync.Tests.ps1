# Project-Version: 1.4.20261022.1
# Author: andreas.lucas@outlook.com (aka Kili)

BeforeAll {
    $syncScript = Join-Path $PSScriptRoot '..\Scripts\Sync-DevelopmentBranches.ps1'
}

Describe 'Dev synchronization pull requests' {
    BeforeEach {
        $savedToken = $env:GH_TOKEN
        $env:GH_TOKEN = 'unit-test-placeholder'
        $devSha = 'a' * 40
        $targetSha = 'b' * 40
        $branches = @(
            @{ name = 'main'; commit = @{ sha = $targetSha } }
            @{ name = 'dev'; commit = @{ sha = $devSha } }
            @{ name = 'feature/work'; commit = @{ sha = $targetSha } }
            @{ name = 'nextversion'; commit = @{ sha = $targetSha } }
            @{ name = 'sync/dev/generated'; commit = @{ sha = $devSha } }
            @{ name = 'sync/dev-to-nextversion'; commit = @{ sha = $devSha } }
        )
        $createdRefs = [Collections.Generic.List[object]]::new()
        $createdPrs = [Collections.Generic.List[object]]::new()
        Mock Invoke-RestMethod {
            param($Uri, $Method, $Body)
            if ($Uri -like '*/git/ref/heads/dev') { return @{ object = @{ sha = $devSha } } }
            if ($Uri -like '*/branches?*') { return $branches }
            if ($Uri -like '*/compare/*') { return @{ status = 'diverged' } }
            if ($Uri -like '*/git/ref/heads/sync/*') {
                $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::NotFound)
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Not found', $response)
            }
            if ($Uri -like '*/git/refs' -and $Method -eq 'POST') {
                $createdRefs.Add(($Body | ConvertFrom-Json))
                return @{ ref = 'created' }
            }
            if ($Uri -like '*/pulls?*') { return @() }
            if ($Uri -like '*/pulls' -and $Method -eq 'POST') {
                $createdPrs.Add(($Body | ConvertFrom-Json))
                return @{ html_url = 'https://github.com/owner/repo/pull/1' }
            }
            throw "Unexpected test API request: $Method $Uri"
        }
    }
    AfterEach { $env:GH_TOKEN = $savedToken }

    It 'opens PRs for every ordinary branch, including nextversion, but never modifies the targets' {
        $urls = @(& $syncScript -Repository owner/repo)
        $urls.Count | Should -Be 2
        $createdRefs.Count | Should -Be 2
        $createdPrs.base | Should -Contain 'feature/work'
        $createdPrs.base | Should -Contain 'nextversion'
        $createdRefs[0].ref | Should -Match '^refs/heads/sync/dev/[0-9a-f]{16}/a{40}$'
        $createdRefs[0].sha | Should -Be $devSha
        $createdRefs[0].ref | Should -Not -Be $createdRefs[1].ref
        Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { $Method -in @('PUT','PATCH','DELETE') }
    }
    It 'skips targets that already include dev' {
        Mock Invoke-RestMethod { @{ status = 'ahead' } } -ParameterFilter { $Uri -like '*/compare/*' }
        & $syncScript -Repository owner/repo
        $createdPrs.Count | Should -Be 0
        $createdRefs.Count | Should -Be 0
    }
    It 'reuses existing sync refs and PRs on rerun, even after manual conflict resolutions' {
        Mock Invoke-RestMethod { @{ object = @{ sha = 'c' * 40 } } } -ParameterFilter { $Uri -like '*/git/ref/heads/sync/*' }
        Mock Invoke-RestMethod { @(@{ html_url = 'https://github.com/owner/repo/pull/2' }) } -ParameterFilter { $Uri -like '*/pulls?*' }
        @(& $syncScript -Repository owner/repo).Count | Should -Be 2
        $createdRefs.Count | Should -Be 0
        $createdPrs.Count | Should -Be 0
        Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { $Method -ne 'GET' }
    }
    It 'never recreates a deliberately closed synchronization PR' {
        Mock Invoke-RestMethod { @(@{ state = 'closed'; html_url = 'https://github.com/owner/repo/pull/3' }) } -ParameterFilter { $Uri -like '*/pulls?*' }
        & $syncScript -Repository owner/repo
        $createdPrs.Count | Should -Be 0
        Should -Invoke Invoke-RestMethod -Times 2 -ParameterFilter { $Uri -like '*state=all*' }
    }
    It 'normalizes non-enumerated empty HTTP arrays instead of treating them as existing PRs' {
        Mock Invoke-RestMethod { Write-Output -NoEnumerate @() } -ParameterFilter { $Uri -like '*/pulls?*' }
        @(& $syncScript -Repository owner/repo).Count | Should -Be 2
        $createdPrs.Count | Should -Be 2
    }
    It 'follows branch pagination instead of silently omitting later branches' {
        Mock Invoke-RestMethod {
            if ($Uri -like '*page=2') { return @(@{ name = 'feature/later'; commit = @{ sha = $targetSha } }) }
            @(1..100 | ForEach-Object { @{ name = "sync/dev/$_"; commit = @{ sha = $devSha } } })
        } -ParameterFilter { $Uri -like '*/branches?*' }
        & $syncScript -Repository owner/repo
        $createdPrs.Count | Should -Be 1
        $createdPrs[0].base | Should -Be 'feature/later'
    }
    It 'surfaces API errors instead of interpreting them as missing refs' {
        Mock Invoke-RestMethod {
            $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::Forbidden)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Forbidden', $response)
        } -ParameterFilter { $Uri -like '*/git/ref/heads/sync/*' }
        Mock Write-Error {}
        { & $syncScript -Repository owner/repo } | Should -Throw '*Synchronization failed*'
        $createdRefs.Count | Should -Be 0
        $createdPrs.Count | Should -Be 0
        Should -Invoke Write-Error -Times 2
    }
    It 'requires explicit GitHub authentication' {
        $env:GH_TOKEN = ''
        { & $syncScript -Repository owner/repo } | Should -Throw '*GH_TOKEN*'
        Should -Invoke Invoke-RestMethod -Times 0
    }
}

Describe 'Protected promotion and release workflow wiring' {
    BeforeAll {
        $workflowRoot = Join-Path $PSScriptRoot '..\..\.github\workflows'
        $packageWorkflow = Get-Content (Join-Path $workflowRoot 'deployment-package.yml') -Raw
        $syncWorkflow = Get-Content (Join-Path $workflowRoot 'sync-dev-to-development.yml') -Raw
        $promotionWorkflow = Get-Content (Join-Path $workflowRoot 'enforce-dev-promotion.yml') -Raw
    }
    It 'validates pull requests and builds a downloadable ZIP before publishing only main pushes' {
        $packageWorkflow | Should -Match '(?s)pull_request:\s+branches:\s+- dev\s+- main'
        $packageWorkflow | Should -Match 'name: Validation and tests'
        $packageWorkflow | Should -Match 'npm run check'
        $packageWorkflow | Should -Match "if: github.event_name == 'push' && github.ref == 'refs/heads/main'"
        $packageWorkflow | Should -Match 'needs: package'
        $packageWorkflow | Should -Match 'contents: write'
        $packageWorkflow | Should -Match 'softprops/action-gh-release@v2'
        $packageWorkflow | Should -Match 'target_commitish: \$\{\{ github.sha \}\}'
        $packageWorkflow | Should -Match 'files: release/\*\.zip'
        $packageWorkflow | Should -Match 'Never overwrite a published version'
    }
    It 'uses protected dev code for sync without target checkouts or automatic merges' {
        $syncWorkflow | Should -Match "if: github.ref == 'refs/heads/dev'"
        $syncWorkflow | Should -Match 'Sync-DevelopmentBranches.ps1'
        $syncWorkflow | Should -Not -Match 'git merge|--force|auto-merge'
        $promotionWorkflow | Should -Not -Match 'nextversion may only'
        Test-Path (Join-Path $workflowRoot 'sync-dev-to-nextversion.yml') | Should -BeFalse
    }
}
