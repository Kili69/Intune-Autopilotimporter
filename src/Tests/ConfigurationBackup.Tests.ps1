# Project-Version: 1.4.20261022.1
# Author: andreas.lucas@outlook.com (aka Kili)

BeforeAll {
    Remove-Module AutopilotImport.Client -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $PSScriptRoot '..\AutopilotImport.Client\AutopilotImport.Client.psd1') -Force
}

Describe 'Configuration backup client' {
    Context 'JSON file operations' {
        BeforeEach {
            $path = Join-Path $TestDrive "backup-$([guid]::NewGuid()).json"
            $backup = @{
                format = 'autopilot-importer-configuration'; schemaVersion = 1
                tenantId = '11111111-1111-1111-1111-111111111111'
                rules = @(@{ ruleId = '22222222-2222-2222-2222-222222222222'; description = "Line one`nLine two" })
                managerPolicy = @{ installerPrincipalId = '33333333-3333-3333-3333-333333333333'; additionalPrincipalIds = @() }
            }
            $arguments = @{
                ManagementUrl = 'https://custom.example/api/management/tag-policy'
                ApiApplicationIdUri = 'api://test'
                TenantId = $backup.tenantId
            }
            Mock Get-ClientAccessToken -ModuleName AutopilotImport.Client { ConvertTo-SecureString 'token' -AsPlainText -Force }
            Mock Invoke-RestMethod -ModuleName AutopilotImport.Client {
                param($Method)
                if ($Method -eq 'Put') { return @{ restored = $true; rulesState = 'applied'; managersState = 'applied' } }
                @{ backup = $backup; expectedPolicy = '{"current":true}'; expectedRules = @() }
            }
        }
        It 'exports a standalone JSON snapshot and uses API and ARM authentication on a custom hostname' {
            $file = Export-AutoPilotConfiguration -Path $path @arguments
            $file.FullName | Should -Be $path
            $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $json.format | Should -Be 'autopilot-importer-configuration'
            $json.rules[0].description | Should -Be "Line one`nLine two"
            $json.PSObject.Properties.Name | Should -Not -Contain 'expectedPolicy'
            Should -Invoke Get-ClientAccessToken -ModuleName AutopilotImport.Client -Times 1 -ParameterFilter { $ResourceUrl -eq 'https://management.azure.com/' }
            Should -Invoke Invoke-RestMethod -ModuleName AutopilotImport.Client -Times 1 -ParameterFilter {
                $Method -eq 'Get' -and $Uri -eq 'https://custom.example/api/management/policy-managers?backup=true' -and
                $Headers['x-autopilot-arm-token'] -eq 'token' -and $Authentication -eq 'Bearer'
            }
        }
        It 'never overwrites an existing backup without Force' {
            Set-Content -LiteralPath $path -Value 'existing'
            { Export-AutoPilotConfiguration -Path $path @arguments } | Should -Throw '*already exists*'
            (Get-Content -LiteralPath $path -Raw).Trim() | Should -Be 'existing'
            Should -Invoke Invoke-RestMethod -ModuleName AutopilotImport.Client -Times 0
            Export-AutoPilotConfiguration -Path $path -Force @arguments
            (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).format | Should -Be $backup.format
        }
        It 'does not create a file when the API fails or returns no backup' {
            Mock Invoke-RestMethod -ModuleName AutopilotImport.Client { @{} }
            { Export-AutoPilotConfiguration -Path $path @arguments } | Should -Throw '*supported configuration backup*'
            Test-Path -LiteralPath $path | Should -BeFalse
        }
        It 'restores through the target API with fresh concurrency values and unchanged backup content' {
            ConvertTo-Json -InputObject $backup -Depth 20 | Set-Content -LiteralPath $path
            $result = Restore-AutoPilotConfiguration -Path $path @arguments -Confirm:$false
            $result.restored | Should -BeTrue
            Should -Invoke Invoke-RestMethod -ModuleName AutopilotImport.Client -Times 1 -ParameterFilter {
                $Method -eq 'Put' -and
                ([Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json).expectedPolicy -eq '{"current":true}' -and
                ([Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json).backup.rules[0].description -eq "Line one`nLine two"
            }
        }
        It 'supports WhatIf without network calls or file creation' {
            Export-AutoPilotConfiguration -Path $path @arguments -WhatIf
            Test-Path -LiteralPath $path | Should -BeFalse
            ConvertTo-Json -InputObject $backup -Depth 20 | Set-Content -LiteralPath $path
            Restore-AutoPilotConfiguration -Path $path @arguments -WhatIf
            Should -Invoke Invoke-RestMethod -ModuleName AutopilotImport.Client -Times 0
            Should -Invoke Get-ClientAccessToken -ModuleName AutopilotImport.Client -Times 0
        }
        It 'rejects malformed input before authentication or mutation' {
            Set-Content -LiteralPath $path -Value '{}'
            { Restore-AutoPilotConfiguration -Path $path @arguments -Confirm:$false } | Should -Throw '*supported configuration backup*'
            Should -Invoke Get-ClientAccessToken -ModuleName AutopilotImport.Client -Times 0
        }
        It 'does not PUT when the target omits concurrency values' {
            ConvertTo-Json -InputObject $backup -Depth 20 | Set-Content -LiteralPath $path
            Mock Invoke-RestMethod -ModuleName AutopilotImport.Client { @{ backup = $backup } }
            { Restore-AutoPilotConfiguration -Path $path @arguments -Confirm:$false } | Should -Throw '*concurrency*'
            Should -Invoke Invoke-RestMethod -ModuleName AutopilotImport.Client -Times 0 -ParameterFilter { $Method -eq 'Put' }
        }
        It 'propagates partial-restore API errors rather than reporting success' {
            ConvertTo-Json -InputObject $backup -Depth 20 | Set-Content -LiteralPath $path
            Mock Invoke-RestMethod -ModuleName AutopilotImport.Client { throw 'configurationRestoreFailed: rules applied, managers unconfirmed' } -ParameterFilter { $Method -eq 'Put' }
            { Restore-AutoPilotConfiguration -Path $path @arguments -Confirm:$false } | Should -Throw '*configurationRestoreFailed*'
        }
        It 'requires explicit complete-restore confirmation in the response' {
            ConvertTo-Json -InputObject $backup -Depth 20 | Set-Content -LiteralPath $path
            Mock Invoke-RestMethod -ModuleName AutopilotImport.Client { @{ restored = $false } } -ParameterFilter { $Method -eq 'Put' }
            { Restore-AutoPilotConfiguration -Path $path @arguments -Confirm:$false } | Should -Throw '*did not confirm*'
        }
        It 'rejects URLs with query parameters before obtaining tokens' {
            $arguments.ManagementUrl = 'https://custom.example/?unexpected=true'
            { Export-AutoPilotConfiguration -Path $path @arguments } | Should -Throw '*ManagementUrl*'
            Should -Invoke Get-ClientAccessToken -ModuleName AutopilotImport.Client -Times 0
        }
    }
}
