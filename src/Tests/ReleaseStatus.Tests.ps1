# Project-Version: 1.4.20261112.1
# Author: andreas.lucas@outlook.com (aka Kili)

Describe 'Central daily release check' {
    BeforeAll {
        function Push-OutputBinding { param($Name, $Value) }
        $check = Join-Path $PSScriptRoot '..\FunctionApp\CheckRelease\run.ps1'
    }
    BeforeEach {
        $release = @{
            tag_name = 'v1.4.20261112.1'
            draft = $false
            prerelease = $false
            assets = @(@{
                name = 'Intune-autopilotImporter-main1.4.20261112.1.zip'
                state = 'uploaded'
                size = 1234
                browser_download_url = 'https://github.com/Kili69/Intune-Autopilotimporter/releases/download/v1.4.20261112.1/Intune-autopilotImporter-main1.4.20261112.1.zip'
            })
        }
        Mock Push-OutputBinding {}
        Mock Write-Warning {}
        Mock Invoke-WebRequest {
            [pscustomobject]@{ StatusCode = 200; Content = ($release | ConvertTo-Json -Depth 6) }
        }
    }
    It 'persists a stable release only after its installation ZIP is uploaded' {
        & $check
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://api.github.com/repos/Kili69/Intune-Autopilotimporter/releases/latest' -and
            $TimeoutSec -eq 30
        }
        Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter {
            $result = $Value | ConvertFrom-Json
            $Name -eq 'ReleaseStatus' -and $result.status -eq 'available' -and
            $result.version -eq '1.4.20261112.1' -and
            $result.releaseUrl -eq 'https://github.com/Kili69/Intune-Autopilotimporter/releases/tag/v1.4.20261112.1' -and
            $result.checkedAtUtc
        }
    }
    It 'rejects <Name>' -ForEach @(
        @{ Name = 'a prerelease'; Field = 'prerelease'; Value = $true }
        @{ Name = 'a draft'; Field = 'draft'; Value = $true }
        @{ Name = 'a malformed tag'; Field = 'tag_name'; Value = 'main' }
        @{ Name = 'a release without a ZIP'; Field = 'assets'; Value = @() }
        @{ Name = 'an incomplete ZIP'; Field = 'assets'; Value = @(@{
            name = 'Intune-autopilotImporter-main1.4.20261112.1.zip'; state = 'new'; size = 0
        }) }
    ) {
        $release[$Field] = $Value
        & $check
        Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter {
            $result = $Value | ConvertFrom-Json
            $result.status -eq 'unavailable' -and $null -eq $result.version -and $result.checkedAtUtc
        }
        Should -Invoke Write-Warning -Times 1 -Exactly
    }
    It 'persists a failure rather than retrying GitHub for every browser request' {
        Mock Invoke-WebRequest { throw 'GitHub unavailable' }
        & $check
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter {
            ($Value | ConvertFrom-Json).status -eq 'unavailable'
        }
        Should -Invoke Write-Warning -Times 1 -Exactly
    }
    It 'records a GitHub rate limit as unavailable' {
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 403; Content = '' } }
        & $check
        Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter {
            ($Value | ConvertFrom-Json).status -eq 'unavailable'
        }
        Should -Invoke Write-Warning -Times 1 -Exactly
    }
    It 'rejects an asset outside the expected repository download URL' {
        $release.assets[0].browser_download_url = 'https://example.com/package.zip'
        & $check
        Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter {
            ($Value | ConvertFrom-Json).status -eq 'unavailable'
        }
        Should -Invoke Write-Warning -Times 1 -Exactly
    }
    It 'propagates storage output failures' {
        Mock Push-OutputBinding { throw 'Storage unavailable' }
        { & $check } | Should -Throw '*Storage unavailable*'
        Should -Invoke Write-Warning -Times 0
    }
    It 'records an empty release repository without treating it as an update' {
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 404; Content = '' } }
        & $check
        Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter {
            ($Value | ConvertFrom-Json).status -eq 'noRelease'
        }
        Should -Invoke Write-Warning -Times 0
    }
    It 'uses a monitored daily UTC timer without startup checks on scale-out' {
        $bindings = (Get-Content (Join-Path $PSScriptRoot '..\FunctionApp\CheckRelease\function.json') -Raw |
            ConvertFrom-Json).bindings
        $timer = $bindings | Where-Object type -eq timerTrigger
        $timer.schedule | Should -Be '0 0 0 * * *'
        $timer.useMonitor | Should -BeTrue
        $timer.runOnStartup | Should -BeFalse
    }
}

Describe 'Cached public release endpoint' {
    BeforeAll {
        if (-not ('HttpResponseContext' -as [type])) {
            Add-Type 'public class HttpResponseContext {
                public System.Net.HttpStatusCode StatusCode;
                public System.Collections.Hashtable Headers;
                public string Body;
            }'
        }
        Import-Module (Join-Path $PSScriptRoot '..\FunctionApp\src\AutopilotImport\AutopilotImport.psm1') -Force
        function Push-OutputBinding { param($Name, $Value) }
        $handler = Join-Path $PSScriptRoot '..\FunctionApp\GetReleaseStatus\run.ps1'
    }
    BeforeEach {
        Mock Import-Module {}
        Mock Push-OutputBinding {}
        Mock Invoke-WebRequest { throw 'The status endpoint must not call GitHub.' }
    }
    It 'returns pending before the first timer run' {
        & $handler -Request @{} -ReleaseStatusBlob $null
        Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter {
            $Value.StatusCode -eq 200 -and $Value.Headers['Cache-Control'] -eq 'no-store' -and
            ($Value.Body | ConvertFrom-Json).status -eq 'pending'
        }
        Should -Invoke Invoke-WebRequest -Times 0
    }
    It 'returns the shared stored result without a new GitHub lookup' {
        & $handler -Request @{} -ReleaseStatusBlob '{"status":"unavailable","checkedAtUtc":"2026-11-12T00:00:00Z"}'
        Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter {
            $Value.StatusCode -eq 200 -and ($Value.Body | ConvertFrom-Json).status -eq 'unavailable'
        }
        Should -Invoke Invoke-WebRequest -Times 0
    }
    It 'does not disguise corrupt stored JSON as a successful check' {
        { & $handler -Request @{} -ReleaseStatusBlob 'invalid' } | Should -Throw
        Should -Invoke Push-OutputBinding -Times 0
    }
}
