# Project-Version: 1.4.20261020.8
# Author: andreas.lucas@outlook.com (aka Kili)

BeforeAll {
    $migrationScriptPath = Join-Path $PSScriptRoot `
        '..\Scripts\Migrate-AutopilotImportToPrivate.ps1'
    $migrationTokens = $null
    $migrationErrors = $null
    $migrationAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $migrationScriptPath,
        [ref] $migrationTokens,
        [ref] $migrationErrors
    )
    $migrationErrors | Should -BeNullOrEmpty
    foreach ($functionName in @(
            'Invoke-MigrationArmRequest'
            'Read-MigrationSettings'
        'Get-MigrationIPv4Range'
            'Get-MigrationSourceManagedIdentityId'
            'Remove-MigrationSourceStorageRoleAssignments'
            'Assert-MigrationNetworkPrefix'
    )) {
        $functionAst = $migrationAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
            }, $true) | Select-Object -First 1
        $functionAst | Should -Not -BeNullOrEmpty
        Invoke-Expression $functionAst.Extent.Text
    }
}

Describe 'Private endpoint migration safety' {
    It 'requires explicit acknowledgement for custom-domain certificate reissue' {
        $migrationAst.ParamBlock.Parameters.Name.VariablePath.UserPath |
            Should -Contain 'AcceptCustomDomainCertificateReissue'
        $migrationAst.Extent.Text |
            Should -Match 'Custom domains are not bound to the new Flex app'
        $migrationAst.Extent.Text |
            Should -Match 'no automatic certificate migration path'
    }

    It 'only deletes the source Function App and its hosting plan, never Storage' {
        $migrationAst.Extent.Text | Should -Match '\$\{resourceId\}\?api-version=2024-11-01'
        $migrationAst.Extent.Text | Should -Match '\$\{planResourceId\}\?api-version=2024-11-01'
        $migrationAst.Extent.Text | Should -Not -Match 'Remove-AzStorageAccount|Microsoft\.Storage/storageAccounts/.+DELETE'
        ([regex]::Matches($migrationAst.Extent.Text, '-Method DELETE')).Count |
            Should -Be 2
    }

    It 'places the ShouldProcess gate before any resource deletion' {
        $scriptText = Get-Content -LiteralPath $migrationScriptPath -Raw
        $gateIndex = $scriptText.IndexOf('$PSCmdlet.ShouldProcess')
        $deleteIndex = $scriptText.IndexOf('-Method DELETE')
        $gateIndex | Should -BeGreaterThan -1
        $deleteIndex | Should -BeGreaterThan $gateIndex
    }

    It 'preserves IDs, policy settings and Storage identity from the old app settings' {
        $settings = @{
            API_AUDIENCE = 'api://11111111-1111-1111-1111-111111111111'
            WEB_CLIENT_ID = '22222222-2222-2222-2222-222222222222'
            TENANT_ID = '33333333-3333-3333-3333-333333333333'
            TAG_AUTHORIZATION_POLICY = '[{"tags":["Default"]}]'
            MANAGER_AUTHORIZATION_POLICY = '{"installerPrincipalId":"44444444-4444-4444-4444-444444444444","additionalPrincipalIds":["55555555-5555-5555-5555-555555555555"],"allowIntuneRoleAdministrators":true}'
            AzureWebJobsStorage__accountName = 'autopilotstorage123'
            DEVICE_TAG_EXTENSION_ATTRIBUTE = 'extensionAttribute7'
        }
        Mock Invoke-MigrationArmRequest {
            @{
                StatusCode = 200
                Content = ConvertTo-Json -InputObject @{ properties = $settings } -Depth 8
            }
        }

        $result = Read-MigrationSettings `
            -SubscriptionId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' `
            -ResourceGroupName 'rg-test' `
            -FunctionAppName 'func-test' `
            -TenantId '33333333-3333-3333-3333-333333333333'

        $result.apiAudience | Should -BeExactly $settings.API_AUDIENCE
        $result.webClientId | Should -BeExactly $settings.WEB_CLIENT_ID
        $result.tagAuthorizationPolicy | Should -BeExactly $settings.TAG_AUTHORIZATION_POLICY
        $result.managerPolicy | Should -BeExactly $settings.MANAGER_AUTHORIZATION_POLICY
        $result.managerPrincipalIds | Should -Contain '55555555-5555-5555-5555-555555555555'
        $result.storageAccountName | Should -BeExactly $settings.AzureWebJobsStorage__accountName
        $result.deviceTagExtensionAttribute | Should -BeExactly 'extensionAttribute7'
    }

    It 'refuses a tenant mismatch or invalid manager policy before migration' {
        $settings = @{
            API_AUDIENCE = 'api://11111111-1111-1111-1111-111111111111'
            WEB_CLIENT_ID = '22222222-2222-2222-2222-222222222222'
            TENANT_ID = '33333333-3333-3333-3333-333333333333'
            TAG_AUTHORIZATION_POLICY = '[]'
            MANAGER_AUTHORIZATION_POLICY = '{"installerPrincipalId":"invalid","additionalPrincipalIds":[],"allowIntuneRoleAdministrators":true}'
            AzureWebJobsStorage__accountName = 'autopilotstorage123'
        }
        Mock Invoke-MigrationArmRequest {
            @{
                StatusCode = 200
                Content = ConvertTo-Json -InputObject @{ properties = $settings } -Depth 8
            }
        }

        {
            Read-MigrationSettings `
                -SubscriptionId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' `
                -ResourceGroupName 'rg-test' `
                -FunctionAppName 'func-test' `
                -TenantId '99999999-9999-9999-9999-999999999999'
        } | Should -Throw '*TENANT_ID*'

        $settings.TENANT_ID = '33333333-3333-3333-3333-333333333333'
        {
            Read-MigrationSettings `
                -SubscriptionId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' `
                -ResourceGroupName 'rg-test' `
                -FunctionAppName 'func-test' `
                -TenantId '33333333-3333-3333-3333-333333333333'
        } | Should -Throw '*MANAGER_AUTHORIZATION_POLICY*'
    }

    It 'allows the selected non-overlapping private range and rejects overlapping VNets' {
        Mock Get-AzVirtualNetwork {
            @(
                [pscustomobject]@{
                    Name = 'existing-172'
                    ResourceGroupName = 'rg-network'
                    AddressSpace = [pscustomobject]@{ AddressPrefixes = @('172.16.0.0/16') }
                }
                [pscustomobject]@{
                    Name = 'existing-10'
                    ResourceGroupName = 'rg-onprem'
                    AddressSpace = [pscustomobject]@{ AddressPrefixes = @('10.0.0.0/16') }
                }
            )
        }

        { Assert-MigrationNetworkPrefix -Cidr '192.168.0.0/24' } |
            Should -Not -Throw
        { Assert-MigrationNetworkPrefix -Cidr '172.16.0.0/24' } |
            Should -Throw '*overlaps existing VNet*'
        Should -Invoke Get-AzVirtualNetwork -Times 2
    }

    It 'allows its existing target VNet during a partial Flex migration resume' {
        Mock Get-AzVirtualNetwork {
            @(
                [pscustomobject]@{
                    Name = 'vnet-func-test'
                    ResourceGroupName = 'rg-test'
                    AddressSpace = [pscustomobject]@{ AddressPrefixes = @('192.168.0.0/24') }
                }
            )
        }

        {
            Assert-MigrationNetworkPrefix `
                -Cidr '192.168.0.0/24' `
                -ExistingTargetVNetName 'vnet-func-test' `
                -ExistingTargetVNetResourceGroup 'rg-test'
        } | Should -Not -Throw
    }

    It 'identifies the old Function identity only from its complete Storage role set' {
        $principalId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $scope = '/subscriptions/test/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/autopilot'
        Mock Get-AzRoleAssignment {
            @(
                'Storage Blob Data Owner'
                'Storage Queue Data Contributor'
                'Storage Table Data Contributor'
            ) | ForEach-Object {
                [pscustomobject]@{
                    ObjectId = $principalId
                    ObjectType = 'ServicePrincipal'
                    RoleDefinitionName = $_
                    Scope = $scope
                }
            }
        }

        Get-MigrationSourceManagedIdentityId -StorageResourceId $scope |
            Should -BeExactly $principalId

        Mock Get-AzRoleAssignment {
            @(
                [pscustomobject]@{
                    ObjectId = $principalId
                    ObjectType = 'ServicePrincipal'
                    RoleDefinitionName = 'Storage Blob Data Owner'
                    Scope = $scope
                }
            )
        }
        {
            Get-MigrationSourceManagedIdentityId -StorageResourceId $scope
        } | Should -Throw '*complete set of Storage roles*'
    }

    It 'removes only the old identity roles at the retained Storage account scope' {
        $principalId = [guid] 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $scope = '/subscriptions/test/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/autopilot'
        $roleNames = @(
            'Storage Blob Data Owner'
            'Storage Queue Data Contributor'
            'Storage Table Data Contributor'
        )
        $script:roleQueryCount = 0
        Mock Get-AzRoleAssignment {
            $script:roleQueryCount++
            if ($script:roleQueryCount -eq 1) {
                @(
                    $roleNames | ForEach-Object {
                        [pscustomobject]@{
                            ObjectId = $principalId.ToString()
                            RoleDefinitionName = $_
                            Scope = $scope
                        }
                    }
                    [pscustomobject]@{
                        ObjectId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
                        RoleDefinitionName = 'Storage Blob Data Owner'
                        Scope = $scope
                    }
                    [pscustomobject]@{
                        ObjectId = $principalId.ToString()
                        RoleDefinitionName = 'Storage Blob Data Owner'
                        Scope = "$scope/blobServices/default/containers/policy"
                    }
                )
            }
            else {
                @(
                    [pscustomobject]@{
                        ObjectId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
                        RoleDefinitionName = 'Storage Blob Data Owner'
                        Scope = $scope
                    }
                )
            }
        }
        Mock Remove-AzRoleAssignment {}

        Remove-MigrationSourceStorageRoleAssignments `
            -StorageResourceId $scope `
            -PrincipalId $principalId

        Should -Invoke Remove-AzRoleAssignment -Times 3 -Exactly
        Should -Invoke Remove-AzRoleAssignment -ParameterFilter {
            $ObjectId -eq $principalId.ToString() -and
            $RoleDefinitionName -in $roleNames -and
            $Scope -eq $scope
        } -Times 3 -Exactly
    }

    It 'preserves the existing Flex plan when resuming after a partial deployment' {
        $migrationAst.Extent.Text |
            Should -Match 'if \(-not \$resumeExistingFlex\)'
        $migrationAst.Extent.Text |
            Should -Match 'Remove obsolete Storage roles for the old identity and resume deployment without deleting the existing Flex app or plan'
    }
}
