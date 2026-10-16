# Project-Version: 1.4.20261016.4
# Author: andreas.lucas@outlook.com (aka Kili)

Import-Module (Join-Path $PSScriptRoot '..\FunctionApp\src\AutopilotImport\AutopilotImport.psm1') -Force

Describe 'Named device policy normalization' {
    BeforeEach {
        $rule = @{
            name = 'Sales'
            groupId = '11111111-1111-1111-1111-111111111111'
            groupTag = 'Sales'
        }
    }
    It 'fills in a missing scope tag from the group tag' {
        $policy = ConvertTo-TagAuthorizationPolicy -Rules @($rule)
        $policy[0].name | Should -Be 'Sales'
        $policy[0].scopeTag | Should -Be 'Sales'
        $policy[0].tags | Should -Be @('Sales')
        @($policy[0].extensionAttributes.Keys).Count | Should -Be 0
    }
    It 'fills in a missing group tag from a scope tag' {
        $rule.Remove('groupTag')
        $rule.scopeTag = 'Operations'
        $policy = ConvertTo-TagAuthorizationPolicy -Rules @($rule)
        $policy[0].groupTag | Should -Be 'Operations'
        $policy[0].tags | Should -Be @('Operations')
    }
    It 'requires a name and at least one tag' {
        $rule.name = ''
        { ConvertTo-TagAuthorizationPolicy -Rules @($rule) } | Should -Throw '*name*'
        $rule.name = 'Sales'
        $rule.groupTag = ''
        { ConvertTo-TagAuthorizationPolicy -Rules @($rule) } | Should -Throw '*At least one*'
    }
    It 'round-trips multiple attribute values and target groups through JSON' {
        $rule.extensionAttributes = @{ extensionAttribute1 = 'Sales'; extensionAttribute5 = 'Berlin' }
        $rule.deviceGroupIds = @('22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333')
        $policy = ConvertTo-TagAuthorizationPolicy -Rules @($rule)
        $json = ConvertTo-Json -InputObject @($policy) -Depth 8 -Compress
        $result = ConvertTo-TagAuthorizationPolicy -Rules @($json | ConvertFrom-Json)
        $result[0].extensionAttributes.extensionAttribute1 | Should -Be 'Sales'
        $result[0].extensionAttributes.extensionAttribute5 | Should -Be 'Berlin'
        $result[0].deviceGroupIds.Count | Should -Be 2
    }
    It 'supports distinct named rules for the same authorized user group' {
        $other = $rule.Clone()
        $other.name = 'Engineering'
        $other.groupTag = 'Engineering'
        $result = ConvertTo-TagAuthorizationPolicy -Rules @($rule, $other)
        $result.Count | Should -Be 2
        $result.tags | Should -Contain 'Sales'
        $result.tags | Should -Contain 'Engineering'
    }
    It 'rejects invalid attribute names and non-string values' -ForEach @(
        @{ Attributes = @{ extensionAttribute16 = 'bad' } }
        @{ Attributes = @{ extensionAttribute1 = 42 } }
        @{ Attributes = @{ extensionAttribute1 = ('x' * 1025) } }
        @{ Attributes = @{ extensionAttribute1 = "A`nB" } }
        @{ Attributes = @{ extensionAttribute1 = "A`rB" } }
        @{ Attributes = @{ extensionAttribute1 = "A`tB" } }
        @{ Attributes = @{ extensionAttribute1 = "A`0B" } }
        @{ Attributes = @{ extensionAttribute1 = "A$([char]0x7f)B" } }
        @{ Attributes = @{ extensionAttribute1 = "A$([char]0x85)B" } }
        @{ Attributes = @{ extensionAttribute1 = "A$([char]0x2028)B" } }
        @{ Attributes = @{ extensionAttribute1 = "A$([char]0x2029)B" } }
    ) {
        $rule.extensionAttributes = $Attributes
        { ConvertTo-TagAuthorizationPolicy -Rules @($rule) } | Should -Throw '*Extension attributes*'
    }
    It 'rejects non-GUID and empty target groups' -ForEach @(
        @{ Group = 'not-a-guid' }
        @{ Group = '00000000-0000-0000-0000-000000000000' }
    ) {
        $rule.deviceGroupIds = @($Group)
        { ConvertTo-TagAuthorizationPolicy -Rules @($rule) } | Should -Throw '*non-empty GUID*'
    }
    It 'accepts exact-length, empty and Unicode single-line attribute values' {
        $rule.extensionAttributes = @{
            extensionAttribute1 = 'x' * 1024
            extensionAttribute2 = ''
            extensionAttribute3 = "M$([char]0xfc)nchen & $([char]0x6771)$([char]0x4eac) / IT = $([char]::ConvertFromUtf32(0x1f600))"
        }
        $policy = ConvertTo-TagAuthorizationPolicy -Rules @($rule)
        $policy[0].extensionAttributes.extensionAttribute1.Length | Should -Be 1024
        $policy[0].extensionAttributes.extensionAttribute2 | Should -Be ''
        $policy[0].extensionAttributes.extensionAttribute3 | Should -Be $rule.extensionAttributes.extensionAttribute3
    }
    It 'rejects conflicting actions for the same group tag' {
        $other = $rule.Clone()
        $other.groupId = '22222222-2222-2222-2222-222222222222'
        $other.scopeTag = 'Other'
        $policy = ConvertTo-TagAuthorizationPolicy -Rules @($rule, $other)
        { Get-DevicePolicyActions -Policy $policy -GroupTag 'Sales' } | Should -Throw '*conflicting device actions*'
    }
    It 'migrates legacy names without enabling new scope/group actions' {
        $policy = ConvertTo-TagAuthorizationPolicy -Rules @('11111111-1111-1111-1111-111111111111=Sales,Shared')
        $policy[0].name | Should -Be 'Policy 11111111-1111-1111-1111-111111111111'
        $policy[0].tags.Count | Should -Be 2
        $policy[0].PSObject.Properties.Name | Should -Not -Contain 'scopeTag'
    }
}

Describe 'Device policy Graph actions' {
    InModuleScope AutopilotImport {
        BeforeEach {
            $token = ConvertTo-SecureString test -AsPlainText -Force
            $device = [guid]'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            $target = '22222222-2222-2222-2222-222222222222'
            $old = '33333333-3333-3333-3333-333333333333'
            $unmanaged = '44444444-4444-4444-4444-444444444444'
        }
        It 'rejects dynamic, synchronized, non-security and role-assignable target groups' -ForEach @(
            @{ Security = $true; Types = @('DynamicMembership'); Synced = $false; Role = $false }
            @{ Security = $true; Types = @(); Synced = $true; Role = $false }
            @{ Security = $false; Types = @(); Synced = $false; Role = $false }
            @{ Security = $true; Types = @(); Synced = $false; Role = $true }
        ) {
            Mock Invoke-RestMethod {
                [pscustomobject]@{ id = $target; securityEnabled = $Security; groupTypes = $Types; onPremisesSyncEnabled = $Synced; isAssignableToRole = $Role }
            }
            { Assert-DevicePolicyGroups -GroupIds @($target) -AccessToken $token } | Should -Throw '*static*security group*'
        }
        It 'adds new target membership and removes only managed memberships' {
            Mock Assert-DevicePolicyGroups {}
            Mock Get-PolicyGraphCollection {
                @([pscustomobject]@{ id = $old }, [pscustomobject]@{ id = $unmanaged })
            }
            Mock Invoke-RestMethod {}
            Sync-DevicePolicyGroups -Policy @([pscustomobject]@{ deviceGroupIds = @($target) }) `
                -PreviousGroupIds @($old) -TargetGroupIds @($target) -DeviceObjectId $device -AccessToken $token
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'Post' -and $Uri -eq "https://graph.microsoft.com/v1.0/groups/$target/members/`$ref"
            }
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'Delete' -and $Uri -eq "https://graph.microsoft.com/v1.0/groups/$old/members/$device/`$ref"
            }
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -like "*$unmanaged*" }
        }
        It 'does not add an existing membership again' {
            Mock Assert-DevicePolicyGroups {}
            Mock Get-PolicyGraphCollection { [pscustomobject]@{ id = $target } }
            Mock Invoke-RestMethod {}
            Sync-DevicePolicyGroups -Policy @([pscustomobject]@{ deviceGroupIds = @($target) }) `
                -TargetGroupIds @($target) -DeviceObjectId $device -AccessToken $token
            Should -Invoke Invoke-RestMethod -Times 0
        }
        It 'creates a missing scope tag only when explicitly requested' {
            Mock Get-PolicyGraphCollection { @() }
            Mock Invoke-RestMethod { [pscustomobject]@{ id = '7'; displayName = 'Sales' } }
            { Resolve-PolicyScopeTag -Name Sales -AccessToken $token } | Should -Throw '*was not found*'
            (Resolve-PolicyScopeTag -Name Sales -AccessToken $token -Create).id | Should -Be '7'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'Post' -and ($Body | ConvertFrom-Json).displayName -eq 'Sales'
            }
        }
        It 'reuses an existing scope tag and rejects duplicate names' {
            Mock Get-PolicyGraphCollection { [pscustomobject]@{ id = '7'; displayName = 'Sales' } }
            Mock Invoke-RestMethod {}
            (Resolve-PolicyScopeTag -Name Sales -AccessToken $token -Create).id | Should -Be '7'
            Should -Invoke Invoke-RestMethod -Times 0
            Mock Get-PolicyGraphCollection { @([pscustomobject]@{ id = '7'; displayName = 'Sales' }, [pscustomobject]@{ id = '8'; displayName = 'Sales' }) }
            { Resolve-PolicyScopeTag -Name Sales -AccessToken $token -Create } | Should -Throw '*ambiguous*'
        }
        It 'leaves scope processing pending before enrollment without writing Graph' {
            Mock Get-PolicyGraphCollection { @() }
            Mock Invoke-RestMethod {}
            Set-DevicePolicyScopeTag -EntraDeviceId $device -ScopeTag Sales -AccessToken $token | Should -BeFalse
            Should -Invoke Invoke-RestMethod -Times 0
        }
        It 'replaces only policy-managed scope tags on all matching managed devices' {
            Mock Get-PolicyGraphCollection {
                if ($Uri -like '*managedDevices*') {
                    [pscustomobject]@{ id = 'managed-1'; roleScopeTagIds = @('2', '99') }
                } else {
                    @([pscustomobject]@{ id = '2'; displayName = 'Old' }, [pscustomobject]@{ id = '7'; displayName = 'Sales' })
                }
            }
            Mock Resolve-PolicyScopeTag { [pscustomobject]@{ id = '7' } }
            Mock Invoke-RestMethod {}
            Set-DevicePolicyScopeTag -EntraDeviceId $device -ScopeTag Sales -ManagedScopeTagNames @('Old', 'Sales') `
                -AccessToken $token | Should -BeTrue
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'Patch' -and
                ($Body | ConvertFrom-Json).roleScopeTagIds.Count -eq 2 -and
                '7' -in ($Body | ConvertFrom-Json).roleScopeTagIds -and
                '99' -in ($Body | ConvertFrom-Json).roleScopeTagIds
            }
        }
        It 'propagates Graph failures rather than reporting success' {
            Mock Get-PolicyGraphCollection { throw 'Graph unavailable' }
            { Set-DevicePolicyScopeTag -EntraDeviceId $device -ScopeTag Sales -AccessToken $token } |
                Should -Throw '*Graph unavailable*'
        }
        It 'paginates group collections' {
            Mock Invoke-RestMethod {
                if ($Uri -eq 'https://graph.microsoft.com/v1.0/groups') {
                    [pscustomobject]@{ value = @([pscustomobject]@{ id = '1' }); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/groups?page=2' }
                } else { [pscustomobject]@{ value = @([pscustomobject]@{ id = '2' }) } }
            }
            $result = @(Get-PolicyGraphCollection -Uri 'https://graph.microsoft.com/v1.0/groups' -AccessToken $token)
            $result.Count | Should -Be 2
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly
        }
        It 'keeps enrollment-pending records until a managed device exists' {
            Mock Get-ImportAuditTableUri { 'https://test.table.core.windows.net/importaudit' }
            Mock Invoke-RestMethod {
                [pscustomobject]@{ value = @([pscustomobject]@{
                    RowKey = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                    entraDeviceId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
                    scopeTagName = 'Sales'
                    managedScopeTagNamesJson = '["Sales"]'
                }) }
            }
            Mock Set-DevicePolicyScopeTag { $false }
            Mock Set-ImportAuditRecord {}
            Complete-PendingDeviceScopeTags -AccessToken $token -AuditToken $token
            Should -Invoke Set-ImportAuditRecord -Times 0
            Mock Set-DevicePolicyScopeTag { $true }
            Complete-PendingDeviceScopeTags -AccessToken $token -AuditToken $token
            Should -Invoke Set-ImportAuditRecord -Times 1 -Exactly -ParameterFilter {
                $Properties.scopeTagStatus -eq 'complete' -and $Properties.scopeTagUpdatedAtUtc
            }
        }
        It 'does not delete pending enrollment audit records after normal retention' {
            Mock Get-ImportAuditTableUri { 'https://test.table.core.windows.net/importaudit' }
            Mock Invoke-RestMethod {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ RowKey = 'pending'; scopeTagStatus = 'pendingEnrollment' }
                    [pscustomobject]@{ RowKey = 'old' }
                ) }
            } -ParameterFilter { $Method -eq 'Get' }
            Mock Invoke-RestMethod {} -ParameterFilter { $Method -eq 'Delete' }
            Remove-ExpiredImportAuditRecords -BeforeUtc ([datetimeoffset]::UtcNow.AddDays(-30)) -AccessToken $token |
                Should -Be 1
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'Delete' -and $Uri -like "*RowKey='old'*" }
        }
        It 'persists device ownership outside expiring import history' {
            Mock Get-ImportAuditTableUri { 'https://test.table.core.windows.net/importaudit' }
            Mock Invoke-RestMethod {}
            Set-DevicePolicyState -DeviceId $device -GroupIds @($target, $old) -ScopeTagNames @('Sales') -AccessToken $token
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'Put' -and $Uri -like "*PartitionKey='devicePolicies'*" -and
                (($Body | ConvertFrom-Json).groupIdsJson | ConvertFrom-Json).Count -eq 2
            }
        }
    }
}

    Describe 'Client named policy preservation' {
        BeforeAll {
            Import-Module (Join-Path $PSScriptRoot '..\AutopilotImport.Client\AutopilotImport.Client.psd1') -Force
        }
        BeforeEach {
            $parameters = @{
                ManagementUrl = 'https://test.example/api/management/tag-policy'
                ApiApplicationIdUri = 'api://33333333-3333-3333-3333-333333333333'
                TenantId = '44444444-4444-4444-4444-444444444444'
            }
            Mock Get-ClientAccessToken -ModuleName AutopilotImport.Client {
                ConvertTo-SecureString test -AsPlainText -Force
            }
            Mock Invoke-RestMethod -ModuleName AutopilotImport.Client {
                if ($Method -eq 'Get') {
                    [pscustomobject]@{ policy = @([pscustomobject]@{
                        name = 'Sales'
                        groupId = '11111111-1111-1111-1111-111111111111'
                        tags = @('Sales')
                        groupTag = 'Sales'
                        scopeTag = 'Sales scope'
                        extensionAttributes = [pscustomobject]@{ extensionAttribute5 = 'Berlin' }
                        deviceGroupIds = @('22222222-2222-2222-2222-222222222222')
                    }) }
                } else { [pscustomobject]@{ correlationId = 'test' } }
            }
        }
        It 'preserves every named action when adding an unrelated legacy rule' {
            $null = Add-AutoPilotTagPolicy @parameters -GroupId '55555555-5555-5555-5555-555555555555' -GroupTag Other
            Should -Invoke Invoke-RestMethod -ModuleName AutopilotImport.Client -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'Put' -and
                ($Body | ConvertFrom-Json).policy[0].name -eq 'Sales' -and
                ($Body | ConvertFrom-Json).policy[0].extensionAttributes.extensionAttribute5 -eq 'Berlin' -and
                ($Body | ConvertFrom-Json).policy[0].deviceGroupIds -contains '22222222-2222-2222-2222-222222222222' -and
                ($Body | ConvertFrom-Json).policy[0].scopeTag -eq 'Sales scope'
            }
        }
        It 'rejects adding a second Group Tag to a named single-tag rule' {
            { Add-AutoPilotTagPolicy @parameters -GroupId '11111111-1111-1111-1111-111111111111' -GroupTag Other } |
                Should -Throw '*complete rule objects*'
            Should -Invoke Invoke-RestMethod -ModuleName AutopilotImport.Client -Times 0 -ParameterFilter { $Method -eq 'Put' }
        }
    }
Describe 'Device policy queue integration' {
    BeforeAll {
        Import-Module Az.Accounts
        $worker = Join-Path $PSScriptRoot '..\FunctionApp\ProcessDeviceAttribute\run.ps1'
    }
    BeforeEach {
        $token = ConvertTo-SecureString test -AsPlainText -Force
        Mock Import-Module {}
        Mock Get-AzAccessToken { [pscustomobject]@{ Token = $token } }
        Mock Get-ImportAuditAccessToken { $token }
        Mock Get-ImportAuditRecords {
            @{ 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' = [pscustomobject]@{
                requestReceivedAtUtc = '2026-10-16T00:00:00Z'
                processingStartedAtUtc = ''
            } }
        }
        Mock Set-ImportAuditRecord {}
        Mock Get-ImportAuditHistory { @() }
        Mock Resolve-EffectiveAdministrativeUnitName { '' }
        Mock Get-DevicePolicyActions {
            [pscustomobject]@{
                name = 'Sales'
                groupTag = 'Sales'
                scopeTag = 'Sales'
                extensionAttributes = [pscustomobject]@{ extensionAttribute1 = 'Sales'; extensionAttribute5 = 'Berlin' }
                deviceGroupIds = @('22222222-2222-2222-2222-222222222222')
            }
        }
        Mock Get-DevicePolicyState { [pscustomobject]@{ groupIdsJson = '[]'; scopeTagNamesJson = '[]' } }
        Mock Set-DevicePolicyState {}
        Mock Sync-DevicePolicyGroups {}
        Mock Sync-EntraDeviceAdministrativeUnits {}
        Mock Set-DevicePolicyScopeTag { $false }
        Mock Invoke-RestMethod {
            if ($Uri -like '*importedWindowsAutopilot*') {
                [pscustomobject]@{ state = [pscustomobject]@{ deviceRegistrationId = 'cccccccc-cccc-cccc-cccc-cccccccccccc' } }
            } elseif ($Uri -like '*windowsAutopilotDeviceIdentities/*' -and $Method -eq 'Get') {
                [pscustomobject]@{
                    azureActiveDirectoryDeviceId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
                    serialNumber = 'TEST-POLICY'
                    enrollmentState = 'notContacted'
                }
            } elseif ($Method -eq 'Get') { [pscustomobject]@{ id = 'dddddddd-dddd-dddd-dddd-dddddddddddd' } }
        }
        $message = [pscustomobject]@{
            importId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            registeredDeviceId = ''
            operationId = ''
            groupTag = 'Sales'
            administrativeUnitName = ''
        }
        $policy = '[{"name":"Sales","groupId":"11111111-1111-1111-1111-111111111111","tags":["Sales"],"scopeTag":"Sales","deviceGroupIds":["22222222-2222-2222-2222-222222222222"]}]'
    }
    It 'patches multiple values, syncs groups and records pending scope assignment on import' {
        & $worker -QueueItem $message -TagPolicyBlob $policy
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Patch' -and
            ($Body | ConvertFrom-Json).extensionAttributes.extensionAttribute1 -eq 'Sales' -and
            ($Body | ConvertFrom-Json).extensionAttributes.extensionAttribute5 -eq 'Berlin'
        }
        Should -Invoke Sync-DevicePolicyGroups -Times 1 -Exactly -ParameterFilter {
            $TargetGroupIds -contains '22222222-2222-2222-2222-222222222222'
        }
        Should -Invoke Set-ImportAuditRecord -Times 1 -Exactly -ParameterFilter {
            $Properties.scopeTagStatus -eq 'pendingEnrollment' -and $Properties.managedScopeTagNamesJson -eq '["Sales"]'
        }
        Should -Invoke Set-ImportAuditRecord -Times 1 -Exactly -ParameterFilter { $Properties.processingCompletedAtUtc }
    }
    It 'applies the same actions during re-tagging' {
        $message.registeredDeviceId = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
        $message.operationId = $message.importId
        & $worker -QueueItem $message -TagPolicyBlob $policy
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Post' -and $Uri -like '*updateDeviceProperties'
        }
        Should -Invoke Sync-DevicePolicyGroups -Times 1 -Exactly
        Should -Invoke Set-DevicePolicyScopeTag -Times 1 -Exactly
    }
    It 'skips attribute patches when a named rule has no configured attributes' {
        Mock Get-DevicePolicyActions {
            [pscustomobject]@{ name = 'Sales'; groupTag = 'Sales'; scopeTag = 'Sales'; extensionAttributes = [pscustomobject]@{} }
        }
        & $worker -QueueItem $message -TagPolicyBlob $policy
        Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { $Method -eq 'Patch' }
        Should -Invoke Set-ImportAuditRecord -Times 1 -Exactly -ParameterFilter { $Properties.processingCompletedAtUtc }
    }
}

Describe 'Pending scope timer cleanup' {
    BeforeAll {
        Import-Module Az.Accounts
        $timer = Join-Path $PSScriptRoot '..\FunctionApp\RemoveExpiredImportHistory\run.ps1'
    }
    BeforeEach {
        Mock Import-Module {}
        Mock Get-ImportAuditAccessToken { ConvertTo-SecureString test -AsPlainText -Force }
        Mock Get-AzAccessToken { [pscustomobject]@{ Token = 'test' } }
        Mock Complete-PendingDeviceScopeTags { throw 'Scope assignment failed' }
        Mock Remove-ExpiredImportAuditRecords { 1 }
    }
    It 'cleans up expired history while propagating a scope assignment error' {
        { & $timer } | Should -Throw '*Scope assignment failed*'
        Should -Invoke Remove-ExpiredImportAuditRecords -Times 1 -Exactly
    }
    It 'cleans up expired history while propagating a Graph token error' {
        Mock Get-AzAccessToken { throw 'Graph token failed' }
        { & $timer } | Should -Throw '*Graph token failed*'
        Should -Invoke Remove-ExpiredImportAuditRecords -Times 1 -Exactly
    }
}

BeforeAll {
        if (-not ('HttpResponseContext' -as [type])) {
            Add-Type 'public class HttpResponseContext {
                public System.Net.HttpStatusCode StatusCode;
                public System.Collections.Hashtable Headers;
                public string Body;
            }'
        }
}

        Describe 'Entra policy group search' {
            InModuleScope AutopilotImport {
                BeforeEach {
                    $token = ConvertTo-SecureString test -AsPlainText -Force
                    Mock Invoke-RestMethod {
                        [pscustomobject]@{
                            value = @([pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111'; displayName = 'Sales'; secret = 'excluded' })
                            '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/groups?skiptoken=test'
                        }
                    }
                }
                It 'uses a bounded prefix query and returns only picker properties' {
                    $result = Find-EntraPolicyGroups -SearchText ' Sales ' -AccessToken $token
                    $result.groups.Count | Should -Be 1
                    $result.groups[0].displayName | Should -Be Sales
                    $result.groups[0].PSObject.Properties.Name | Should -Be @('id', 'displayName')
                    $result.hasMore | Should -BeTrue
                    Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                        [uri]::UnescapeDataString($Uri) -eq "https://graph.microsoft.com/v1.0/groups?`$filter=startswith(displayName,'Sales')&`$select=id,displayName&`$top=25"
                    }
                }
                It 'escapes apostrophes without allowing OData injection' {
                    $null = Find-EntraPolicyGroups -SearchText "O'Brien" -AccessToken $token
                    Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                        [uri]::UnescapeDataString($Uri) -like "*startswith(displayName,'O''Brien')*"
                    }
                }
                It 'looks up exact object IDs without treating them as name prefixes' {
                    $id = '11111111-1111-1111-1111-111111111111'
                    $null = Find-EntraPolicyGroups -SearchText $id -AccessToken $token
                    Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                        [uri]::UnescapeDataString($Uri) -like "*id eq '11111111-1111-1111-1111-111111111111'*"
                    }
                }
                It 'returns a real empty array when there are no results' {
                    Mock Invoke-RestMethod { [pscustomobject]@{ value = @() } }
                    $result = Find-EntraPolicyGroups -SearchText Missing -AccessToken $token
                    $result.groups.Count | Should -Be 0
                    $result.hasMore | Should -BeFalse
                }
                It 'rejects short and oversized queries before Graph is called' {
                    { Find-EntraPolicyGroups -SearchText 'a' -AccessToken $token } | Should -Throw
                    { Find-EntraPolicyGroups -SearchText '  ' -AccessToken $token } | Should -Throw
                    { Find-EntraPolicyGroups -SearchText ('a' * 129) -AccessToken $token } | Should -Throw
                    Should -Invoke Invoke-RestMethod -Times 0
                }
                It 'propagates Graph failures instead of reporting no matches' {
                    Mock Invoke-RestMethod { throw 'Graph unavailable' }
                    { Find-EntraPolicyGroups -SearchText Sales -AccessToken $token } | Should -Throw '*Graph unavailable*'
                }
            }
        }

        Describe 'Manager-authorized group search endpoint' {
            BeforeAll {
                Import-Module Az.Accounts
                $managerHandler = Join-Path $PSScriptRoot '..\FunctionApp\ManageTagPolicy\run.ps1'
                $previousManagerPolicy = $env:MANAGER_AUTHORIZATION_POLICY
                $env:MANAGER_AUTHORIZATION_POLICY = '{"allowIntuneRoleAdministrators":false}'
                function Push-OutputBinding { param($Name, $Value) }
            }
            AfterAll {
                $env:MANAGER_AUTHORIZATION_POLICY = $previousManagerPolicy
            }
            BeforeEach {
                $request = @{ Method = 'GET'; Headers = @{ 'x-ms-client-principal' = 'mock' }; Query = @{ groupSearch = 'Sales' } }
                Mock Import-Module {}
                Mock ConvertFrom-ClientPrincipalHeader { [pscustomobject]@{ UserId = 'test' } }
                Mock Test-TagPolicyManagerPrincipal { $true }
                Mock Get-AzAccessToken { [pscustomobject]@{ Token = 'test' } }
                Mock Find-EntraPolicyGroups {
                    [pscustomobject]@{ groups = @([pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111'; displayName = 'Sales' }); hasMore = $false }
                }
                Mock Push-OutputBinding {}
                Mock Write-Error {}
            }
            It 'returns groups independently of policy blob contents' {
                & $managerHandler -Request $request -TagPolicyBlob ''
                Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter {
                    $Value.StatusCode -eq 200 -and ($Value.Body | ConvertFrom-Json).groups[0].displayName -eq 'Sales'
                }
                Should -Invoke Find-EntraPolicyGroups -Times 1 -Exactly -ParameterFilter { $SearchText -eq 'Sales' }
            }
            It 'routes AU searches through the same authorized endpoint' {
                $request.Query = @{ auSearch = 'Berlin' }
                & $managerHandler -Request $request
                Should -Invoke Find-EntraPolicyGroups -Times 1 -Exactly -ParameterFilter {
                    $SearchText -eq 'Berlin' -and $ObjectType -eq 'administrativeUnits'
                }
                Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter { $Value.StatusCode -eq 200 }
            }
            It 'does not expose AU search to non-managers' {
                $request.Query = @{ auSearch = 'Berlin' }
                Mock Test-TagPolicyManagerPrincipal { $false }
                & $managerHandler -Request $request
                Should -Invoke Find-EntraPolicyGroups -Times 0
                Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter { $Value.StatusCode -eq 403 }
            }
            It 'does not expose group search to non-managers' {
                Mock Test-TagPolicyManagerPrincipal { $false }
                & $managerHandler -Request $request
                Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter { $Value.StatusCode -eq 403 }
                Should -Invoke Find-EntraPolicyGroups -Times 0
                Should -Invoke Get-AzAccessToken -Times 0
            }
            It 'requires authentication before group search' {
                $request.Headers = @{}
                & $managerHandler -Request $request
                Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter { $Value.StatusCode -eq 401 }
                Should -Invoke Find-EntraPolicyGroups -Times 0
            }
            It 'rejects invalid query lengths without Graph requests' {
                $request.Query.groupSearch = ''
                & $managerHandler -Request $request
                Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter { $Value.StatusCode -eq 400 }
                Should -Invoke Find-EntraPolicyGroups -Times 0
            }
            It 'logs dependency failure and reports a gateway error' {
                Mock Find-EntraPolicyGroups { throw 'Graph unavailable' }
                & $managerHandler -Request $request
                Should -Invoke Write-Error -Times 1 -Exactly
                Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter {
                    $Value.StatusCode -eq 502 -and ($Value.Body | ConvertFrom-Json).error -eq 'groupSearchFailed'
                }
            }
        }
    Describe 'AU picker search and explicit named attributes' {
        InModuleScope AutopilotImport {
            BeforeEach {
                $token = ConvertTo-SecureString test -AsPlainText -Force
            }
            It 'searches AU names across Graph pages without unsupported startswith filters' {
                Mock Invoke-RestMethod {
                    if ($Uri -like '*skiptoken*') {
                        [pscustomobject]@{ value = @([pscustomobject]@{ id = '22222222-2222-2222-2222-222222222222'; displayName = 'Berlin Devices' }) }
                    } else {
                        [pscustomobject]@{
                            value = @([pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111'; displayName = 'Hamburg' })
                            '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/directory/administrativeUnits?skiptoken=next'
                        }
                    }
                }
                $result = Find-EntraPolicyGroups -SearchText 'ber' -ObjectType administrativeUnits -AccessToken $token
                $result.groups.Count | Should -Be 1
                $result.groups[0].displayName | Should -Be 'Berlin Devices'
                $result.hasMore | Should -BeFalse
                Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter {
                    $Uri -like '*directory/administrativeUnits*' -and $Uri -notlike '*startswith*'
                }
            }
            It 'finds AUs by ID and indicates truncated name searches' {
                Mock Get-PolicyGraphCollection {
                    1..26 | ForEach-Object {
                        [pscustomobject]@{ id = ([guid]::Parse("00000000-0000-0000-0000-$($_.ToString('000000000000'))")).ToString(); displayName = "Berlin $_" }
                    }
                }
                $result = Find-EntraPolicyGroups -SearchText Berlin -ObjectType administrativeUnits -AccessToken $token
                $result.groups.Count | Should -Be 25
                $result.hasMore | Should -BeTrue
                $result = Find-EntraPolicyGroups -SearchText '00000000-0000-0000-0000-000000000026' -ObjectType administrativeUnits -AccessToken $token
                $result.groups.Count | Should -Be 1
                $result.groups[0].displayName | Should -Be 'Berlin 26'
            }
            It 'returns an empty AU result without swallowing Graph errors' {
                Mock Get-PolicyGraphCollection { @() }
                (Find-EntraPolicyGroups -SearchText Missing -ObjectType administrativeUnits -AccessToken $token).groups.Count | Should -Be 0
                Mock Get-PolicyGraphCollection { throw 'AU lookup unavailable' }
                { Find-EntraPolicyGroups -SearchText Berlin -ObjectType administrativeUnits -AccessToken $token } | Should -Throw '*AU lookup unavailable*'
            }
            It 'treats omitted attributes on stored named actions as no writes without mutating the rule' {
                $rule = [pscustomobject]@{ name = 'Sales'; groupId = '11111111-1111-1111-1111-111111111111'; tags = @('Sales'); groupTag = 'Sales' }
                $actions = Get-DevicePolicyActions -Policy @($rule) -GroupTag Sales
                @($actions.extensionAttributes.PSObject.Properties).Count | Should -Be 0
                $rule.PSObject.Properties.Name | Should -Not -Contain extensionAttributes
            }
            It 'matches omitted and explicit empty maps consistently across named actions' {
                $rule = [pscustomobject]@{ name = 'Sales'; tags = @('Sales'); groupTag = 'Sales'; deviceGroupIds = @() }
                $other = [pscustomobject]@{ name = 'Other'; tags = @('Sales'); groupTag = 'Sales'; extensionAttributes = [pscustomobject]@{}; deviceGroupIds = @() }
                { Get-DevicePolicyActions -Policy @($rule, $other) -GroupTag Sales } | Should -Not -Throw
            }
        }
    }
Describe 'Named policy import status' {
    BeforeAll {
        Import-Module Az.Accounts
        function Push-OutputBinding { param($Name, $Value) }
        $handler = Join-Path $PSScriptRoot '..\FunctionApp\ImportDevice\run.ps1'
    }
    BeforeEach {
        $id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $expectedAttributes = [pscustomobject]@{ extensionAttribute1 = 'Sales'; extensionAttribute5 = 'Berlin' }
        $actualAttributes = [pscustomobject]@{ extensionAttribute1 = 'Sales'; extensionAttribute5 = 'Berlin' }
        $request = @{ Method = 'GET'; Headers = @{ 'x-ms-client-principal' = 'mock' }; Query = @{ importId = $id } }
        Mock Import-Module {}
        Mock Get-AzAccessToken { [pscustomobject]@{ Token = 'test' } }
        Mock ConvertFrom-ClientPrincipalHeader { [pscustomobject]@{ UserId = 'test' } }
        Mock Get-CurrentPolicyPrincipal { [pscustomobject]@{ UserId = 'test' } }
        Mock Resolve-AuthorizedGroupTag { 'Sales' }
        Mock Get-DevicePolicyActions {
            [pscustomobject]@{ groupTag = 'Sales'; scopeTag = 'Sales'; extensionAttributes = $expectedAttributes }
        }
        Mock Get-ImportAuditAccessToken { ConvertTo-SecureString test -AsPlainText -Force }
        Mock Get-ImportAuditRecords {
            @{ $id = [pscustomobject]@{ processingCompletedAtUtc = '2026-10-16T00:00:00Z'; scopeTagStatus = 'pendingEnrollment' } }
        }
        Mock Push-OutputBinding {}
        Mock Get-AutoPilotDeviceRegistrationId { $id }
        Mock Invoke-RestMethod {
            if ($Uri -like '*importedWindowsAutopilotDeviceIdentities/*') {
                [pscustomobject]@{ id = $id; serialNumber = 'TEST'; groupTag = 'Sales'; state = @{ deviceImportStatus = 'complete' } }
            } elseif ($Uri -like '*windowsAutopilotDeviceIdentities/*') {
                [pscustomobject]@{ azureActiveDirectoryDeviceId = $id }
            } else { [pscustomobject]@{ extensionAttributes = $actualAttributes } }
        }
        $policy = '[{"name":"Sales","groupId":"11111111-1111-1111-1111-111111111111","tags":["Sales"],"groupTag":"Sales"}]'
    }
    It 'reports all custom values and separates pending enrollment from initial completion' {
        & $handler -Request $request -TagPolicyBlob $policy
        Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter {
            $Value.StatusCode | Should -Be 200
            $body = $Value.Body | ConvertFrom-Json
            $body.workflowStatus | Should -Be 'complete'
            $body.scopeTagStatus | Should -Be 'pendingEnrollment'
            $body.expectedExtensionAttributes.extensionAttribute5 | Should -Be 'Berlin'
            $true
        }
    }
    It 'does not complete when only one of several attributes matches' {
        $actualAttributes.extensionAttribute5 = 'Hamburg'
        & $handler -Request $request -TagPolicyBlob $policy
        Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter {
            ($Value.Body | ConvertFrom-Json).workflowStatus -eq 'pending'
        }
    }
    It 'completes an explicit empty attribute map even if Entra returns no attributes' {
        $expectedAttributes = [pscustomobject]@{}
        $actualAttributes = $null
        & $handler -Request $request -TagPolicyBlob $policy
        Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter {
            ($Value.Body | ConvertFrom-Json).workflowStatus -eq 'complete'
        }
    }
    It 'waits for the queue to complete group actions even when attributes already match' {
        Mock Get-ImportAuditRecords { @{} }
        & $handler -Request $request -TagPolicyBlob $policy
        Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter {
            ($Value.Body | ConvertFrom-Json).workflowStatus -eq 'pending'
        }
    }
}
