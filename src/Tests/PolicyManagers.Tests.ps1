# Project-Version: 1.4.20261020.15
# Author: andreas.lucas@outlook.com (aka Kili)

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
}

Describe 'Policy manager administration API' {
    BeforeEach {
        $handler = Join-Path $PSScriptRoot '..\FunctionApp\ManagePolicyManagers\run.ps1'
        $savedResourceId = $env:FUNCTION_RESOURCE_ID
        $savedTenantId = $env:TENANT_ID
        $env:TENANT_ID = '11111111-1111-1111-1111-111111111111'
        $env:FUNCTION_RESOURCE_ID = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/test/providers/Microsoft.Web/sites/test'
        $caller = '33333333-3333-3333-3333-333333333333'
        $installer = '44444444-4444-4444-4444-444444444444'
        $additional = '55555555-5555-5555-5555-555555555555'
        $newId = '66666666-6666-6666-6666-666666666666'
        $policyJson = @{
            installerPrincipalId = $installer
            additionalPrincipalIds = @($additional)
            allowIntuneRoleAdministrators = $true
        } | ConvertTo-Json -Compress
        $principal = @{ claims = @(@{ typ = 'oid'; val = $caller }) } | ConvertTo-Json -Compress
        $claims = @{ oid = $caller; tid = $env:TENANT_ID } | ConvertTo-Json -Compress
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($claims)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $request = @{
            Method = 'GET'; Query = @{}
            Headers = @{
                'x-ms-client-principal' = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($principal))
                'x-autopilot-arm-token' = "header.$payload.signature"
            }
        }
        $responses = [Collections.Generic.List[object]]::new()
        $writes = [Collections.Generic.List[object]]::new()
        $settings = [pscustomobject]@{ properties = [pscustomobject]@{
            MANAGER_AUTHORIZATION_POLICY = $policyJson
            UNRELATED = 'preserve-me'
        } }
        $role = [pscustomobject]@{ properties = [pscustomobject]@{
            scope = '/subscriptions/22222222-2222-2222-2222-222222222222'
            roleDefinitionId = '/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c'
        } }
        Mock Import-Module {}
        Mock Write-Error {}
        Mock Write-ManagementAuditEvent {}
        Mock Get-ManagementAuditHistory { @{ events = @(); continuation = '' } }
        Mock Push-OutputBinding { $responses.Add($Value) }
        Mock Invoke-RestMethod {
            param($Uri, $Method, $Body)
            if ($Uri -like '*roleAssignments*') {
                return [pscustomobject]@{ value = @($role) }
            }
            if ($Method -eq 'PUT') {
                $writes.Add(($Body | ConvertFrom-Json))
                return $settings
            }
            return $settings
        }
        Mock Get-AzAccessToken { @{ Token = ConvertTo-SecureString 'graph' -AsPlainText -Force } }
        Mock Find-EntraPolicyGroups {
            param($SearchText, $ObjectType)
            @{ groups = @(@{ id = $SearchText; displayName = "Test $ObjectType" }); hasMore = $false }
        }
    }
    AfterEach {
        $env:FUNCTION_RESOURCE_ID = $savedResourceId
        $env:TENANT_ID = $savedTenantId
    }
    It 'requires API authentication before calling ARM' {
        $request.Headers.Remove('x-ms-client-principal')
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 401
        Should -Invoke Invoke-RestMethod -Times 0
    }
    It 'allows history only after delegated Owner or Contributor authorization' {
        $request.Query.history = 'true'
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 200
        Should -Invoke Get-ManagementAuditHistory -Times 1 -ParameterFilter { $Kind -eq 'managers' }
        Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { $Uri -like '*config/appsettings*' }
    }
    It 'does not expose manager history to an ordinary policy manager' {
        $request.Query.history = 'true'
        Mock Invoke-RestMethod { [pscustomobject]@{ value = @() } }
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 403
        Should -Invoke Get-ManagementAuditHistory -Times 0
    }
    It 'rejects mixing eligibility and history reads' {
        $request.Query = @{ access = 'true'; history = 'true' }
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 400
        Should -Invoke Get-ManagementAuditHistory -Times 0
    }
    It 'reports invalid history continuation explicitly' {
        $request.Query.history = 'true'
        Mock Get-ManagementAuditHistory { throw [ArgumentException]::new('Invalid continuation') }
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 400
    }
    It 'blocks a manager change if the requested audit event cannot be saved' {
        $request.Method = 'PUT'
        $request.Body = @{ additionalPrincipalIds = @(); expectedPolicy = $policyJson }
        Mock Write-ManagementAuditEvent { throw 'Audit unavailable' }
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 502
        $writes.Count | Should -Be 0
    }
    It 'records requested before mutation and applied only after mutation' {
        $request.Method = 'PUT'
        $request.Body = @{ additionalPrincipalIds = @(); expectedPolicy = $policyJson }
        Mock Write-ManagementAuditEvent {
            param($Stage)
            if ($Stage -eq 'requested') { $writes.Count | Should -Be 0 }
            if ($Stage -eq 'applied') { $writes.Count | Should -Be 1 }
        }
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 200
        Should -Invoke Write-ManagementAuditEvent -Times 1 -ParameterFilter { $Stage -eq 'requested' }
        Should -Invoke Write-ManagementAuditEvent -Times 1 -ParameterFilter { $Stage -eq 'applied' }
    }
    It 'does not claim success when audit confirmation fails after a manager change' {
        $request.Method = 'PUT'
        $request.Body = @{ additionalPrincipalIds = @(); expectedPolicy = $policyJson }
        Mock Write-ManagementAuditEvent { throw 'Confirmation failed' } -ParameterFilter { $Stage -eq 'applied' }
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 502
        $writes.Count | Should -Be 1
        ($responses[0].Body | ConvertFrom-Json).message | Should -Match 'verify the current state'
        Should -Invoke Write-ManagementAuditEvent -Times 1 -ParameterFilter { $Stage -eq 'failed' }
    }
    It 'requires a separate ARM token' {
        $request.Headers.Remove('x-autopilot-arm-token')
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 401
        Should -Invoke Invoke-RestMethod -Times 0
    }
    It 'requires API authentication for the visibility check' {
        $request.Query.access = 'true'
        $request.Headers.Remove('x-ms-client-principal')
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 401
        Should -Invoke Get-AzAccessToken -Times 0
        Should -Invoke Invoke-RestMethod -Times 0
    }
    It 'checks <RoleName> at <ScopeKind> without delegated ARM consent' -TestCases @(
        @{ RoleName = 'Owner'; ScopeKind = 'Function'; RoleId = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635' }
        @{ RoleName = 'Contributor'; ScopeKind = 'Function'; RoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c' }
        @{ RoleName = 'Owner'; ScopeKind = 'Ancestor'; RoleId = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635' }
        @{ RoleName = 'Contributor'; ScopeKind = 'Ancestor'; RoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c' }
    ) {
        param($RoleName, $ScopeKind, $RoleId)
        $request.Query.access = 'true'
        $request.Headers.Remove('x-autopilot-arm-token')
        $role.properties.roleDefinitionId = "/roles/$RoleId"
        if ($ScopeKind -eq 'Function') { $role.properties.scope = $env:FUNCTION_RESOURCE_ID }
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 200
        $result = $responses[0].Body | ConvertFrom-Json
        $result.canManagePolicyManagers | Should -BeTrue
        @($result.PSObject.Properties.Name | Sort-Object) | Should -Be @('canManagePolicyManagers', 'correlationId')
        Should -Invoke Get-AzAccessToken -ParameterFilter { $ResourceUrl -eq 'https://management.azure.com/' } -Times 1
        Should -Invoke Invoke-RestMethod -ParameterFilter {
            $Uri -like '*assignedTo*33333333*' -and
            (ConvertFrom-SecureString $Token -AsPlainText) -eq 'graph'
        } -Times 1
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -like '*appsettings*' } -Times 0
        Should -Invoke Find-EntraPolicyGroups -Times 0
    }
    It 'returns false for an additional policy manager with only Reader' {
        $request.Query.access = 'true'
        $request.Headers.Remove('x-autopilot-arm-token')
        $role.properties.roleDefinitionId = '/roles/acdd72a7-3385-48ef-bd42-f606fba81ae7'
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 200
        ($responses[0].Body | ConvertFrom-Json).canManagePolicyManagers | Should -BeFalse
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -like '*appsettings*' } -Times 0
    }
    It 'does not infer Azure rights from being the protected installer' {
        $request.Query.access = 'true'
        $installerPrincipal = @{ claims = @(@{ typ = 'oid'; val = $installer }) } | ConvertTo-Json -Compress
        $request.Headers['x-ms-client-principal'] = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($installerPrincipal))
        Mock Invoke-RestMethod { [pscustomobject]@{ value = @() } }
        & $handler -Request $request
        ($responses[0].Body | ConvertFrom-Json).canManagePolicyManagers | Should -BeFalse
    }
    It 'hides administration for a Contributor on another Function' {
        $request.Query.access = 'true'
        $role.properties.scope = $env:FUNCTION_RESOURCE_ID + '-other'
        & $handler -Request $request
        ($responses[0].Body | ConvertFrom-Json).canManagePolicyManagers | Should -BeFalse
    }
    It 'uses the authenticated caller, not a caller ID supplied in the query' {
        $request.Query.access = 'true'
        $request.Query.callerId = $installer
        & $handler -Request $request
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -like '*assignedTo*33333333*' } -Times 1
    }
    It 'includes inherited group roles returned by ARM on later pages' {
        $request.Query.access = 'true'
        $role.properties | Add-Member -NotePropertyName principalType -NotePropertyValue Group
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -like '*next-page*') { return [pscustomobject]@{ value = @($role) } }
            [pscustomobject]@{ value = @(); nextLink = 'https://management.azure.com/next-page' }
        }
        & $handler -Request $request
        ($responses[0].Body | ConvertFrom-Json).canManagePolicyManagers | Should -BeTrue
    }
    It 'does not follow a role pagination link outside ARM' {
        $request.Query.access = 'true'
        Mock Invoke-RestMethod { [pscustomobject]@{ value = @(); nextLink = 'https://example.test/roles' } }
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 502
        Should -Invoke Invoke-RestMethod -Times 1
        Should -Invoke Write-Error -Times 1
    }
    It 'rejects invalid access modes without any Azure access' -TestCases @(
        @{ Method = 'PUT'; Access = 'true'; Search = $null }
        @{ Method = 'GET'; Access = 'false'; Search = $null }
        @{ Method = 'GET'; Access = 'true'; Search = 'Test' }
    ) {
        param($Method, $Access, $Search)
        $request.Method = $Method
        $request.Query = @{ access = $Access; search = $Search }
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 400
        Should -Invoke Get-AzAccessToken -Times 0
        Should -Invoke Invoke-RestMethod -Times 0
    }
    It 'rejects invalid principals before acquiring the identity token' {
        $request.Query.access = 'true'
        $request.Headers['x-ms-client-principal'] = 'invalid'
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 401
        Should -Invoke Get-AzAccessToken -Times 0
    }
    It 'reports identity permission failures as errors, not ordinary denied access' {
        $request.Query.access = 'true'
        Mock Invoke-RestMethod {
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Forbidden', $response)
        }
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 502
        ($responses[0].Body | ConvertFrom-Json).error | Should -Be 'azureAuthorizationUnavailable'
        Should -Invoke Write-Error -Times 1
    }
    It 'reports identity token failures explicitly' {
        $request.Query.access = 'true'
        Mock Get-AzAccessToken { throw 'Identity unavailable' }
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 502
        Should -Invoke Write-Error -Times 1
        Should -Invoke Invoke-RestMethod -Times 0
    }
    It 'reports malformed ARM responses instead of treating them as no assignments' {
        $request.Query.access = 'true'
        Mock Invoke-RestMethod { [pscustomobject]@{ unexpected = @() } }
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 502
        Should -Invoke Write-Error -Times 1
    }
    It 'rejects mismatched API and ARM users' {
        $otherPrincipal = @{ claims = @(@{ typ = 'oid'; val = $installer }) } | ConvertTo-Json -Compress
        $request.Headers['x-ms-client-principal'] = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($otherPrincipal))
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 401
        Should -Invoke Invoke-RestMethod -Times 0
    }

    Describe 'Manager visibility infrastructure' {
        It 'grants only role-assignment read at Function scope' {
            $bicep = Get-Content (Join-Path $PSScriptRoot '..\Infrastructure\main.bicep') -Raw
            $roleDefinition = [regex]::Match($bicep, "(?s)resource managerAccessReaderRole .*?(?=\r?\n// Inherited)").Value
            $roleDefinition | Should -Match "'Microsoft.Authorization/roleAssignments/read'"
            $roleDefinition | Should -Not -Match 'roleAssignments/write|roleDefinitions/write|Microsoft.Web/|''\*'''
            $roleDefinition | Should -Match 'assignableScopes:\s*\[\s*resourceGroup\(\).id'
            $assignment = [regex]::Match($bicep, '(?s)resource functionManagerAccessReader .*?(?=\r?\n// Easy Auth)').Value
            $assignment | Should -Match 'scope: functionApp'
            $assignment | Should -Match 'roleDefinitionId: managerAccessReaderRole.id'
            $assignment | Should -Match 'principalId: functionApp.identity.principalId'
        }
    }
    It 'requires configured deployment coordinates' {
        $env:FUNCTION_RESOURCE_ID = ''
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 500
    }
    It 'allows an inherited Contributor and returns only manager settings' {
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 200
        $result = $responses[0].Body | ConvertFrom-Json
        $result.policy.installerPrincipalId | Should -Be $installer
        $result.expectedPolicy | Should -BeExactly $policyJson
        $responses[0].Body | Should -Not -Match 'preserve-me'
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -like "*assignedTo*33333333*" } -Times 1
    }
    It 'does not authorize a Reader or policy manager without Azure Owner/Contributor' {
        $role.properties.roleDefinitionId = '/roles/acdd72a7-3385-48ef-bd42-f606fba81ae7'
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 403
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -like '*appsettings*' } -Times 0
    }
    It 'rejects Contributor on a sibling Function App' {
        $role.properties.scope = $env:FUNCTION_RESOURCE_ID + '-other'
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 403
    }
    It 'does not treat unverified token claims as authorization' {
        Mock Invoke-RestMethod { throw 'ARM unavailable' }
        & $handler -Request $request -ErrorAction SilentlyContinue
        [int] $responses[0].StatusCode | Should -Be 502
        Should -Invoke Write-Error -Times 1
    }
    It 'rejects tokens that ARM refuses without reading settings' {
        Mock Invoke-RestMethod {
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Forbidden', $response)
        }
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 403
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -like '*appsettings*' } -Times 0
    }
    It 'follows role pages before making its authorization decision' {
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -like '*next-page*') { return [pscustomobject]@{ value = @($role) } }
            return [pscustomobject]@{ value = @(); nextLink = 'https://management.azure.com/next-page' }
        } -ParameterFilter { $Uri -notlike '*appsettings*' }
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 200
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -like '*next-page*' } -Times 1
    }
    It 'searches both users and groups after authorizing the caller' {
        $request.Query.search = 'Test'
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 200
        $result = $responses[0].Body | ConvertFrom-Json
        $result.groups.Count | Should -Be 2
        Should -Invoke Find-EntraPolicyGroups -ParameterFilter { $ObjectType -eq 'users' } -Times 1
        Should -Invoke Find-EntraPolicyGroups -ParameterFilter { $ObjectType -eq 'groups' } -Times 1
    }
    It 'validates search length before Graph calls' {
        $request.Query.search = 'x'
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 400
        Should -Invoke Find-EntraPolicyGroups -Times 0
    }
    It 'saves a selected manager while preserving the installer and unrelated settings' {
        $request.Method = 'PUT'
        $request.Body = @{ additionalPrincipalIds = @($newId, $installer); expectedPolicy = $policyJson }
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 200
        $writes.Count | Should -Be 1
        $writes[0].properties.UNRELATED | Should -Be 'preserve-me'
        $saved = $writes[0].properties.MANAGER_AUTHORIZATION_POLICY | ConvertFrom-Json
        $saved.installerPrincipalId | Should -Be $installer
        $saved.additionalPrincipalIds | Should -Be @($newId)
        $saved.allowIntuneRoleAdministrators | Should -BeTrue
    }
    It 'can remove all additional managers but never removes the installer' {
        $request.Method = 'PUT'
        $request.Body = @{ additionalPrincipalIds = @(); expectedPolicy = $policyJson }
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 200
        $saved = $writes[0].properties.MANAGER_AUTHORIZATION_POLICY | ConvertFrom-Json
        $saved.installerPrincipalId | Should -Be $installer
        $saved.additionalPrincipalIds.Count | Should -Be 0
    }
    It 'rejects stale manager edits without writing settings' {
        $request.Method = 'PUT'
        $request.Body = @{ additionalPrincipalIds = @($newId); expectedPolicy = '{}' }
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 409
        $writes.Count | Should -Be 0
    }
    It 'rejects malformed manager IDs without writing settings' {
        $request.Method = 'PUT'
        $request.Body = @{ additionalPrincipalIds = @('not-a-guid'); expectedPolicy = $policyJson }
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 400
        $writes.Count | Should -Be 0
    }
    It 'requires an explicit array rather than silently clearing a malformed request' {
        $request.Method = 'PUT'
        $request.Body = @{ additionalPrincipalIds = $null; expectedPolicy = $policyJson }
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 400
        $writes.Count | Should -Be 0
    }
    It 'checks for a competing manager change again after Graph validation' {
        $reads = [Collections.Generic.List[bool]]::new()
        Mock Invoke-RestMethod {
            $reads.Add($true)
            if ($reads.Count -gt 1) {
                return [pscustomobject]@{ properties = [pscustomobject]@{ MANAGER_AUTHORIZATION_POLICY = '{}' } }
            }
            return $settings
        } -ParameterFilter { $Uri -like '*appsettings/list*' }
        $request.Method = 'PUT'
        $request.Body = @{ additionalPrincipalIds = @($newId); expectedPolicy = $policyJson }
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 409
        $writes.Count | Should -Be 0
    }
    It 'rejects new objects that are neither a user nor a group' {
        Mock Find-EntraPolicyGroups { @{ groups = @(); hasMore = $false } }
        $request.Method = 'PUT'
        $request.Body = @{ additionalPrincipalIds = @($newId); expectedPolicy = $policyJson }
        & $handler -Request $request
        [int] $responses[0].StatusCode | Should -Be 400
        $writes.Count | Should -Be 0
    }
    It 'reports settings-write failure instead of success' {
        Mock Invoke-RestMethod { throw 'Write denied' } -ParameterFilter { $Method -eq 'PUT' }
        $request.Method = 'PUT'
        $request.Body = @{ additionalPrincipalIds = @(); expectedPolicy = $policyJson }
        & $handler -Request $request -ErrorAction SilentlyContinue
        [int] $responses[0].StatusCode | Should -Be 502
    }

    Context 'Configuration backup and restore' {
        BeforeEach {
            $request.Query = @{ backup = 'true' }
            $ruleId = '77777777-7777-7777-7777-777777777777'
            $sourceInstaller = '88888888-8888-8888-8888-888888888888'
            $backup = @{
                format = 'autopilot-importer-configuration'; schemaVersion = 1
                tenantId = $env:TENANT_ID
                sourceResourceId = $env:FUNCTION_RESOURCE_ID + '-source'
                createdAtUtc = [datetime]::UtcNow.ToString('o')
                rules = @(@{
                    ruleId = $ruleId; name = 'Backup rule'; groupId = $newId; groupTag = 'Restore'
                    description = "Line one`nLine two"; extensionAttributes = @{ extensionAttribute2 = 'Test' }
                    deviceGroupIds = @($additional); administrativeUnitName = 'Devices'
                })
                managerPolicy = @{
                    installerPrincipalId = $sourceInstaller; additionalPrincipalIds = @($newId, $installer)
                    allowIntuneRoleAdministrators = $false
                }
            }
            $blobWrites = [Collections.Generic.List[object]]::new()
            Mock Set-ManagementPolicyBlob {
                param($Json)
                $blobWrites.Add(($Json | ConvertFrom-Json -NoEnumerate))
            }
            Mock Assert-DevicePolicyGroups {}
            Mock Resolve-EntraAdministrativeUnit { @{ id = 'unit' } }
            $request.Body = @{ backup = $backup; expectedRules = @(); expectedPolicy = $policyJson }
        }
        It 'exports tenant metadata, complete rules and manager policy without unrelated app settings' {
            $json = ConvertTo-Json -InputObject $backup.rules -Depth 10
            & $handler -Request $request -TagPolicyBlob $json
            [int] $responses[0].StatusCode | Should -Be 200
            $result = $responses[0].Body | ConvertFrom-Json
            $result.backup.format | Should -Be 'autopilot-importer-configuration'
            $result.backup.schemaVersion | Should -Be 1
            $result.backup.tenantId | Should -Be $env:TENANT_ID
            $result.backup.rules[0].ruleId | Should -Be $ruleId
            $result.backup.rules[0].description | Should -Be "Line one`nLine two"
            $result.backup.rules[0].extensionAttributes.extensionAttribute2 | Should -Be 'Test'
            $result.backup.managerPolicy.installerPrincipalId | Should -Be $installer
            $result.expectedPolicy | Should -BeExactly $policyJson
            $responses[0].Headers['Cache-Control'] | Should -Be 'no-store'
            $responses[0].Body | Should -Not -Match 'preserve-me'
            $blobWrites.Count | Should -Be 0
            $writes.Count | Should -Be 0
        }
        It 'exports a valid empty policy and requires the delegated ARM token' {
            & $handler -Request $request -TagPolicyBlob '[]'
            ($responses[0].Body | ConvertFrom-Json).backup.rules.Count | Should -Be 0
            $responses.Clear()
            $request.Headers.Remove('x-autopilot-arm-token')
            & $handler -Request $request -TagPolicyBlob '[]'
            [int] $responses[0].StatusCode | Should -Be 401
        }
        It 'does not expose backups to an ordinary policy manager' {
            $role.properties.roleDefinitionId = '/roles/reader'
            & $handler -Request $request -TagPolicyBlob '[]'
            [int] $responses[0].StatusCode | Should -Be 403
            Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { $Uri -like '*appsettings*' }
        }
        It 'rejects backup mixed with access, search or history' -ForEach @('access', 'search', 'history') {
            $request.Query[$_] = 'true'
            & $handler -Request $request -TagPolicyBlob '[]'
            [int] $responses[0].StatusCode | Should -Be 400
        }
        It 'restores another source in the same tenant, retaining the target installer and stable rules' {
            $request.Method = 'PUT'
            & $handler -Request $request -TagPolicyBlob '[]'
            [int] $responses[0].StatusCode | Should -Be 200
            $blobWrites.Count | Should -Be 1
            $blobWrites[0][0].ruleId | Should -Be $ruleId
            $blobWrites[0][0].description | Should -Be "Line one`nLine two"
            $saved = $writes[0].properties.MANAGER_AUTHORIZATION_POLICY | ConvertFrom-Json
            $saved.installerPrincipalId | Should -Be $installer
            $saved.additionalPrincipalIds | Should -Be @($newId)
            $saved.additionalPrincipalIds | Should -Not -Contain $sourceInstaller
            $saved.allowIntuneRoleAdministrators | Should -BeFalse
            $writes[0].properties.UNRELATED | Should -Be 'preserve-me'
            Should -Invoke Assert-DevicePolicyGroups -Times 1 -ParameterFilter { $GroupIds -contains $additional }
            Should -Invoke Resolve-EntraAdministrativeUnit -Times 1 -ParameterFilter { $AdministrativeUnitName -eq 'Devices' }
            Should -Invoke Write-ManagementAuditEvent -Times 2 -ParameterFilter { $Stage -eq 'requested' }
            Should -Invoke Write-ManagementAuditEvent -Times 2 -ParameterFilter { $Stage -eq 'applied' }
        }
        It 'can restore an empty rule set and no additional managers' {
            $request.Method = 'PUT'
            $backup.rules = @()
            $backup.managerPolicy.additionalPrincipalIds = @()
            & $handler -Request $request -TagPolicyBlob '[]'
            [int] $responses[0].StatusCode | Should -Be 200
            $blobWrites[0].Count | Should -Be 0
            (($writes[0].properties.MANAGER_AUTHORIZATION_POLICY | ConvertFrom-Json).additionalPrincipalIds).Count | Should -Be 0
        }
        It 'rejects invalid backup field <Field> before any writes' -ForEach @(
            @{ Field = 'tenantId'; Value = '99999999-9999-9999-9999-999999999999' }
            @{ Field = 'format'; Value = 'other' }
            @{ Field = 'schemaVersion'; Value = 2 }
            @{ Field = 'schemaVersion'; Value = '1' }
            @{ Field = 'rules'; Value = $null }
        ) {
            $request.Method = 'PUT'
            $backup[$Field] = $Value
            & $handler -Request $request -TagPolicyBlob '[]'
            [int] $responses[0].StatusCode | Should -Be 400
            $blobWrites.Count | Should -Be 0
            $writes.Count | Should -Be 0
            Should -Invoke Write-ManagementAuditEvent -Times 0
        }
        It 'rejects malformed rules or manager flags without writes' {
            $request.Method = 'PUT'
            $backup.managerPolicy.allowIntuneRoleAdministrators = 'false'
            & $handler -Request $request -TagPolicyBlob '[]'
            [int] $responses[0].StatusCode | Should -Be 400
            $blobWrites.Count | Should -Be 0
        }
        It 'rejects stale <Part> before either mutation' -ForEach @('rules', 'managers') {
            $request.Method = 'PUT'
            if ($_ -eq 'rules') { $request.Body.expectedRules = $backup.rules }
            else { $request.Body.expectedPolicy = '{}' }
            & $handler -Request $request -TagPolicyBlob '[]'
            [int] $responses[0].StatusCode | Should -Be 409
            $blobWrites.Count | Should -Be 0
            $writes.Count | Should -Be 0
        }
        It 'requires all referenced directory objects to exist before writing rules' {
            $request.Method = 'PUT'
            Mock Find-EntraPolicyGroups { @{ groups = @() } }
            & $handler -Request $request -TagPolicyBlob '[]'
            [int] $responses[0].StatusCode | Should -Be 400
            $blobWrites.Count | Should -Be 0
            $writes.Count | Should -Be 0
        }
        It 'does not mutate either store if the second requested audit fails' {
            $request.Method = 'PUT'
            Mock Write-ManagementAuditEvent { throw 'Audit unavailable' } -ParameterFilter { $Kind -eq 'managers' -and $Stage -eq 'requested' }
            & $handler -Request $request -TagPolicyBlob '[]'
            [int] $responses[0].StatusCode | Should -Be 502
            $blobWrites.Count | Should -Be 0
            $writes.Count | Should -Be 0
        }
        It 'rejects a competing manager change found during the pre-write recheck' {
            $request.Method = 'PUT'
            $reads = [Collections.Generic.List[bool]]::new()
            Mock Invoke-RestMethod {
                $reads.Add($true)
                if ($reads.Count -gt 1) {
                    return [pscustomobject]@{ properties = [pscustomobject]@{ MANAGER_AUTHORIZATION_POLICY = '{}' } }
                }
                return $settings
            } -ParameterFilter { $Uri -like '*appsettings/list*' }
            & $handler -Request $request -TagPolicyBlob '[]'
            [int] $responses[0].StatusCode | Should -Be 409
            $blobWrites.Count | Should -Be 0
            $writes.Count | Should -Be 0
        }
        It 'reports a manager conflict occurring after rules applied without overwriting managers' {
            $request.Method = 'PUT'
            $reads = [Collections.Generic.List[bool]]::new()
            Mock Invoke-RestMethod {
                $reads.Add($true)
                if ($reads.Count -gt 2) {
                    return [pscustomobject]@{ properties = [pscustomobject]@{ MANAGER_AUTHORIZATION_POLICY = '{}' } }
                }
                return $settings
            } -ParameterFilter { $Uri -like '*appsettings/list*' }
            & $handler -Request $request -TagPolicyBlob '[]'
            [int] $responses[0].StatusCode | Should -Be 502
            $result = $responses[0].Body | ConvertFrom-Json
            $result.rulesState | Should -Be 'applied'
            $result.managersState | Should -Be 'notStarted'
            $blobWrites.Count | Should -Be 1
            $writes.Count | Should -Be 0
        }
        It 'never reports full success when the <Kind> audit confirmation fails' -ForEach @(
            @{ Kind = 'policies'; ExpectedManagerState = 'notStarted' }
            @{ Kind = 'managers'; ExpectedManagerState = 'applied' }
        ) {
            $request.Method = 'PUT'
            $failedKind = $Kind
            Mock Write-ManagementAuditEvent { throw 'Audit confirmation failed' } -ParameterFilter {
                $Kind -eq $failedKind -and $Stage -eq 'applied'
            }
            & $handler -Request $request -TagPolicyBlob '[]'
            [int] $responses[0].StatusCode | Should -Be 502
            $result = $responses[0].Body | ConvertFrom-Json
            $result.rulesState | Should -Be 'applied'
            $result.managersState | Should -Be $ExpectedManagerState
            Should -Invoke Write-ManagementAuditEvent -Times 1 -ParameterFilter { $Stage -eq 'failed' }
        }
        It 'does not write managers when the conditional rule write fails' {
            $request.Method = 'PUT'
            Mock Set-ManagementPolicyBlob { throw 'Policy changed' }
            & $handler -Request $request -TagPolicyBlob '[]'
            [int] $responses[0].StatusCode | Should -Be 502
            $result = $responses[0].Body | ConvertFrom-Json
            $result.rulesState | Should -Be 'unconfirmed'
            $result.managersState | Should -Be 'notStarted'
            $writes.Count | Should -Be 0
        }
        It 'reports partial restore instead of success or rollback after an ARM write failure' {
            $request.Method = 'PUT'
            Mock Invoke-RestMethod { throw 'ARM write failed' } -ParameterFilter { $Method -eq 'PUT' }
            & $handler -Request $request -TagPolicyBlob '[]'
            [int] $responses[0].StatusCode | Should -Be 502
            $result = $responses[0].Body | ConvertFrom-Json
            $result.rulesState | Should -Be 'applied'
            $result.managersState | Should -Be 'unconfirmed'
            $blobWrites.Count | Should -Be 1
            Should -Invoke Write-ManagementAuditEvent -Times 1 -ParameterFilter { $Kind -eq 'managers' -and $Stage -eq 'failed' }
            Should -Invoke Write-ManagementAuditEvent -Times 0 -ParameterFilter { $Kind -eq 'policies' -and $Stage -eq 'failed' }
        }
    }
}
