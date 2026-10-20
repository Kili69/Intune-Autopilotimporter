# Project-Version: 1.4.20261020.15
# Author: andreas.lucas@outlook.com (aka Kili)

Import-Module (Join-Path $PSScriptRoot '..\FunctionApp\src\AutopilotImport\AutopilotImport.psm1') -Force

Describe 'Permanent management audit storage' {
    InModuleScope AutopilotImport {
        BeforeEach {
            $principal = @{ claims = @(
                @{ typ = 'oid'; val = '11111111-1111-1111-1111-111111111111' }
                @{ typ = 'preferred_username'; val = 'manager@example.test' }
            ) }
            $operation = [guid]::NewGuid()
            $bodies = [Collections.Generic.List[object]]::new()
            $secure = ConvertTo-SecureString 'storage' -AsPlainText -Force
            Mock Get-ImportAuditTableUri { 'https://test.table.core.windows.net/importaudit' }
            Mock Get-ImportAuditAccessToken { $secure }
            Mock Invoke-RestMethod {
                param($Body)
                if ($Body) { $bodies.Add(($Body | ConvertFrom-Json)) }
            }
        }
        It 'only inserts immutable events into a non-import partition' {
            Write-ManagementAuditEvent -Kind policies -OperationId $operation -Stage requested `
                -Principal $principal -Before @(@{ description = 'Old' }) -After @(@{ description = 'New' })
            Write-ManagementAuditEvent -Kind policies -OperationId $operation -Stage applied -Principal $principal
            $bodies.Count | Should -Be 2
            $bodies[0].PartitionKey | Should -Be 'management-policies'
            $bodies[0].RowKey | Should -Not -Be $bodies[1].RowKey
            $event = $bodies[0].payload0 | ConvertFrom-Json
            $event.before[0].description | Should -Be 'Old'
            $event.after[0].description | Should -Be 'New'
            $event.actorId | Should -Be '11111111-1111-1111-1111-111111111111'
            $event.actorName | Should -Be 'manager@example.test'
            $event.operationId | Should -Be $operation.ToString()
            Should -Invoke Invoke-RestMethod -Times 2 -ParameterFilter { $Method -eq 'Post' }
            Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { $Method -in @('Merge','Put','Delete') }
        }
        It 'chunks a payload below Table property limits without losing values' {
            $text = 'x' * 50000
            Write-ManagementAuditEvent -Kind managers -OperationId $operation -Stage requested `
                -Principal $principal -Before @{} -After @{ text = $text }
            $body = $bodies[0]
            $body.chunks | Should -BeGreaterThan 1
            $json = ''
            for ($i = 0; $i -lt $body.chunks; $i++) {
                $body."payload$i".Length | Should -BeLessOrEqual 15000
                $json += $body."payload$i"
            }
            ($json | ConvertFrom-Json).after.text | Should -BeExactly $text
        }
        It 'rejects oversized snapshots before contacting storage' {
            { Write-ManagementAuditEvent -Kind policies -OperationId $operation -Stage requested `
                -Principal $principal -Before @{} -After @{ text = 'x' * 351000 } } | Should -Throw '*size*'
            Should -Invoke Invoke-RestMethod -Times 0
        }
        It 'does not split Unicode surrogate pairs between stored string properties' {
            $text = [char]::ConvertFromUtf32(0x1F600) * 16000
            Write-ManagementAuditEvent -Kind policies -OperationId $operation -Stage requested `
                -Principal $principal -Before @{} -After @{ text = $text }
            $json = ''
            for ($i = 0; $i -lt $bodies[0].chunks; $i++) {
                $chunk = $bodies[0]."payload$i"
                [char]::IsHighSurrogate($chunk[$chunk.Length - 1]) | Should -BeFalse
                [char]::IsLowSurrogate($chunk[0]) | Should -BeFalse
                $json += $chunk
            }
            ($json | ConvertFrom-Json).after.text | Should -BeExactly $text
        }
        It 'propagates insertion failures without merging or overwriting history' {
            Mock Invoke-RestMethod { throw 'Insert failed' }
            { Write-ManagementAuditEvent -Kind managers -OperationId $operation -Stage requested `
                -Principal $principal -Before @{} -After @{} } | Should -Throw 'Insert failed'
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { $Method -eq 'Post' }
        }
        It 'reads bounded newest-first history without applying import retention' {
            $payload = @{ operationId = $operation; stage = 'requested'; before = @{}; after = @{} } | ConvertTo-Json -Compress
            Mock Invoke-RestMethod {
                @{ value = @(@{ PartitionKey = 'management-managers'; chunks = 1; payload0 = $payload }) }
            }
            $result = Get-ManagementAuditHistory -Kind managers
            $result.events.Count | Should -Be 1
            $result.events[0].stage | Should -Be 'requested'
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Method -eq 'Get' -and $Uri -match 'management-managers' -and
                $Uri -match '\$top=25' -and $Uri -notmatch 'Since|requestReceivedAtUtc'
            }
        }
        It 'validates continuation tokens instead of accepting arbitrary filters' {
            { Get-ManagementAuditHistory -Kind policies -Continuation "' or true" } | Should -Throw '*continuation*'
            Should -Invoke Invoke-RestMethod -Times 0
        }
        It 'continues only within the server-selected history partition' {
            Mock Invoke-RestMethod { @{ value = @() } }
            $next = '0000000000000000001-11111111-1111-1111-1111-111111111111'
            Get-ManagementAuditHistory -Kind policies -Continuation $next | Out-Null
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Uri -like '*NextPartitionKey=management-policies*NextRowKey=0000000000000000001-*'
            }
        }
            It 'returns only changed snapshots of the selected rule, including confirmations' {
                $id = '22222222-2222-2222-2222-222222222222'
                $before = @(
                    @{ ruleId = $id; groupId = '11111111-1111-1111-1111-111111111111'; name = 'Sales'; tags = @('Sales'); description = 'Before' }
                    @{ groupId = '33333333-3333-3333-3333-333333333333'; tags = @('Secret unrelated') }
                )
                $after = @($before[0].Clone(), $before[1].Clone())
                $after[0].name = 'Renamed'
                $after[0].description = 'After'
                $after[1].tags = @('Changed unrelated')
                $payload = @{ operationId = $operation; stage = 'applied'; before = $before; after = $after } | ConvertTo-Json -Depth 10 -Compress
                Mock Invoke-RestMethod {
                    @{ value = @(@{ PartitionKey = 'management-policies'; chunks = 1; payload0 = $payload }) }
                }
                $page = Get-ManagementAuditHistory -Kind policies -RuleId $id
                $page.events.Count | Should -Be 1
                $page.events[0].before.name | Should -Be 'Sales'
                $page.events[0].after.name | Should -Be 'Renamed'
                $page.events[0].stage | Should -Be 'applied'
                ($page | ConvertTo-Json -Depth 10) | Should -Not -Match 'unrelated'
            }
            It 'omits events changing other rules or merely adding the legacy rule ID' {
                $rule = @{ groupId = '11111111-1111-1111-1111-111111111111'; tags = @('Sales') }
                $id = Get-TagPolicyRuleId $rule
                $normalized = ConvertTo-TagAuthorizationPolicy -Rules @($rule)
                $payload = @{ stage = 'requested'; before = @($rule); after = @($normalized) } | ConvertTo-Json -Depth 10 -Compress
                Mock Invoke-RestMethod {
                    @{ value = @(@{ PartitionKey = 'management-policies'; chunks = 1; payload0 = $payload }) }
                }
                (Get-ManagementAuditHistory -Kind policies -RuleId $id).events.Count | Should -Be 0
                (Get-ManagementAuditHistory -Kind policies -RuleId '33333333-3333-3333-3333-333333333333').events.Count | Should -Be 0
            }
            It 'recognizes historical pre-ID rule snapshots and rule deletion' {
                $rule = @{ groupId = '11111111-1111-1111-1111-111111111111'; name = 'Sales'; tags = @('Sales') }
                $payload = @{ stage = 'requested'; before = @($rule); after = @() } | ConvertTo-Json -Depth 10 -Compress
                Mock Invoke-RestMethod {
                    @{ value = @(@{ PartitionKey = 'management-policies'; chunks = 1; payload0 = $payload }) }
                }
                $page = Get-ManagementAuditHistory -Kind policies -RuleId (Get-TagPolicyRuleId $rule)
                $page.events.Count | Should -Be 1
                $page.events[0].before.name | Should -Be 'Sales'
                $page.events[0].after | Should -BeNullOrEmpty
            }
        It 'never includes management partitions in the import cleanup query' {
            Mock Invoke-RestMethod { @{ value = @() } }
            Remove-ExpiredImportAuditRecords -BeforeUtc ([datetimeoffset]::UtcNow) -AccessToken $secure | Out-Null
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Method -eq 'Get' -and [uri]::UnescapeDataString($Uri) -like "*PartitionKey eq 'imports'*"
            }
            Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { $Method -eq 'Delete' }
        }
    }
}

Describe 'Synchronous audited policy persistence' {
    InModuleScope AutopilotImport {
        BeforeEach {
            $savedAccount = $env:AzureWebJobsStorage__accountName
            $savedPolicy = $env:TAG_AUTHORIZATION_POLICY
            $env:AzureWebJobsStorage__accountName = 'test'
            $env:TAG_AUTHORIZATION_POLICY = '[{"groupId":"11111111-1111-1111-1111-111111111111","tags":["Old"]}]'
            Mock Get-ImportAuditAccessToken { ConvertTo-SecureString 'storage' -AsPlainText -Force }
            Mock Invoke-WebRequest { @{ Content = $env:TAG_AUTHORIZATION_POLICY; Headers = @{ ETag = '"etag1"' } } }
            Mock Invoke-RestMethod {}
        }
        AfterEach {
            $env:AzureWebJobsStorage__accountName = $savedAccount
            $env:TAG_AUTHORIZATION_POLICY = $savedPolicy
        }
        It 'writes using the current ETag and UTF-8 JSON bytes' {
            Set-ManagementPolicyBlob -ExpectedJson $env:TAG_AUTHORIZATION_POLICY -Json '{"description":"Büro"}'
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Method -eq 'Put' -and $Headers['If-Match'] -eq '"etag1"' -and
                $Headers['x-ms-blob-type'] -eq 'BlockBlob' -and
                [Text.Encoding]::UTF8.GetString($Body) -eq '{"description":"Büro"}'
            }
        }
        It 'rejects a concurrent policy change without overwriting it' {
            Mock Invoke-WebRequest { @{ Content = '[{"groupId":"11111111-1111-1111-1111-111111111111","tags":["Changed"]}]'; Headers = @{ ETag = '"etag2"' } } }
            { Set-ManagementPolicyBlob -ExpectedJson $env:TAG_AUTHORIZATION_POLICY -Json new } | Should -Throw '*changed*'
            Should -Invoke Invoke-RestMethod -Times 0
        }
        It 'creates an absent blob conditionally using the deployment fallback' {
            Mock Invoke-WebRequest {
                $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::NotFound)
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Not found', $response)
            }
            Set-ManagementPolicyBlob -ExpectedJson $env:TAG_AUTHORIZATION_POLICY -Json new
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { $Headers['If-None-Match'] -eq '*' }
        }
        It 'creates the first rule conditionally from an empty deployment fallback' {
            $env:TAG_AUTHORIZATION_POLICY = '[]'
            Mock Invoke-WebRequest {
                $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::NotFound)
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Not found', $response)
            }
            $firstRule = '[{"name":"First","groupId":"11111111-1111-1111-1111-111111111111","groupTag":"Sales"}]'
            Set-ManagementPolicyBlob -ExpectedJson '[]' -Json $firstRule
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Headers['If-None-Match'] -eq '*' -and
                [Text.Encoding]::UTF8.GetString($Body) -eq $firstRule
            }
        }
        It 'updates an explicitly empty blob using its ETag instead of stale legacy rules' {
            Mock Invoke-WebRequest { @{ Content = '[]'; Headers = @{ ETag = '"empty"' } } }
            Set-ManagementPolicyBlob -ExpectedJson '[]' -Json new
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { $Headers['If-Match'] -eq '"empty"' }
        }
        It 'rejects a concurrent first rule without overwriting it' {
            { Set-ManagementPolicyBlob -ExpectedJson '[]' -Json new } | Should -Throw '*changed*'
            Should -Invoke Invoke-RestMethod -Times 0
        }
        It 'propagates storage authorization failures without writing' {
            Mock Invoke-WebRequest { throw 'Storage unavailable' }
            { Set-ManagementPolicyBlob -ExpectedJson old -Json new } | Should -Throw 'Storage unavailable'
            Should -Invoke Invoke-RestMethod -Times 0
        }
        It 'accepts binding reserialization and trailing newline without losing ETag protection' {
            Mock Invoke-WebRequest {
                @{ Content = "[{`"tags`": [`"Old`"], `"groupId`": `"11111111-1111-1111-1111-111111111111`"}]`r`n"; Headers = @{ ETag = '"etag1"' } }
            }
            Set-ManagementPolicyBlob -ExpectedJson $env:TAG_AUTHORIZATION_POLICY -Json new
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { $Headers['If-Match'] -eq '"etag1"' }
        }
        It 'rejects an actual description change even with identical tags' {
            Mock Invoke-WebRequest {
                @{ Content = '[{"groupId":"11111111-1111-1111-1111-111111111111","tags":["Old"],"description":"Changed"}]'; Headers = @{ ETag = '"etag2"' } }
            }
            { Set-ManagementPolicyBlob -ExpectedJson $env:TAG_AUTHORIZATION_POLICY -Json new } | Should -Throw '*changed*'
            Should -Invoke Invoke-RestMethod -Times 0
        }
    }
}
