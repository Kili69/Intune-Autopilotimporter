# Project-Version: 1.4.20261019.6
# Author: andreas.lucas@outlook.com (aka Kili)

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutopilotImport.Client\AutopilotImport.Client.psd1') -Force
}

Describe 'PowerShell rule history API parity' {
    BeforeEach {
        $parameters = @{
            ManagementUrl = 'https://test.example/api/management/tag-policy'
            ApiApplicationIdUri = 'api://33333333-3333-3333-3333-333333333333'
            TenantId = '44444444-4444-4444-4444-444444444444'
        }
        $id = '11111111-1111-1111-1111-111111111111'
        Mock Get-ClientAccessToken -ModuleName AutopilotImport.Client {
            ConvertTo-SecureString 'api' -AsPlainText -Force
        }
        Mock Invoke-RestMethod -ModuleName AutopilotImport.Client {
            [pscustomobject]@{ events = @([pscustomobject]@{
                operationId = 'operation'; stage = 'applied'; actorId = 'actor'
                before = @{ description = 'Before' }; after = @{ description = 'After' }
            }); continuation = '' }
        }
    }
    It 'exports the rule history command and requests only the selected rule' {
        $page = Get-AutoPilotTagPolicyHistory @parameters -RuleId $id
        $page.events.Count | Should -Be 1
        $page.events[0].after.description | Should -Be 'After'
        Should -Invoke Invoke-RestMethod -ModuleName AutopilotImport.Client -Times 1 -ParameterFilter {
            $Method -eq 'Get' -and $Uri -eq "https://test.example/api/management/tag-policy?history=true&ruleId=$id"
        }
        Should -Invoke Get-ClientAccessToken -ModuleName AutopilotImport.Client -Times 1 -ParameterFilter {
            $ResourceUrl -notlike '*graph*'
        }
    }
    It 'forwards pagination without changing the rule ID' {
        $next = '0000000000000000001-22222222-2222-2222-2222-222222222222'
        Get-AutoPilotTagPolicyHistory @parameters -RuleId $id -Continuation $next | Out-Null
        Should -Invoke Invoke-RestMethod -ModuleName AutopilotImport.Client -Times 1 -ParameterFilter {
            $Uri -eq "https://test.example/api/management/tag-policy?history=true&ruleId=$id&continuation=$next"
        }
    }
    It 'rejects empty IDs and invalid pagination before any request' {
        { Get-AutoPilotTagPolicyHistory @parameters -RuleId ([guid]::Empty) } | Should -Throw
        { Get-AutoPilotTagPolicyHistory @parameters -RuleId $id -Continuation "' or true" } | Should -Throw
        Should -Invoke Invoke-RestMethod -ModuleName AutopilotImport.Client -Times 0
    }
    It 'propagates authorization and server failures rather than returning an empty history' {
        Mock Invoke-RestMethod -ModuleName AutopilotImport.Client { throw 'Forbidden' }
        { Get-AutoPilotTagPolicyHistory @parameters -RuleId $id } | Should -Throw 'Forbidden'
    }
    It 'exposes persistent IDs and descriptions in the normal policy output' {
        Mock Invoke-RestMethod -ModuleName AutopilotImport.Client {
            if ($Uri -like '*graph.microsoft.com*') { return [pscustomobject]@{ displayName = 'Sales group' } }
            [pscustomobject]@{
                policy = @([pscustomobject]@{ ruleId = $id; name = 'Sales'; description = "Line 1`nLine 2"; groupId = $id; tags = @('Sales') })
                correlationId = 'test'
            }
        }
        $rule = Get-AutoPilotTagPolicy @parameters
        $rule.ruleId | Should -Be $id
        $rule.description | Should -BeExactly "Line 1`nLine 2"
    }
}
