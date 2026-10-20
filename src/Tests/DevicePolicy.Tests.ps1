# Project-Version: 1.4.20261020.8
# Author: andreas.lucas@outlook.com (aka Kili)

Import-Module (Join-Path $PSScriptRoot '..\FunctionApp\src\AutopilotImport\AutopilotImport.psm1') -Force

Describe 'Named device policy normalization' {
    BeforeEach {
        $rule = @{
            name = 'Sales'
            description = "Sales devices`nBerlin"
            groupId = '11111111-1111-1111-1111-111111111111'
            groupTag = 'Sales'
        }
    }
    It 'allows an empty existing policy only when explicitly requested' {
        $policy = ConvertTo-TagAuthorizationPolicy -Rules @() -AllowEmpty
        ($null -eq $policy) | Should -BeFalse
        $policy.Count | Should -Be 0
        ConvertTo-Json -InputObject $policy -Compress | Should -BeExactly '[]'
        { ConvertTo-TagAuthorizationPolicy -Rules @() } | Should -Throw '*At least one*'
    }
    It 'does not treat null or blank rules as a valid empty policy' -ForEach @(
        @{ Json = 'null' }
        @{ Json = '[null]' }
        @{ Json = '[""]' }
        @{ Json = '[" "]' }
    ) {
        { ConvertTo-TagAuthorizationPolicy -Rules @($Json | ConvertFrom-Json) -AllowEmpty } |
            Should -Throw
    }
    It 'keeps Group Tag actions without scope tag output' {
        $policy = ConvertTo-TagAuthorizationPolicy -Rules @($rule)
        $policy[0].name | Should -Be 'Sales'
        $policy[0].PSObject.Properties.Name | Should -Not -Contain 'scopeTag'
        $policy[0].tags | Should -Be @('Sales')
        @($policy[0].extensionAttributes.Keys).Count | Should -Be 0
    }
    It 'assigns stable IDs to existing rules and preserves them across renames' {
        $first = ConvertTo-TagAuthorizationPolicy -Rules @($rule)
        $again = ConvertTo-TagAuthorizationPolicy -Rules @($rule)
        $first[0].ruleId | Should -Be $again[0].ruleId
        $first[0].name = 'Renamed'
        $first[0].groupId = '22222222-2222-2222-2222-222222222222'
        (ConvertTo-TagAuthorizationPolicy -Rules @($first))[0].ruleId | Should -Be $again[0].ruleId
        $rule.ruleId = 'invalid'
        { ConvertTo-TagAuthorizationPolicy -Rules @($rule) } | Should -Throw '*ruleId*'
    }
    It 'rejects assigning the same persistent ID to two different rules' {
        $rule.ruleId = '22222222-2222-2222-2222-222222222222'
        $other = $rule.Clone()
        $other.name = 'Other'
        { ConvertTo-TagAuthorizationPolicy -Rules @($rule, $other) } | Should -Throw '*unique ruleId*'
    }
    It 'preserves multiline descriptions for named and legacy rules' {
        $rule.description = "Sales devices`nBerlin and Hamburg"
        $policy = ConvertTo-TagAuthorizationPolicy -Rules @($rule)
        $policy[0].description | Should -BeExactly $rule.description
        $legacy = @{ groupId = $rule.groupId; tags = @('Sales'); description = $rule.description }
        (ConvertTo-TagAuthorizationPolicy -Rules @($legacy))[0].description | Should -BeExactly $rule.description
    }
    It 'enforces description length and rejects non-text controls' {
        $rule.description = 'x' * 2048
        (ConvertTo-TagAuthorizationPolicy -Rules @($rule))[0].description.Length | Should -Be 2048
        $rule.description += 'x'
        { ConvertTo-TagAuthorizationPolicy -Rules @($rule) } | Should -Throw '*description*'
        $rule.description = "bad$([char]0)value"
        { ConvertTo-TagAuthorizationPolicy -Rules @($rule) } | Should -Throw '*description*'
        $rule.description = 123
        { ConvertTo-TagAuthorizationPolicy -Rules @($rule) } | Should -Throw '*description*'
    }
    It 'migrates the effective group tag from an older scope-only rule without retaining scope actions' {
        $rule.Remove('groupTag')
        $rule.scopeTag = 'Operations'
        $policy = ConvertTo-TagAuthorizationPolicy -Rules @($rule)
        $policy[0].groupTag | Should -Be 'Operations'
        $policy[0].tags | Should -Be @('Operations')
        $policy[0].PSObject.Properties.Name | Should -Not -Contain 'scopeTag'
    }
    It 'requires a name and at least one tag' {
        $rule.name = ''
        { ConvertTo-TagAuthorizationPolicy -Rules @($rule) } | Should -Throw '*name*'
        $rule.name = 'Sales'
        $rule.groupTag = ''
        { ConvertTo-TagAuthorizationPolicy -Rules @($rule) } | Should -Throw '*Group Tag*'
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
        $other.extensionAttributes = @{ extensionAttribute1 = 'Other' }
        $policy = ConvertTo-TagAuthorizationPolicy -Rules @($rule, $other)
        { Get-DevicePolicyActions -Policy $policy -GroupTag 'Sales' } | Should -Throw '*conflicting device actions*'
    }
    It 'migrates legacy names without enabling new scope/group actions' {
        $policy = ConvertTo-TagAuthorizationPolicy -Rules @('11111111-1111-1111-1111-111111111111=Sales,Shared')
        $policy[0].name | Should -Be 'Policy 11111111-1111-1111-1111-111111111111'
        $policy[0].tags.Count | Should -Be 2
        $policy[0].PSObject.Properties.Name | Should -Not -Contain 'scopeTag'
    }
    It 'ignores different deprecated scopes when comparing and returning active actions' {
        $raw = @(
            [pscustomobject]@{ name = 'A'; groupTag = 'Sales'; tags = @('Sales'); scopeTag = 'Old A' }
            [pscustomobject]@{ name = 'B'; groupTag = 'Sales'; tags = @('Sales'); scopeTag = 'Old B' }
        )
        $actions = Get-DevicePolicyActions -Policy $raw -GroupTag Sales
        $actions.groupTag | Should -Be 'Sales'
        $actions.PSObject.Properties.Name | Should -Not -Contain 'scopeTag'
        $raw[0].scopeTag | Should -Be 'Old A'
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
            $result = Sync-DevicePolicyGroups -Policy @([pscustomobject]@{ deviceGroupIds = @($target) }) `
                -PreviousGroupIds @($old) -TargetGroupIds @($target) -DeviceObjectId $device -AccessToken $token -PassThru
            $result.AddedGroupIds | Should -Be @($target)
            $result.RemovedGroupIds | Should -Be @($old)
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
            $result = Sync-DevicePolicyGroups -Policy @([pscustomobject]@{ deviceGroupIds = @($target) }) `
                -TargetGroupIds @($target) -DeviceObjectId $device -AccessToken $token -PassThru
            $result.AddedGroupIds.Count | Should -Be 0
            $result.RemovedGroupIds.Count | Should -Be 0
            Should -Invoke Invoke-RestMethod -Times 0
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
        It 'expires abandoned old scope records with normal audit retention' {
            Mock Get-ImportAuditTableUri { 'https://test.table.core.windows.net/importaudit' }
            Mock Invoke-RestMethod {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ RowKey = 'pending'; scopeTagStatus = 'pendingEnrollment' }
                    [pscustomobject]@{ RowKey = 'old' }
                ) }
            } -ParameterFilter { $Method -eq 'Get' }
            Mock Invoke-RestMethod {} -ParameterFilter { $Method -eq 'Delete' }
            Remove-ExpiredImportAuditRecords -BeforeUtc ([datetimeoffset]::UtcNow.AddDays(-30)) -AccessToken $token |
                Should -Be 2
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Method -eq 'Delete' }
        }
        It 'persists device ownership outside expiring import history' {
            Mock Get-ImportAuditTableUri { 'https://test.table.core.windows.net/importaudit' }
            Mock Invoke-RestMethod {}
            Set-DevicePolicyState -DeviceId $device -GroupIds @($target, $old) -AccessToken $token
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
                        description = "Sales devices`nBerlin"
                        ruleId = '66666666-6666-6666-6666-666666666666'
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
                ($Body | ConvertFrom-Json).policy[0].description -eq "Sales devices`nBerlin" -and
                ($Body | ConvertFrom-Json).policy[0].ruleId -eq '66666666-6666-6666-6666-666666666666' -and
                ($Body | ConvertFrom-Json).policy[0].extensionAttributes.extensionAttribute5 -eq 'Berlin' -and
                ($Body | ConvertFrom-Json).policy[0].deviceGroupIds -contains '22222222-2222-2222-2222-222222222222' -and
                'scopeTag' -notin ($Body | ConvertFrom-Json).policy[0].PSObject.Properties.Name
            }
        }
        It 'rejects adding a second Group Tag to a named single-tag rule' {
            { Add-AutoPilotTagPolicy @parameters -GroupId '11111111-1111-1111-1111-111111111111' -GroupTag Other } |
                Should -Throw '*complete rule objects*'
            Should -Invoke Invoke-RestMethod -ModuleName AutopilotImport.Client -Times 0 -ParameterFilter { $Method -eq 'Put' }
        }
        It 'submits <Count> replacement rules as a flat JSON array' -TestCases @(
            @{ Count = 1 }
            @{ Count = 2 }
        ) {
            param($Count)
            $coreModulePath = Join-Path $PSScriptRoot '..\FunctionApp\src\AutopilotImport\AutopilotImport.psm1'
            Mock Get-CoreModulePath -ModuleName AutopilotImport.Client { $coreModulePath }
            Mock Import-Module -ModuleName AutopilotImport.Client {}
            $rules = @(
                '11111111-1111-1111-1111-111111111111=Sales'
                '55555555-5555-5555-5555-555555555555=Other'
            )[0..($Count - 1)]
            $null = Set-AutoPilotTagPolicy @parameters -TagAuthorizationRule $rules
            Should -Invoke Invoke-RestMethod -ModuleName AutopilotImport.Client -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'Put' -and
                ($Body | ConvertFrom-Json).policy.Count -eq $Count -and
                ($Body | ConvertFrom-Json).policy[0].groupId -is [string]
            }
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
        Mock Sync-DevicePolicyGroups {
            [pscustomobject]@{ AddedGroupIds = @('22222222-2222-2222-2222-222222222222'); RemovedGroupIds = @() }
        }
        Mock Sync-EntraDeviceAdministrativeUnits {
            [pscustomobject]@{ RemovedAdministrativeUnits = @('Old AU'); TargetAdministrativeUnit = ''; MembershipAdded = $false }
        }
        Mock Invoke-RestMethod {
            if ($Uri -like '*importedWindowsAutopilot*') {
                [pscustomobject]@{ state = [pscustomobject]@{ deviceRegistrationId = 'cccccccc-cccc-cccc-cccc-cccccccccccc'; deviceImportStatus = 'complete' } }
            } elseif ($Uri -like '*windowsAutopilotDeviceIdentities/*' -and $Method -eq 'Get') {
                [pscustomobject]@{
                    azureActiveDirectoryDeviceId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
                    serialNumber = 'TEST-POLICY'
                    enrollmentState = 'notContacted'
                    groupTag = 'Sales'
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
    It 'patches multiple values and syncs groups without post-enrollment Graph calls' {
        & $worker -QueueItem $message -TagPolicyBlob $policy
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Patch' -and
            ($Body | ConvertFrom-Json).extensionAttributes.extensionAttribute1 -eq 'Sales' -and
            ($Body | ConvertFrom-Json).extensionAttributes.extensionAttribute5 -eq 'Berlin'
        }
        Should -Invoke Sync-DevicePolicyGroups -Times 1 -Exactly -ParameterFilter {
            $TargetGroupIds -contains '22222222-2222-2222-2222-222222222222'
        }
        Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { $Uri -match 'managedDevices|roleScopeTags' }
        Should -Invoke Set-ImportAuditRecord -Times 0 -ParameterFilter { 'scopeTagStatus' -in $Properties.Keys }
        Should -Invoke Set-ImportAuditRecord -Times 1 -Exactly -ParameterFilter { $Properties.processingCompletedAtUtc }
        Should -Invoke Set-ImportAuditRecord -Times 1 -Exactly -ParameterFilter {
            $Properties.graphImportCompletedAtUtc -and $Properties.autopilotGroupTagUpdatedAtUtc
        }
        Should -Invoke Set-ImportAuditRecord -Times 1 -Exactly -ParameterFilter {
            $Properties.appliedExtensionAttributesJson -and
            ($Properties.appliedExtensionAttributesJson | ConvertFrom-Json).PSObject.Properties['extensionAttribute5'] -and
            ($Properties.appliedExtensionAttributesJson | ConvertFrom-Json).extensionAttribute5 -eq 'Berlin'
        }
        Should -Invoke Set-ImportAuditRecord -Times 1 -Exactly -ParameterFilter {
            $Properties.addedDeviceGroupIdsJson -eq '["22222222-2222-2222-2222-222222222222"]' -and
            $Properties.removedDeviceGroupIdsJson -eq '[]'
        }
        Should -Invoke Set-ImportAuditRecord -Times 1 -Exactly -ParameterFilter {
            $Properties.removedAdministrativeUnitsJson -eq '["Old AU"]'
        }
    }
    It 'applies the same actions during re-tagging' {
        $message.registeredDeviceId = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
        $message.operationId = $message.importId
        & $worker -QueueItem $message -TagPolicyBlob $policy
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Post' -and $Uri -like '*updateDeviceProperties'
        }
        Should -Invoke Sync-DevicePolicyGroups -Times 1 -Exactly
        Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { $Uri -match 'managedDevices|roleScopeTags' }
        Should -Invoke Set-ImportAuditRecord -Times 0 -ParameterFilter { $Properties.graphImportCompletedAtUtc }
    }
    It 'skips attribute patches when a named rule has no configured attributes' {
        Mock Get-DevicePolicyActions {
            [pscustomobject]@{ name = 'Sales'; groupTag = 'Sales'; scopeTag = 'Sales'; extensionAttributes = [pscustomobject]@{} }
        }
        & $worker -QueueItem $message -TagPolicyBlob $policy
        Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { $Method -eq 'Patch' }
        Should -Invoke Set-ImportAuditRecord -Times 1 -Exactly -ParameterFilter { $Properties.appliedExtensionAttributesJson -eq '{}' }
        Should -Invoke Set-ImportAuditRecord -Times 1 -Exactly -ParameterFilter { $Properties.processingCompletedAtUtc }
    }
    It 'does not record successful group synchronization or completion after a group failure' {
        Mock Sync-DevicePolicyGroups { throw 'Membership denied' }
        { & $worker -QueueItem $message -TagPolicyBlob $policy } | Should -Throw '*Membership denied*'
        Should -Invoke Set-ImportAuditRecord -Times 0 -ParameterFilter { $Properties.deviceGroupsUpdatedAtUtc -or $Properties.processingCompletedAtUtc }
        Should -Invoke Set-ImportAuditRecord -Times 1 -Exactly -ParameterFilter {
            $Properties.processingErrorStep -eq 'deviceGroups' -and $Properties.processingError -like '*Membership denied*'
        }
    }
    It 'stops and records a failure when the extension attribute patch is denied' {
        Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Patch' } {
            throw [System.Exception]::new('Response status code does not indicate success: 403 (Forbidden).')
        }
        { & $worker -QueueItem $message -TagPolicyBlob $policy -TriggerMetadata @{ DequeueCount = 24 } } |
            Should -Throw "*Processing step 'extensionAttributes' failed*attempt 24 of 24*"
        Should -Invoke Set-ImportAuditRecord -Times 0 -ParameterFilter {
            $Properties.extensionAttributeUpdatedAtUtc -or $Properties.processingCompletedAtUtc
        }
        Should -Invoke Sync-DevicePolicyGroups -Times 0
        Should -Invoke Set-ImportAuditRecord -Times 1 -Exactly -ParameterFilter {
            $Properties.processingErrorStep -eq 'extensionAttributes' -and
            $Properties.processingFailedAtUtc -and
            $Properties.processingAttempt -eq 24
        }
    }
}

Describe 'Processing failure audit helpers' {
    It 'adds a restricted administrative unit hint for denied requests' {
        $exception = [System.Exception]::new('Response status code does not indicate success: 403 (Forbidden).')
        $exception.Data['StatusCode'] = 403
        $errorRecord = [System.Management.Automation.ErrorRecord]::new($exception, 'Denied', 'PermissionDenied', $null)
        $errorRecord.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"error":{"code":"Authorization_RequestDenied","message":"Target object is a member of a restricted management administrative unit and can only be modified by administrators scoped to that administrative unit."}}')
        $failure = Get-ProcessingFailureAudit -ErrorRecord $errorRecord -Step extensionAttributes -Attempt 1 -MaxAttempts 24
        $failure.IsFailed | Should -BeTrue
        $failure.StatusCode | Should -Be 403
        $failure.Properties.processingErrorStep | Should -Be 'extensionAttributes'
        $failure.Properties.processingError | Should -BeLike 'HTTP 403:*restricted management administrative unit*Autopilot Import Device Attribute Writer*'
        $failure.Properties.processingFailedAtUtc | Should -Not -BeNullOrEmpty
        $failure.Properties.processingAttempt | Should -Be 1
    }
    It 'does not record expected waits before the final attempt' {
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('Entra device is not available yet.'), 'Wait', 'NotSpecified', $null)
        $waiting = Get-ProcessingFailureAudit -ErrorRecord $errorRecord -Step entraDevice -Attempt 2 -MaxAttempts 24
        $waiting.Properties.Count | Should -Be 0
        $waiting.IsFailed | Should -BeFalse
        $final = Get-ProcessingFailureAudit -ErrorRecord $errorRecord -Step entraDevice -Attempt 24 -MaxAttempts 24
        $final.IsFinal | Should -BeTrue
        $final.Properties.processingFailedAtUtc | Should -Not -BeNullOrEmpty
    }
    It 'reports failures only until a later completion' {
        Test-ProcessingFailed -AuditRecord ([pscustomobject]@{ processingFailedAtUtc = '2026-10-19T06:00:00Z'; processingCompletedAtUtc = '' }) | Should -BeTrue
        Test-ProcessingFailed -AuditRecord ([pscustomobject]@{ processingFailedAtUtc = '2026-10-19T06:00:00Z'; processingCompletedAtUtc = '2026-10-19T07:00:00Z' }) | Should -BeFalse
        Test-ProcessingFailed -AuditRecord ([pscustomobject]@{ processingFailedAtUtc = '' }) | Should -BeFalse
    }
}

Describe 'Audit-only timer cleanup' {
    BeforeAll {
        Import-Module Az.Accounts
        $timer = Join-Path $PSScriptRoot '..\FunctionApp\RemoveExpiredImportHistory\run.ps1'
    }
    BeforeEach {
        Mock Import-Module {}
        Mock Get-ImportAuditAccessToken { ConvertTo-SecureString test -AsPlainText -Force }
        Mock Get-AzAccessToken { [pscustomobject]@{ Token = 'test' } }
        Mock Remove-ExpiredImportAuditRecords { 1 }
    }
    It 'cleans up expired history without acquiring a Graph token' {
        & $timer
        Should -Invoke Remove-ExpiredImportAuditRecords -Times 1 -Exactly
        Should -Invoke Get-AzAccessToken -Times 0
    }
    It 'propagates storage cleanup failures' {
        Mock Remove-ExpiredImportAuditRecords { throw 'Storage cleanup failed' }
        { & $timer } | Should -Throw '*Storage cleanup failed*'
        Should -Invoke Remove-ExpiredImportAuditRecords -Times 1 -Exactly
    }
}

Describe 'Detailed history API projection' {
    BeforeAll {
        Import-Module Az.Accounts
        $historyHandler = Join-Path $PSScriptRoot '..\FunctionApp\GetImportHistory\run.ps1'
        function Push-OutputBinding { param($Name, $Value) }
    }
    BeforeEach {
        Mock Import-Module {}
        Mock ConvertFrom-ClientPrincipalHeader {
            [pscustomobject]@{ claims = @([pscustomobject]@{ typ = 'oid'; val = '11111111-1111-1111-1111-111111111111' }) }
        }
        Mock Get-ImportAuditAccessToken { ConvertTo-SecureString test -AsPlainText -Force }
        Mock Get-AzAccessToken { [pscustomobject]@{ Token = 'test' } }
        Mock Invoke-RestMethod { [pscustomobject]@{ value = @() } }
        $capturedResponses = [Collections.Generic.List[object]]::new()
        Mock Push-OutputBinding { $capturedResponses.Add($Value) }
        $record = [pscustomobject]@{
            RowKey = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            graphImportCompletedAtUtc = '2026-10-16T12:00:02Z'
            appliedExtensionAttributesJson = '{"extensionAttribute5":"Berlin"}'
            targetDeviceGroupIdsJson = '["22222222-2222-2222-2222-222222222222"]'
            addedDeviceGroupIdsJson = '["22222222-2222-2222-2222-222222222222"]'
            removedDeviceGroupIdsJson = '[]'
            administrativeUnitName = 'Berlin Devices'
            removedAdministrativeUnitsJson = '["Old AU"]'
        }
        Mock Get-ImportAuditHistory { $record }
        $request = @{ Method = 'GET'; Headers = @{ 'x-ms-client-principal' = 'mock' }; Query = @{} }
    }
    It 'returns attribute maps and real arrays including single and empty group lists' {
        & $historyHandler -Request $request
        $capturedResponses.Count | Should -Be 1
        $capturedResponses[0].StatusCode | Should -Be 200
        $item = ($capturedResponses[0].Body | ConvertFrom-Json).imports[0]
        $item.appliedExtensionAttributes.extensionAttribute5 | Should -Be 'Berlin'
        ($item.targetDeviceGroupIds -is [array]) | Should -BeTrue
        $item.targetDeviceGroupIds.Count | Should -Be 1
        ($item.addedDeviceGroupIds -is [array]) | Should -BeTrue
        $item.addedDeviceGroupIds.Count | Should -Be 1
        ($item.removedDeviceGroupIds -is [array]) | Should -BeTrue
        $item.removedDeviceGroupIds.Count | Should -Be 0
        $item.removedAdministrativeUnits[0] | Should -Be 'Old AU'
        $item.administrativeUnitName | Should -Be 'Berlin Devices'
        ([datetimeoffset] $item.graphImportCompletedAtUtc).ToUniversalTime() |
            Should -Be ([datetimeoffset]'2026-10-16T12:00:02Z')
    }
    It 'does not invent action details for older records' {
        $record = [pscustomobject]@{ RowKey = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
        & $historyHandler -Request $request
        Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter {
            $body = $Value.Body | ConvertFrom-Json
            $Value.StatusCode -eq 200 -and
            $null -eq $body.imports[0].appliedExtensionAttributes -and
            $null -eq $body.imports[0].addedDeviceGroupIds -and
            $null -eq $body.imports[0].graphImportCompletedAtUtc
        }
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
                It 'searches users by display name or UPN and returns basic identifiable names' {
                    Mock Invoke-RestMethod {
                        [pscustomobject]@{ value = @([pscustomobject]@{
                            id = '11111111-1111-1111-1111-111111111111'
                            displayName = 'User One'
                            userPrincipalName = 'user@example.test'
                        }) }
                    }
                    $result = Find-EntraPolicyGroups -SearchText 'user@' -ObjectType users -AccessToken $token
                    $result.groups[0].displayName | Should -Be 'User One (user@example.test)'
                    $result.groups[0].PSObject.Properties.Name | Should -Be @('id', 'displayName')
                    Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                        [uri]::UnescapeDataString($Uri) -eq "https://graph.microsoft.com/v1.0/users?`$filter=(startswith(displayName,'user@') or startswith(userPrincipalName,'user@'))&`$select=id,displayName,userPrincipalName&`$top=25"
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
                It 'treats exact-ID Graph 404 as no object of that type' -ForEach @(
                    @{ ObjectType = 'users' }
                    @{ ObjectType = 'groups' }
                ) {
                    Mock Invoke-RestMethod {
                        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound)
                        throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Not found', $response)
                    }
                    $result = Find-EntraPolicyGroups -SearchText '11111111-1111-1111-1111-111111111111' -ObjectType $ObjectType -AccessToken $token
                    ($result.groups -is [array]) | Should -BeTrue
                    $result.groups.Count | Should -Be 0
                    $result.hasMore | Should -BeFalse
                }
                It 'does not suppress Graph 404 for a name search or forbidden ID lookup' {
                    Mock Invoke-RestMethod {
                        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound)
                        throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Not found', $response)
                    }
                    { Find-EntraPolicyGroups -SearchText Sales -AccessToken $token } | Should -Throw
                    Mock Invoke-RestMethod {
                        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden)
                        throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Forbidden', $response)
                    }
                    { Find-EntraPolicyGroups -SearchText '11111111-1111-1111-1111-111111111111' -AccessToken $token } | Should -Throw
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
                $previousTagPolicy = $env:TAG_AUTHORIZATION_POLICY
                $env:MANAGER_AUTHORIZATION_POLICY = '{"allowIntuneRoleAdministrators":false}'
                $env:TAG_AUTHORIZATION_POLICY = '[]'
                function Push-OutputBinding { param($Name, $Value) }
            }
            AfterAll {
                $env:MANAGER_AUTHORIZATION_POLICY = $previousManagerPolicy
                $env:TAG_AUTHORIZATION_POLICY = $previousTagPolicy
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
                Mock Write-ManagementAuditEvent {}
                Mock Set-ManagementPolicyBlob {}
                Mock Get-ManagementAuditHistory { @{ events = @(); continuation = '' } }
            }
            It 'returns groups independently of policy blob contents' {
                & $managerHandler -Request $request -TagPolicyBlob ''
                Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter {
                    $Value.StatusCode -eq 200 -and ($Value.Body | ConvertFrom-Json).groups[0].displayName -eq 'Sales'
                }
                Should -Invoke Find-EntraPolicyGroups -Times 1 -Exactly -ParameterFilter { $SearchText -eq 'Sales' }
            }
            It 'returns an actual empty policy array before the first rule is configured' {
                $request.Query = @{}
                & $managerHandler -Request $request -TagPolicyBlob ''
                Should -Invoke Push-OutputBinding -Times 1 -ParameterFilter {
                    $body = $Value.Body | ConvertFrom-Json
                    $Value.StatusCode -eq 200 -and $body.policy -is [array] -and $body.policy.Count -eq 0
                }
            }
            It 'saves the first valid rule using the empty deployment fallback' {
                $request.Method = 'PUT'
                $request.Query = @{}
                $request.Body = @{ policy = @(@{
                    name = 'First'
                    groupId = '11111111-1111-1111-1111-111111111111'
                    groupTag = 'Sales'
                }) }
                & $managerHandler -Request $request -TagPolicyBlob ''
                Should -Invoke Set-ManagementPolicyBlob -Times 1 -ParameterFilter {
                    $ExpectedJson -eq '[]' -and ($Json | ConvertFrom-Json)[0].name -eq 'First'
                }
                Should -Invoke Write-ManagementAuditEvent -Times 1 -ParameterFilter { $Stage -eq 'applied' }
                Should -Invoke Push-OutputBinding -Times 1 -ParameterFilter {
                    $Value.StatusCode -eq 200 -and ($Value.Body | ConvertFrom-Json).policy.Count -eq 1
                }
            }
            It 'still rejects replacing a policy with no rules' {
                $request.Method = 'PUT'
                $request.Query = @{}
                $request.Body = @{ policy = @() }
                & $managerHandler -Request $request -TagPolicyBlob '[]'
                Should -Invoke Set-ManagementPolicyBlob -Times 0
                Should -Invoke Push-OutputBinding -Times 1 -ParameterFilter {
                    $Value.StatusCode -eq 400 -and ($Value.Body | ConvertFrom-Json).error -eq 'invalidTagPolicy'
                }
            }
            It 'rejects malformed or null existing policy instead of reporting no rules' -ForEach @(
                @{ Json = 'bad' }
                @{ Json = 'null' }
                @{ Json = '[null]' }
            ) {
                $request.Query = @{}
                & $managerHandler -Request $request -TagPolicyBlob $Json
                Should -Invoke Push-OutputBinding -Times 1 -ParameterFilter {
                    $Value.StatusCode -eq 500 -and ($Value.Body | ConvertFrom-Json).error -eq 'tagPolicyInvalid'
                }
            }
                It 'authorizes policy history before reading its permanent records' {
                    $request.Query = @{ history = 'true'; ruleId = '11111111-1111-1111-1111-111111111111' }
                    & $managerHandler -Request $request
                    Should -Invoke Get-ManagementAuditHistory -Times 1 -ParameterFilter {
                        $Kind -eq 'policies' -and $RuleId -eq '11111111-1111-1111-1111-111111111111'
                    }
                    Should -Invoke Push-OutputBinding -Times 1 -ParameterFilter {
                        $Value.StatusCode -eq 200 -and ($Value.Body | ConvertFrom-Json).ruleId -eq '11111111-1111-1111-1111-111111111111'
                    }
                }
                It 'denies policy history to non-managers' {
                    $request.Query = @{ history = 'true' }
                    Mock Test-TagPolicyManagerPrincipal { $false }
                    & $managerHandler -Request $request
                    Should -Invoke Get-ManagementAuditHistory -Times 0
                    Should -Invoke Push-OutputBinding -Times 1 -ParameterFilter { $Value.StatusCode -eq 403 }
                }
                It 'requires a specific valid rule ID for policy history' -TestCases @(
                    @{ Id = '' }; @{ Id = 'bad' }; @{ Id = '00000000-0000-0000-0000-000000000000' }
                ) {
                    param($Id)
                    $request.Query = @{ history = 'true'; ruleId = $Id }
                    & $managerHandler -Request $request
                    Should -Invoke Get-ManagementAuditHistory -Times 0
                    Should -Invoke Push-OutputBinding -Times 1 -ParameterFilter {
                        $Value.StatusCode -eq 400 -and ($Value.Body | ConvertFrom-Json).error -eq 'ruleIdRequired'
                    }
                }
                It 'reports invalid policy-history pagination explicitly' {
                    $request.Query = @{ history = 'true'; ruleId = '11111111-1111-1111-1111-111111111111'; continuation = 'invalid' }
                    Mock Get-ManagementAuditHistory { throw [ArgumentException]::new('Invalid continuation') }
                    & $managerHandler -Request $request
                    Should -Invoke Push-OutputBinding -Times 1 -ParameterFilter { $Value.StatusCode -eq 400 }
                }
                It 'does not write policy configuration if its initial audit insertion fails' {
                    $request.Method = 'PUT'
                    $request.Query = @{}
                    $request.Body = @{ policy = @(@{ groupId = '11111111-1111-1111-1111-111111111111'; tags = @('New') }) }
                    Mock Write-ManagementAuditEvent { throw 'Audit unavailable' }
                    & $managerHandler -Request $request -TagPolicyBlob '[{"groupId":"11111111-1111-1111-1111-111111111111","tags":["Old"]}]'
                    Should -Invoke Set-ManagementPolicyBlob -Times 0
                    Should -Invoke Push-OutputBinding -Times 1 -ParameterFilter { $Value.StatusCode -eq 502 }
                }
                It 'reports an unconfirmed policy write when completion auditing fails' {
                    $request.Method = 'PUT'
                    $request.Query = @{}
                    $request.Body = @{ policy = @(@{ groupId = '11111111-1111-1111-1111-111111111111'; tags = @('New') }) }
                    Mock Write-ManagementAuditEvent { throw 'Confirmation failed' } -ParameterFilter { $Stage -eq 'applied' }
                    & $managerHandler -Request $request -TagPolicyBlob '[{"groupId":"11111111-1111-1111-1111-111111111111","tags":["Old"]}]'
                    Should -Invoke Set-ManagementPolicyBlob -Times 1
                    Should -Invoke Write-ManagementAuditEvent -Times 1 -ParameterFilter { $Stage -eq 'failed' }
                    Should -Invoke Push-OutputBinding -Times 1 -ParameterFilter {
                        $Value.StatusCode -eq 502 -and ($Value.Body | ConvertFrom-Json).error -eq 'policySaveUnconfirmed'
                    }
                }
            It 'returns a flat policy array for <Count> legacy rules' -TestCases @(
                @{ Count = 1 }
                @{ Count = 2 }
            ) {
                param($Count)
                $request.Query = @{}
                $rules = @(
                    @{ groupId = '11111111-1111-1111-1111-111111111111'; tags = @('Sales'); administrativeUnitName = 'PAW' }
                    @{ groupId = '22222222-2222-2222-2222-222222222222'; tags = @('Other', 'Shared') }
                )[0..($Count - 1)]
                & $managerHandler -Request $request -TagPolicyBlob (ConvertTo-Json -InputObject @($rules) -Depth 8)
                Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter {
                    $Value.StatusCode -eq 200 -and
                    ($Value.Body | ConvertFrom-Json).policy.Count -eq $Count -and
                    ($Value.Body | ConvertFrom-Json).policy[0].groupId -is [string] -and
                    ($Value.Body | ConvertFrom-Json).policy[0].administrativeUnitName -eq 'PAW'
                }
            }
            It 'saves older scope metadata as Group Tag only without Intune calls' {
                $request.Method = 'PUT'
                $request.Query = @{}
                $request.Body = @{
                    policy = @(@{
                        name = 'Older rule'
                        groupId = '11111111-1111-1111-1111-111111111111'
                        scopeTag = 'Sales'
                        extensionAttributes = @{}
                    })
                }
                Mock Invoke-RestMethod { throw 'Unexpected Graph request' }
                & $managerHandler -Request $request -TagPolicyBlob '[{"groupId":"11111111-1111-1111-1111-111111111111","tags":["Sales"]}]'
                Should -Invoke Set-ManagementPolicyBlob -Times 1 -Exactly -ParameterFilter {
                    ($Json | ConvertFrom-Json)[0].groupTag -eq 'Sales' -and
                    'scopeTag' -notin ($Json | ConvertFrom-Json)[0].PSObject.Properties.Name
                }
                Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter {
                    $Name -eq 'Response' -and $Value.StatusCode -eq 200
                }
                Should -Invoke Get-AzAccessToken -Times 0
                Should -Invoke Invoke-RestMethod -Times 0
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
Describe 'Empty policy authorization' {
    BeforeAll {
        Import-Module Az.Accounts
        function Push-OutputBinding { param($Name, $Value) }
        $savedTagPolicy = $env:TAG_AUTHORIZATION_POLICY
    }
    AfterAll {
        $env:TAG_AUTHORIZATION_POLICY = $savedTagPolicy
    }
    BeforeEach {
        $env:TAG_AUTHORIZATION_POLICY = '[{"groupId":"11111111-1111-1111-1111-111111111111","tags":["Sales"]}]'
        $request = @{
            Method = 'GET'
            Headers = @{ 'x-ms-client-principal' = 'mock' }
            Query = @{}
            Body = @{ groupTag = 'Sales' }
        }
        Mock Import-Module {}
        Mock Get-AzAccessToken { [pscustomobject]@{ Token = 'test' } }
        Mock ConvertFrom-ClientPrincipalHeader {
            [pscustomobject]@{ claims = @(
                [pscustomobject]@{ typ = 'oid'; val = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
                [pscustomobject]@{ typ = 'groups'; val = '11111111-1111-1111-1111-111111111111' }
            ) }
        }
        Mock Invoke-RestMethod { [pscustomobject]@{ value = @() } }
        Mock Invoke-RestMethod { throw 'Unexpected Graph request' } -ModuleName AutopilotImport
        Mock Push-OutputBinding {}
        Mock Write-Error {}
    }
    It 'returns no authorized tags for an empty blob rather than stale fallback rules' {
        & (Join-Path $PSScriptRoot '..\FunctionApp\GetAuthorizedTags\run.ps1') -Request $request -TagPolicyBlob '[]'
        Should -Invoke Push-OutputBinding -Times 1 -ParameterFilter {
            $body = $Value.Body | ConvertFrom-Json
            $Value.StatusCode -eq 200 -and $body.tags -is [array] -and $body.tags.Count -eq 0 -and
            $body.policies -is [array] -and $body.policies.Count -eq 0
        }
        Should -Invoke Invoke-RestMethod -ModuleName AutopilotImport -Times 0
    }
    It 'returns no devices before any rules exist' {
        & (Join-Path $PSScriptRoot '..\FunctionApp\ManageDeviceTags\run.ps1') -Request $request -TagPolicyBlob '[]'
        Should -Invoke Push-OutputBinding -Times 1 -ParameterFilter {
            $Value.StatusCode -eq 200 -and ($Value.Body | ConvertFrom-Json).devices.Count -eq 0
        }
        Should -Invoke Invoke-RestMethod -ModuleName AutopilotImport -Times 0
    }
    It 'denies imports with an empty blob even when legacy rules and token groups would allow them' {
        $request.Method = 'POST'
        & (Join-Path $PSScriptRoot '..\FunctionApp\ImportDevice\run.ps1') -Request $request -TagPolicyBlob '[]'
        Should -Invoke Push-OutputBinding -Times 1 -ParameterFilter {
            $Value.StatusCode -eq 403 -and ($Value.Body | ConvertFrom-Json).error -eq 'groupTagNotAllowed'
        }
        Should -Invoke Invoke-RestMethod -ModuleName AutopilotImport -Times 0
    }
    It 'does not disguise missing or malformed configuration <Json> as an empty policy' -ForEach @(
        @{ Json = ''; Status = 500; ExpectedError = 'serviceNotConfigured' }
        @{ Json = ' '; Status = 500; ExpectedError = 'serviceNotConfigured' }
        @{ Json = 'null'; Status = 500; ExpectedError = 'serviceNotConfigured' }
        @{ Json = 'invalid'; Status = 401; ExpectedError = 'invalidPrincipal' }
    ) {
        $env:TAG_AUTHORIZATION_POLICY = $Json
        & (Join-Path $PSScriptRoot '..\FunctionApp\GetAuthorizedTags\run.ps1') -Request $request -TagPolicyBlob ''
        Should -Invoke Push-OutputBinding -Times 1 -ParameterFilter {
            $Value.StatusCode -eq $Status -and ($Value.Body | ConvertFrom-Json).error -eq $ExpectedError
        }
    }
}

Describe 'Recently completed tag changes in the device list' {
    BeforeAll {
        Import-Module Az.Accounts
        function Push-OutputBinding { param($Name, $Value) }
        $deviceId = 'cd1f0bdf-4229-4328-9658-9f0d91614b74'
        $now = [datetimeoffset]::UtcNow
        $completed = [pscustomobject]@{
            operationType = 'tagChange'; registeredDeviceId = $deviceId.ToUpperInvariant()
            previousGroupTag = 'PAW'; groupTag = 'VIP'
            processingCompletedAtUtc = $now.AddMinutes(-1).ToString('o')
        }
    }
    It 'reports the confirmed destination tag while Autopilot still returns the previous tag' {
        $devices = @(
            [pscustomobject]@{ id = $deviceId; groupTag = 'paw' }
            [pscustomobject]@{ id = 'other'; groupTag = 'PAW' }
        )
        $result = @(Resolve-RecentTagChangeGroupTag -Device $devices -AuditRecord @($completed) -CompletedAfterUtc $now.AddMinutes(-60))
        $result.groupTag | Should -Be @('VIP', 'PAW')
    }
    It 'ignores <Name>' -ForEach @(
        @{ Name = 'failed changes'; Change = @{ processingFailedAtUtc = '9999-12-31T00:00:00.0000000Z' } }
        @{ Name = 'incomplete changes'; Change = @{ processingCompletedAtUtc = '' } }
        @{ Name = 'old completions'; Change = @{ processingCompletedAtUtc = [datetimeoffset]::UtcNow.AddHours(-2).ToString('o') } }
        @{ Name = 'other operation types'; Change = @{ operationType = 'import' } }
        @{ Name = 'devices whose tag changed independently'; Change = @{ previousGroupTag = 'Sales' } }
    ) {
        $record = $completed.PSObject.Copy()
        foreach ($entry in $Change.GetEnumerator()) {
            $record | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
        }
        $device = [pscustomobject]@{ id = $deviceId; groupTag = 'PAW' }
        (Resolve-RecentTagChangeGroupTag -Device @($device) -AuditRecord @($record) -CompletedAfterUtc $now.AddMinutes(-60)).groupTag |
            Should -Be 'PAW'
    }
    It 'uses the newest completed change for a device' {
        $older = $completed.PSObject.Copy()
        $older.groupTag = 'BG-Default'
        $older.processingCompletedAtUtc = $now.AddMinutes(-5).ToString('o')
        $device = [pscustomobject]@{ id = $deviceId; groupTag = 'PAW' }
        (Resolve-RecentTagChangeGroupTag -Device @($device) -AuditRecord @($completed, $older) -CompletedAfterUtc $now.AddMinutes(-60)).groupTag |
            Should -Be 'VIP'
    }
    Context 'device list endpoint' {
        BeforeEach {
            $request = @{ Method = 'GET'; Headers = @{ 'x-ms-client-principal' = 'mock' }; Query = @{} }
            Mock Import-Module {}
            Mock Get-AzAccessToken { [pscustomobject]@{ Token = 'test' } }
            Mock ConvertFrom-ClientPrincipalHeader { [pscustomobject]@{ claims = @() } }
            Mock Get-CurrentPolicyPrincipal { $Principal }
            Mock Get-AuthorizedGroupTags { @('PAW', 'VIP') }
            Mock Get-ImportAuditAccessToken { ConvertTo-SecureString 'storage' -AsPlainText -Force }
            Mock Invoke-RestMethod {
                [pscustomobject]@{ value = @([pscustomobject]@{
                    id = $deviceId; serialNumber = 'SN1'; groupTag = 'PAW'; enrollmentState = 'notContacted'
                }) }
            }
            Mock Push-OutputBinding {}
            Mock Write-Warning {}
        }
        It 'overlays recent completed tag changes from the audit history' {
            Mock Get-ImportAuditHistory { @($completed) }
            & (Join-Path $PSScriptRoot '..\FunctionApp\ManageDeviceTags\run.ps1') -Request $request -TagPolicyBlob '[{"groupId":"11111111-1111-1111-1111-111111111111","tags":["PAW"]}]'
            Should -Invoke Push-OutputBinding -Times 1 -ParameterFilter {
                $Value.StatusCode -eq 200 -and ($Value.Body | ConvertFrom-Json).devices[0].groupTag -eq 'VIP'
            }
        }
        It 'still lists Autopilot tags when the audit history is unavailable' {
            Mock Get-ImportAuditHistory { throw 'Storage unavailable' }
            & (Join-Path $PSScriptRoot '..\FunctionApp\ManageDeviceTags\run.ps1') -Request $request -TagPolicyBlob '[{"groupId":"11111111-1111-1111-1111-111111111111","tags":["PAW"]}]'
            Should -Invoke Push-OutputBinding -Times 1 -ParameterFilter {
                $Value.StatusCode -eq 200 -and ($Value.Body | ConvertFrom-Json).devices[0].groupTag -eq 'PAW'
            }
            Should -Invoke Write-Warning -Times 1
        }
    }
}

Describe 'Live tag change progress' {
    BeforeAll {
        Import-Module Az.Accounts
        function Push-OutputBinding { param($Name, $Value) }
    }
    It 'formats <Name> as ISO 8601 UTC' -ForEach @(
        @{ Name = 'UTC DateTime values'; Value = [datetime]::new(2026, 10, 19, 11, 36, 57, [DateTimeKind]::Utc) }
        @{ Name = 'deserialized DateTime values without kind'; Value = [datetime]::new(2026, 10, 19, 11, 36, 57, [DateTimeKind]::Unspecified) }
        @{ Name = 'DateTimeOffset values'; Value = [datetimeoffset]::new(2026, 10, 19, 13, 36, 57, [timespan]::FromHours(2)) }
        @{ Name = 'ISO text'; Value = '2026-10-19T11:36:57Z' }
        @{ Name = 'culture text without a zone'; Value = '10/19/2026 11:36:57' }
    ) {
        ConvertTo-AuditTimestamp $Value | Should -Be '2026-10-19T11:36:57.0000000Z'
    }
    It 'returns null for empty timestamps' {
        ConvertTo-AuditTimestamp $null | Should -BeNullOrEmpty
        ConvertTo-AuditTimestamp '' | Should -BeNullOrEmpty
    }
    It 'reports the <Expected> stage' -ForEach @(
        @{ Expected = 'queued'; Record = @{ queuedAtUtc = '2026-10-19T11:36:57Z' } }
        @{ Expected = 'processing'; Record = @{ processingStartedAtUtc = '2026-10-19T11:37:17Z' } }
        @{ Expected = 'complete'; Record = @{ processingStartedAtUtc = '2026-10-19T11:37:17Z'; processingCompletedAtUtc = '2026-10-19T11:37:21Z' } }
    ) {
        Get-TagChangeProcessingStage -AuditRecord ([pscustomobject] $Record) | Should -Be $Expected
    }
    It 'returns processing progress and ISO timestamps from the status endpoint' {
        $operationId = '445fc072-2036-41ba-b21e-c9b579ae476c'
        $request = @{ Method = 'GET'; Headers = @{ 'x-ms-client-principal' = 'mock' }; Query = @{ operationId = $operationId } }
        Mock Import-Module {}
        Mock Get-AzAccessToken { [pscustomobject]@{ Token = 'test' } }
        Mock ConvertFrom-ClientPrincipalHeader { [pscustomobject]@{ claims = @([pscustomobject]@{ typ = 'oid'; val = 'actor' }) } }
        Mock Get-CurrentPolicyPrincipal { $Principal }
        Mock Get-AuthorizedGroupTags { @('VIP') }
        Mock Get-ImportAuditAccessToken { ConvertTo-SecureString 'storage' -AsPlainText -Force }
        Mock Get-ImportAuditRecords {
            @{ '445fc072-2036-41ba-b21e-c9b579ae476c' = [pscustomobject]@{
                operationType = 'tagChange'; actorObjectId = 'actor'; serialNumber = 'SN1'
                groupTag = 'BG-Default'; previousGroupTag = 'VIP'
                requestReceivedAtUtc = [datetime]::new(2026, 10, 19, 11, 36, 57, [DateTimeKind]::Unspecified)
                processingStartedAtUtc = '2026-10-19T11:37:17Z'
                autopilotGroupTagUpdatedAtUtc = '2026-10-19T11:37:18Z'
            } }
        }
        Mock Push-OutputBinding {}
        & (Join-Path $PSScriptRoot '..\FunctionApp\ManageDeviceTags\run.ps1') -Request $request -TagPolicyBlob '[{"groupId":"11111111-1111-1111-1111-111111111111","tags":["VIP"]}]'
        Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter {
            $Value.StatusCode | Should -Be 200
            $body = $Value.Body | ConvertFrom-Json -DateKind String
            $body.workflowStatus | Should -Be 'pending'
            $body.processingStage | Should -Be 'processing'
            $body.previousGroupTag | Should -Be 'VIP'
            $body.requestReceivedAtUtc | Should -Be '2026-10-19T11:36:57.0000000Z'
            $body.autopilotGroupTagUpdatedAtUtc | Should -Be '2026-10-19T11:37:18.0000000Z'
            $body.processingCompletedAtUtc | Should -BeNullOrEmpty
            $true
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
            $body.PSObject.Properties.Name | Should -Not -Contain 'scopeTagStatus'
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
    It 'reports the processing stage and step timestamps of a pending import' {
        Mock Get-ImportAuditRecords {
            @{ $id = [pscustomobject]@{
                graphImportCreatedAtUtc = '2026-10-19T13:50:00Z'; queuedAtUtc = '2026-10-19T13:50:01Z'
                processingStartedAtUtc = '2026-10-19T13:51:00Z'; processingAttempt = 2
            } }
        }
        & $handler -Request $request -TagPolicyBlob $policy
        Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter {
            $body = $Value.Body | ConvertFrom-Json -DateKind String
            $body.workflowStatus | Should -Be 'pending'
            $body.processingStage | Should -Be 'processing'
            $body.processingStartedAtUtc | Should -Be '2026-10-19T13:51:00.0000000Z'
            $body.processingCompletedAtUtc | Should -BeNullOrEmpty
            $body.processingAttempt | Should -Be 2
            $true
        }
    }
    It 'still reports import status without a Group Tag action when the audit store is unavailable' {
        Mock Get-DevicePolicyActions { [pscustomobject]@{ extensionAttributes = $expectedAttributes } }
        Mock Get-ImportAuditRecords { throw 'Storage unavailable' }
        & $handler -Request $request -TagPolicyBlob $policy
        Should -Invoke Push-OutputBinding -Times 1 -Exactly -ParameterFilter {
            $Value.StatusCode -eq 200 -and ($Value.Body | ConvertFrom-Json).workflowStatus -eq 'complete'
        }
    }
}

Describe 'Restricted administrative unit role script' {
    BeforeAll {
        $grantScriptPath = Join-Path $PSScriptRoot '..\Scripts\Grant-ManagedIdentityAdministrativeUnitRole.ps1'
        $grantScriptText = Get-Content -LiteralPath $grantScriptPath -Raw
    }
    It 'parses without errors' {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($grantScriptPath, [ref] $tokens, [ref] $errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }
    It 'creates a custom role that can update all extension attribute sets' {
        foreach ($action in @(
                'microsoft.directory/devices/standard/read'
                'microsoft.directory/devices/extensionAttributeSet1/update'
                'microsoft.directory/devices/extensionAttributeSet2/update'
                'microsoft.directory/devices/extensionAttributeSet3/update')) {
            $grantScriptText | Should -Match ([regex]::Escape("'$action'"))
        }
        $grantScriptText | Should -Match "RoleDisplayName = 'Autopilot Import Device Attribute Writer'"
    }
    It 'does not assign the built-in Cloud Device Administrator role' {
        $grantScriptText | Should -Not -Match '7698a772-787b-4ac8-901f-60d6b08affd2'
    }
}
