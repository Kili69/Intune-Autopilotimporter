# Project-Version: 1.0.20260828.1
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
.SYNOPSIS
Runs unit tests for Autopilot import validation and authorization.

.DESCRIPTION
Pester tests covering Microsoft Graph payload construction, malformed hardware
hash rejection, Easy Auth role enforcement, Entra group-to-tag authorization,
tag casing, installer authorization-rule parsing, and project metadata markers.

.EXAMPLE
Invoke-Pester -Script .\tests\AutopilotImport.Tests.ps1

Runs the test suite with Pester 5 syntax.

.INPUTS
None.

.OUTPUTS
Pester test results when invoked through Invoke-Pester.
#>

$modulePath = Join-Path $PSScriptRoot '..\src\AutopilotImport\AutopilotImport.psm1'
Import-Module $modulePath -Force

Describe 'Client API error messages' {
    BeforeAll {
        $clientModulePath = Join-Path $PSScriptRoot `
            '..\src\AutopilotImport.Client\AutopilotImport.Client.psd1'
        Import-Module $clientModulePath -Force
        $clientModule = Get-Module AutopilotImport.Client |
            Where-Object ModuleBase -eq (Split-Path (Resolve-Path $clientModulePath).Path)
    }

    It 'explains a disallowed Group Tag and includes the correlation ID' {
        $exception = [InvalidOperationException]::new('HTTP 403 Forbidden')
        $errorRecord = [Management.Automation.ErrorRecord]::new(
            $exception,
            'HttpResponseException',
            [Management.Automation.ErrorCategory]::PermissionDenied,
            $null
        )
        $errorRecord.ErrorDetails = [Management.Automation.ErrorDetails]::new(
            '{"error":"groupTagNotAllowed","correlationId":"109ff31c-4392-415a-b39f-56d3d7776110"}'
        )

        $message = & $clientModule {
            param($ApiError)
            Get-ClientApiErrorMessage `
                -ErrorRecord $ApiError `
                -SerialNumber 'TEST-001' `
                -GroupTag 'BG-PAW1'
        } $errorRecord

        $message | Should -Match "Group Tag 'BG-PAW1' is not allowed"
        $message | Should -Match "serial 'TEST-001'"
        $message | Should -Match 'Correlation ID: 109ff31c-4392-415a-b39f-56d3d7776110'
    }

    It 'preserves the original message for an unknown API error' {
        $errorRecord = [Management.Automation.ErrorRecord]::new(
            [InvalidOperationException]::new('Connection was closed'),
            'UnknownApiError',
            [Management.Automation.ErrorCategory]::ConnectionError,
            $null
        )

        $message = & $clientModule {
            param($ApiError)
            Get-ClientApiErrorMessage `
                -ErrorRecord $ApiError `
                -SerialNumber 'TEST-002' `
                -GroupTag 'BG-PAW'
        } $errorRecord

        $message | Should -Match 'Connection was closed'
    }
}

Describe 'Client import result metadata' {
    BeforeAll {
        $clientModulePath = Join-Path $PSScriptRoot `
            '..\src\AutopilotImport.Client\AutopilotImport.Client.psd1'
        Import-Module $clientModulePath -Force
        $clientModule = Get-Module AutopilotImport.Client |
            Where-Object ModuleBase -eq (Split-Path (Resolve-Path $clientModulePath).Path)
    }

    It 'adds the local import time and Intune availability notice' {
        $response = [pscustomobject]@{
            importId     = '82d7266e-4213-4fa1-a5d5-b0ee10d009de'
            serialNumber = 'TEST-001'
        }
        $importedAt = [datetimeoffset]::Parse('2026-08-12T14:35:42+02:00')

        $result = & $clientModule {
            param($ImportResponse, $Timestamp)
            Add-ClientImportMetadata `
                -ImportResponse $ImportResponse `
                -ImportedAt $Timestamp
        } $response $importedAt

        $result.importedAt | Should -Be '2026-08-12 14:35:42 +02:00'
        $result.intuneAvailabilityNote | Should -Match `
            'several minutes before the device appears'
    }
}

Describe 'Client configuration creation' {
    BeforeAll {
        $clientModulePath = Join-Path $PSScriptRoot `
            '..\src\AutopilotImport.Client\AutopilotImport.Client.psd1'
        Import-Module $clientModulePath -Force
    }

    BeforeEach {
        Mock Get-AzContext -ModuleName AutopilotImport.Client {
            [pscustomobject]@{
                Subscription = [pscustomobject]@{
                    Id = '11111111-1111-1111-1111-111111111111'
                }
                Tenant = [pscustomobject]@{
                    Id = '22222222-2222-2222-2222-222222222222'
                }
            }
        }
        Mock Connect-AzAccount -ModuleName AutopilotImport.Client
        Mock Set-AzContext -ModuleName AutopilotImport.Client
        Mock Invoke-AzRestMethod -ModuleName AutopilotImport.Client {
            [pscustomobject]@{
                StatusCode = 200
                Content = @{
                    properties = @{
                        identityProviders = @{
                            azureActiveDirectory = @{
                                registration = @{
                                    clientId = '33333333-3333-3333-3333-333333333333'
                                }
                                validation = @{
                                    allowedAudiences = @(
                                        'api://33333333-3333-3333-3333-333333333333'
                                        '33333333-3333-3333-3333-333333333333'
                                    )
                                }
                            }
                        }
                    }
                } | ConvertTo-Json -Depth 8
            }
        }
    }

    It 'creates client.settings.json in an optional directory' {
        $outputPath = Join-Path $TestDrive 'configuration'
        $warnings = @()
        $settingsFile = New-AutopilotClientConfiguration `
            -SubscriptionId '11111111-1111-1111-1111-111111111111' `
            -ResourceGroupName 'rg-autopilot-import' `
            -TenantId '22222222-2222-2222-2222-222222222222' `
            -FunctionAppName 'func-autopilot-import' `
            -OutputPath $outputPath `
            -WarningVariable warnings

        $settingsFile.FullName | Should -Be `
            (Join-Path $outputPath 'client.settings.json')
        $settings = Get-Content -LiteralPath $settingsFile.FullName -Raw |
            ConvertFrom-Json
        $settings.functionUrl | Should -Be `
            'https://func-autopilot-import.azurewebsites.net/api/devices/import'
        $settings.managementUrl | Should -Be `
            'https://func-autopilot-import.azurewebsites.net/api/management/tag-policy'
        $settings.apiApplicationIdUri | Should -Be `
            'api://33333333-3333-3333-3333-333333333333'
        $settings.tenantId | Should -Be `
            '22222222-2222-2222-2222-222222222222'
        $settings.subscriptionId | Should -Be `
            '11111111-1111-1111-1111-111111111111'
        $settings.resourceGroupName | Should -Be 'rg-autopilot-import'
        $settings.functionAppName | Should -Be 'func-autopilot-import'
        $warnings | Out-String | Should -Match `
            'AutopilotImport.Client.*client.settings.json'
    }

    It 'creates client.settings.json in the current directory by default' {
        $currentDirectory = Join-Path $TestDrive 'current'
        New-Item -Path $currentDirectory -ItemType Directory | Out-Null
        Push-Location $currentDirectory
        try {
            $settingsFile = New-AutopilotClientConfiguration `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -ResourceGroupName 'rg-autopilot-import' `
                -TenantId '22222222-2222-2222-2222-222222222222' `
                -FunctionAppName 'func-autopilot-import' `
                -WarningAction SilentlyContinue

            $settingsFile.FullName | Should -Be `
                (Join-Path $currentDirectory 'client.settings.json')
        }
        finally {
            Pop-Location
        }

        Should -Invoke Invoke-AzRestMethod `
            -ModuleName AutopilotImport.Client `
            -ParameterFilter {
                $Method -eq 'GET' -and
                $Path -match '/resourceGroups/rg-autopilot-import/' -and
                $Path -match '/sites/func-autopilot-import/config/authsettingsV2'
            } `
            -Times 1
    }

    It 'does not replace an existing client configuration without Force' {
        $settingsPath = Join-Path $TestDrive 'client.settings.json'
        'existing' | Set-Content -LiteralPath $settingsPath

        {
            New-AutopilotClientConfiguration `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -ResourceGroupName 'rg-autopilot-import' `
                -TenantId '22222222-2222-2222-2222-222222222222' `
                -FunctionAppName 'func-autopilot-import' `
                -OutputPath $TestDrive
        } | Should -Throw '*already exists*Use -Force*'

        Get-Content -LiteralPath $settingsPath -Raw | Should -BeLike 'existing*'
    }
}

Describe 'Client import status metadata' {
    BeforeAll {
        $clientModulePath = Join-Path $PSScriptRoot `
            '..\src\AutopilotImport.Client\AutopilotImport.Client.psd1'
        Import-Module $clientModulePath -Force
        $clientModule = Get-Module AutopilotImport.Client |
            Where-Object ModuleBase -eq (Split-Path (Resolve-Path $clientModulePath).Path)
    }

    It 'explains that unknown is a non-final asynchronous state' {
        $result = & $clientModule {
            Add-ClientImportStatusMetadata -ImportStatus ([pscustomobject]@{
                status = 'unknown'
            })
        }

        $result.isFinal | Should -BeFalse
        $result.statusDescription | Should -Match 'not reported a definitive state'
    }

    It 'does not mark a completed Intune import final while the attribute is pending' {
        $result = & $clientModule {
            Add-ClientImportStatusMetadata -ImportStatus ([pscustomobject]@{
                status                   = 'complete'
                extensionAttributeStatus = 'pending'
            })
        }

        $result.isFinal | Should -BeFalse
        $result.statusDescription | Should -Match 'still pending'
    }

    It 'marks the completed end-to-end workflow as final' {
        $result = & $clientModule {
            Add-ClientImportStatusMetadata -ImportStatus ([pscustomobject]@{
                status                   = 'complete'
                extensionAttributeStatus = 'complete'
            })
        }

        $result.isFinal | Should -BeTrue
    }

    It 'marks an Intune import error as final' {
        $result = & $clientModule {
            Add-ClientImportStatusMetadata -ImportStatus ([pscustomobject]@{
                status                   = 'error'
                extensionAttributeStatus = 'notApplicable'
            })
        }

        $result.isFinal | Should -BeTrue
    }
}

Describe 'Blob binding content conversion' {
    It 'decodes text and byte content' {
        $json = '{"groupId":"11111111-1111-1111-1111-111111111111"}'

        ConvertFrom-BlobBindingContent -Value $json | Should -Be $json
        ConvertFrom-BlobBindingContent `
            -Value ([Text.Encoding]::UTF8.GetBytes($json)) |
            Should -Be $json
    }

    It 'decodes streams and content wrappers' {
        $json = '{"groupId":"11111111-1111-1111-1111-111111111111"}'
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $stream = [IO.MemoryStream]::new($bytes)
        $wrapper = [pscustomobject]@{ Content = [IO.MemoryStream]::new($bytes) }
        try {
            ConvertFrom-BlobBindingContent -Value $stream | Should -Be $json
            ConvertFrom-BlobBindingContent -Value $wrapper | Should -Be $json
        }
        finally {
            $stream.Dispose()
            $wrapper.Content.Dispose()
        }
    }

    It 'serializes policy objects supplied by the Functions worker' {
        $policy = @(
            [pscustomobject]@{
                groupId = '11111111-1111-1111-1111-111111111111'
                tags    = @('BG-Client')
            }
            [pscustomobject]@{
                groupId = '22222222-2222-2222-2222-222222222222'
                tags    = @('BG-PAW')
            }
        )

        $decodedPolicy = @(ConvertFrom-BlobBindingContent -Value $policy |
            ConvertFrom-Json)

        $decodedPolicy.Count | Should -Be 2
        $decodedPolicy[0].tags | Should -Be 'BG-Client'
    }
}

Describe 'Autopilot import request validation' {
    It 'builds a Graph payload with the server-side group tag' {
        $requestBody = [pscustomobject]@{
            serialNumber       = '  PC-001  '
            hardwareIdentifier = [Convert]::ToBase64String([byte[]](1, 2, 3, 4))
            groupTag           = 'Untrusted-Client-Tag'
        }

        $payload = ConvertTo-AutopilotImportPayload -RequestBody $requestBody -GroupTag 'Corporate'

        $payload.serialNumber | Should -Be 'PC-001'
        $payload.groupTag | Should -Be 'Corporate'
    }

    It 'rejects a malformed hardware hash' {
        $requestBody = [pscustomobject]@{
            serialNumber       = 'PC-001'
            hardwareIdentifier = 'not-base64'
        }

        { ConvertTo-AutopilotImportPayload -RequestBody $requestBody -GroupTag 'Corporate' } |
            Should -Throw
    }
}

Describe 'Entra device extension attribute updates' {
    It 'maps the Group Tag to the configured extension attribute' {
        $payload = ConvertTo-EntraDeviceExtensionAttributes `
            -ExtensionAttribute 'extensionAttribute7' `
            -GroupTag 'PAW-CSM'

        $payload.extensionAttributes.extensionAttribute7 | Should -Be 'PAW-CSM'
        $payload.extensionAttributes.Keys.Count | Should -Be 1
    }

    It 'rejects an unsupported extension attribute name' {
        {
            ConvertTo-EntraDeviceExtensionAttributes `
                -ExtensionAttribute 'extensionAttribute16' `
                -GroupTag 'PAW-CSM'
        } | Should -Throw
    }

    It 'resolves the registered Autopilot identity from a completed import' {
        $registrationId = Get-AutopilotDeviceRegistrationId -ImportedDevice `
            ([pscustomobject]@{
                state = [pscustomobject]@{
                    deviceRegistrationId = '11111111-1111-1111-1111-111111111111'
                }
            })

        $registrationId | Should -Be '11111111-1111-1111-1111-111111111111'
    }

    It 'rejects an import without a device registration ID' {
        {
            Get-AutopilotDeviceRegistrationId -ImportedDevice `
                ([pscustomobject]@{ state = [pscustomobject]@{} })
        } | Should -Throw '*registration is not available yet*'
    }
}

Describe 'Easy Auth authorization' {
    It 'accepts the configured importer role' {
        $principalJson = @{
            auth_typ = 'aad'
            role_typ = 'roles'
            claims   = @(
                @{ typ = 'roles'; val = 'DeviceHash.Importer' }
                @{ typ = 'oid'; val = '00000000-0000-0000-0000-000000000001' }
            )
        } | ConvertTo-Json -Depth 4 -Compress
        $header = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($principalJson))

        $principal = ConvertFrom-ClientPrincipalHeader -HeaderValue $header

        (Test-ClientPrincipalRole -Principal $principal -RequiredRole 'DeviceHash.Importer') |
            Should -Be $true
    }

    It 'rejects a principal without the importer role' {
        $principal = [pscustomobject]@{
            role_typ = 'roles'
            claims   = @(@{ typ = 'roles'; val = 'Reader' })
        }

        (Test-ClientPrincipalRole -Principal $principal -RequiredRole 'DeviceHash.Importer') |
            Should -Be $false
    }
}

Describe 'Group-based tag authorization' {
    BeforeEach {
        $principal = [pscustomobject]@{
            claims = @(
                @{ typ = 'groups'; val = '11111111-1111-1111-1111-111111111111' }
            )
        }
        $policy = @(
            [pscustomobject]@{
                groupId = '11111111-1111-1111-1111-111111111111'
                tags    = @('Autopilot-Standard', 'Autopilot-Kiosk')
            }
            [pscustomobject]@{
                groupId = '22222222-2222-2222-2222-222222222222'
                tags    = @('Autopilot-Privileged')
            }
        )
    }

    It 'allows a tag assigned to a caller group' {
        Resolve-AuthorizedGroupTag `
            -Principal $principal `
            -Policy $policy `
            -RequestedGroupTag 'Autopilot-Kiosk' |
            Should -Be 'Autopilot-Kiosk'
    }

    It 'returns the configured tag casing' {
        Resolve-AuthorizedGroupTag `
            -Principal $principal `
            -Policy $policy `
            -RequestedGroupTag 'autopilot-kiosk' |
            Should -Be 'Autopilot-Kiosk'
    }

    It 'rejects a tag assigned only to another group' {
        { Resolve-AuthorizedGroupTag `
                -Principal $principal `
                -Policy $policy `
                -RequestedGroupTag 'Autopilot-Privileged' } |
            Should -Throw
    }

    It 'rejects a tag that is not configured' {
        { Resolve-AuthorizedGroupTag `
                -Principal $principal `
                -Policy $policy `
                -RequestedGroupTag 'Untrusted-Tag' } |
            Should -Throw
    }
}

Describe 'Installer tag authorization rules' {
    BeforeAll {
        $installerPath = Join-Path $PSScriptRoot '..\Install-AutopilotImport.ps1'
        $tokens = $null
        $parseErrors = $null
        $installerAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $installerPath,
            [ref] $tokens,
            [ref] $parseErrors
        )
        $functionAst = $installerAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'ConvertTo-TagAuthorizationPolicy'
        }, $true) | Select-Object -First 1
        Invoke-Expression $functionAst.Extent.Text
    }

    It 'consolidates tags for the same group' {
        $policy = ConvertTo-TagAuthorizationPolicy -Rules @(
            '11111111-1111-1111-1111-111111111111=Standard,Kiosk'
            '11111111-1111-1111-1111-111111111111=Kiosk,Privileged'
        )

        $policy.Count | Should -Be 1
        $policy[0].tags.Count | Should -Be 3
    }

    It 'rejects a non-GUID group identifier' {
        { ConvertTo-TagAuthorizationPolicy -Rules @('Not-A-Group=Standard') } |
            Should -Throw
    }

    It 'preserves an optional restricted management administrative unit name' {
        $policy = ConvertTo-TagAuthorizationPolicy `
            -Rules @('11111111-1111-1111-1111-111111111111=Standard') `
            -RestrictedManagementAdministrativeUnitName ' RMAU-Autopilot '

        $policy.restrictedManagementAdministrativeUnitName |
            Should -Be 'RMAU-Autopilot'
        AutopilotImport\Resolve-RestrictedManagementAdministrativeUnitName `
            -Policy $policy `
            -GroupTag 'Standard' | Should -Be 'RMAU-Autopilot'
    }

    It 'keeps the current policy shape when no administrative unit is configured' {
        $policy = ConvertTo-TagAuthorizationPolicy `
            -Rules @('11111111-1111-1111-1111-111111111111=Standard')

        $policy.PSObject.Properties.Name |
            Should -Not -Contain 'restrictedManagementAdministrativeUnitName'
        AutopilotImport\Resolve-RestrictedManagementAdministrativeUnitName `
            -Policy $policy `
            -GroupTag 'Standard' | Should -BeNullOrEmpty
    }
}

Describe 'Restricted management administrative unit membership' {
    InModuleScope AutopilotImport {
        BeforeEach {
            $script:administrativeUnit = [pscustomobject]@{
                id                           = '22222222-2222-2222-2222-222222222222'
                displayName                  = 'RMAU-Autopilot'
                isMemberManagementRestricted = $true
            }
            $script:existingMembers = @()
            Mock Invoke-RestMethod {
                if ($Uri -match '/members\?') {
                    return @{ value = @($script:existingMembers) }
                }
                if ($Method -eq 'Get') {
                    return @{ value = @($script:administrativeUnit) }
                }
                return $null
            }
        }

        It 'adds a new Entra device member to the named RMAU' {
            $deviceObjectId = [guid] `
                '11111111-1111-1111-1111-111111111111'
            $result = `
                Add-EntraDeviceToRestrictedManagementAdministrativeUnit `
                    -AdministrativeUnitName 'RMAU-Autopilot' `
                    -DeviceObjectId $deviceObjectId `
                    -AccessToken (ConvertTo-SecureString 'token' `
                        -AsPlainText -Force)

            $result.MembershipAdded | Should -BeTrue
            Assert-MockCalled Invoke-RestMethod -Times 1 `
                -ParameterFilter {
                    $Method -eq 'Post' -and
                    $Uri -match '/administrativeUnits/.+/members/\$ref$' -and
                    $Body -match [regex]::Escape($deviceObjectId.ToString())
                }
        }

        It 'does not add an Entra device that is already a member' {
            $deviceObjectId = [guid] `
                '11111111-1111-1111-1111-111111111111'
            $script:existingMembers = @(
                [pscustomobject]@{ id = $deviceObjectId.ToString() }
            )

            $result = `
                Add-EntraDeviceToRestrictedManagementAdministrativeUnit `
                    -AdministrativeUnitName 'RMAU-Autopilot' `
                    -DeviceObjectId $deviceObjectId `
                    -AccessToken (ConvertTo-SecureString 'token' `
                        -AsPlainText -Force)

            $result.MembershipAdded | Should -BeFalse
            Assert-MockCalled Invoke-RestMethod -Times 0 `
                -ParameterFilter { $Method -eq 'Post' }
        }

        It 'checks membership without adding a missing device' {
            $result = `
                Add-EntraDeviceToRestrictedManagementAdministrativeUnit `
                    -AdministrativeUnitName 'RMAU-Autopilot' `
                    -DeviceObjectId `
                        '11111111-1111-1111-1111-111111111111' `
                    -AccessToken (ConvertTo-SecureString 'token' `
                        -AsPlainText -Force) `
                    -TestOnly

            $result.IsMember | Should -BeFalse
            $result.MembershipAdded | Should -BeFalse
            Assert-MockCalled Invoke-RestMethod -Times 0 `
                -ParameterFilter { $Method -eq 'Post' }
        }

        It 'rejects an administrative unit that is not restricted' {
            $script:administrativeUnit.isMemberManagementRestricted = $false

            {
                Add-EntraDeviceToRestrictedManagementAdministrativeUnit `
                    -AdministrativeUnitName 'RMAU-Autopilot' `
                    -DeviceObjectId '11111111-1111-1111-1111-111111111111' `
                    -AccessToken (ConvertTo-SecureString 'token' `
                        -AsPlainText -Force)
            } | Should -Throw '*is not a restricted management administrative unit*'
        }
    }
}

Describe 'Installer Function App naming' {
    BeforeAll {
        $installerPath = Join-Path $PSScriptRoot '..\Install-AutopilotImport.ps1'
        $tokens = $null
        $parseErrors = $null
        $installerAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $installerPath,
            [ref] $tokens,
            [ref] $parseErrors
        )
        $functionAst = $installerAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Test-FunctionAppName'
        }, $true) | Select-Object -First 1
        Invoke-Expression $functionAst.Extent.Text
    }

    It 'accepts Azure Function App names at the supported boundaries' {
        Test-FunctionAppName -Name 'a1' | Should -Be $true
        Test-FunctionAppName -Name ('a' * 60) | Should -Be $true
        Test-FunctionAppName -Name 'func-autopilot-contoso' | Should -Be $true
    }

    It 'rejects invalid Azure Function App names' -ForEach @(
        @{ Name = 'a' }
        @{ Name = 'a' * 61 }
        @{ Name = '-func-autopilot' }
        @{ Name = 'func-autopilot-' }
        @{ Name = 'func_autopilot' }
        @{ Name = 'func autopilot' }
    ) {
        Test-FunctionAppName -Name $Name | Should -Be $false
    }
}

Describe 'Installer additional manager principal IDs' {
    BeforeAll {
        $installerPath = Join-Path $PSScriptRoot '..\Install-AutopilotImport.ps1'
        $tokens = $null
        $parseErrors = $null
        $installerAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $installerPath,
            [ref] $tokens,
            [ref] $parseErrors
        )
        $functionAst = $installerAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'ConvertTo-AdditionalManagerPrincipalIds'
        }, $true) | Select-Object -First 1
        Invoke-Expression $functionAst.Extent.Text
    }

    It 'returns an empty collection when no additional manager is supplied' {
        $managerIds = @(ConvertTo-AdditionalManagerPrincipalIds `
            -PrincipalIds $null `
            -InstallingUserObjectId '11111111-1111-1111-1111-111111111111')

        $managerIds.Count | Should -Be 0
    }

    It 'removes the installing user and duplicate additional managers' {
        $managerIds = @(ConvertTo-AdditionalManagerPrincipalIds `
            -PrincipalIds @(
                '11111111-1111-1111-1111-111111111111'
                '22222222-2222-2222-2222-222222222222'
                '22222222-2222-2222-2222-222222222222'
            ) `
            -InstallingUserObjectId '11111111-1111-1111-1111-111111111111')

        $managerIds | Should -Be '22222222-2222-2222-2222-222222222222'
    }
}

Describe 'Installer client tools package' {
    BeforeAll {
        $projectRoot = Join-Path $PSScriptRoot '..'
        $installerPath = Join-Path $projectRoot 'Install-AutopilotImport.ps1'
        $tokens = $null
        $parseErrors = $null
        $installerAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $installerPath,
            [ref] $tokens,
            [ref] $parseErrors
        )
        $functionAst = $installerAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Install-AutopilotClientTools'
        }, $true) | Select-Object -First 1
        Invoke-Expression $functionAst.Extent.Text
    }

    It 'installs compatibility scripts and a versioned client module with defaults' {
        $destinationPath = Join-Path $TestDrive 'AutopilotImport'
        $documentsPath = Join-Path $TestDrive 'Documents'
        $moduleVersion = [string] (Import-PowerShellDataFile `
            (Join-Path $projectRoot `
                'src\AutopilotImport.Client\AutopilotImport.Client.psd1')).ModuleVersion
        [void] (New-Item -Path $documentsPath -ItemType Directory -Force)
        $modulePackagePath = Join-Path $documentsPath `
            "Intune-Autopilotimport-psmodule-$moduleVersion.zip"
        'outdated package' | Set-Content -LiteralPath $modulePackagePath
        $previousModulePath = Join-Path $destinationPath `
            'Modules\AutopilotImport.Client\1.0.20260812.1'
        [void] (New-Item -Path $previousModulePath -ItemType Directory -Force)
        '{"functionAppName":"func-previous"}' | Set-Content `
            -LiteralPath (Join-Path $previousModulePath 'client.settings.json')
        $settings = [ordered]@{
            functionUrl         = 'https://func-test.azurewebsites.net/api/devices/import'
            managementUrl       = 'https://func-test.azurewebsites.net/api/management/tag-policy'
            apiApplicationIdUri = 'api://11111111-1111-1111-1111-111111111111'
            tenantId            = '22222222-2222-2222-2222-222222222222'
            subscriptionId      = '33333333-3333-3333-3333-333333333333'
            resourceGroupName   = 'rg-test'
            functionAppName     = 'func-test'
        } | ConvertTo-Json

        $settingsPath = Install-AutopilotClientTools `
            -DestinationPath $destinationPath `
            -ProjectRoot $projectRoot `
            -ClientSettingsJson $settings `
            -PackageDestinationPath $documentsPath

        $modulePath = Join-Path $destinationPath `
            "Modules\AutopilotImport.Client\$moduleVersion"
        $settingsPath | Should -Be (Join-Path $modulePath 'client.settings.json')
        @(
            'scripts\Import-AutopilotDevice.ps1'
            'scripts\Set-TagAuthorizationPolicy.ps1'
            'scripts\Set-TagPolicyManagers.ps1'
            "Modules\AutopilotImport.Client\$moduleVersion\AutopilotImport.Client.psm1"
            "Modules\AutopilotImport.Client\$moduleVersion\AutopilotImport.Client.psd1"
            "Modules\AutopilotImport.Client\$moduleVersion\AutopilotImport.psm1"
            "Modules\AutopilotImport.Client\$moduleVersion\client.settings.json"
        ) | ForEach-Object {
            Join-Path $destinationPath $_ | Should -Exist
        }
        $installedSettings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        $installedSettings.functionAppName | Should -Be 'func-test'
        $installedSettings.subscriptionId | Should -Be `
            '33333333-3333-3333-3333-333333333333'
        $previousModulePath | Should -Not -Exist

        $modulePackagePath | Should -Exist
        $archive = [IO.Compression.ZipFile]::OpenRead($modulePackagePath)
        try {
            @($archive.Entries.FullName) | Should -Contain `
                "AutopilotImport.Client/$moduleVersion/AutopilotImport.Client.psd1"
            @($archive.Entries.FullName) | Should -Contain `
                "AutopilotImport.Client/$moduleVersion/AutopilotImport.Client.psm1"
            @($archive.Entries.FullName) | Should -Contain `
                "AutopilotImport.Client/$moduleVersion/AutopilotImport.psm1"
            @($archive.Entries.FullName) | Should -Contain `
                "AutopilotImport.Client/$moduleVersion/client.settings.json"
            $settingsEntry = $archive.GetEntry(
                "AutopilotImport.Client/$moduleVersion/client.settings.json")
            $reader = [IO.StreamReader]::new($settingsEntry.Open())
            try {
                $archivedSettings = $reader.ReadToEnd() | ConvertFrom-Json
                $archivedSettings.functionAppName | Should -Be 'func-test'
                $archivedSettings.subscriptionId | Should -Be `
                    '33333333-3333-3333-3333-333333333333'
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $archive.Dispose()
        }

        $autoloadModuleRoot = Join-Path $TestDrive 'PowerShell\Modules'
        Expand-Archive `
            -LiteralPath $modulePackagePath `
            -DestinationPath $autoloadModuleRoot
        $originalModulePath = $env:PSModulePath
        try {
            $env:PSModulePath = $autoloadModuleRoot + `
                [IO.Path]::PathSeparator + $originalModulePath
            Remove-Module AutopilotImport.Client -ErrorAction SilentlyContinue
            $autoloadedCommand = Get-Command Import-AutopilotDevice `
                -ErrorAction Stop
            $autoloadedCommand.Module.Path | Should -Be `
                (Join-Path $autoloadModuleRoot `
                    "AutopilotImport.Client\$moduleVersion\AutopilotImport.Client.psm1")
        }
        finally {
            Remove-Module AutopilotImport.Client -ErrorAction SilentlyContinue
            $env:PSModulePath = $originalModulePath
        }

        Import-Module `
            (Join-Path $modulePath 'AutopilotImport.Client.psd1') `
            -Force
        (Get-Command -Module AutopilotImport.Client).Count | Should -Be 8
        Remove-Module AutopilotImport.Client
    }
}

Describe 'Update script deployment discovery' {
    BeforeAll {
        $projectRoot = Join-Path $PSScriptRoot '..'
        $updateScriptPath = Join-Path $projectRoot 'Update-AutopilotImport.ps1'
        $tokens = $null
        $parseErrors = $null
        $updateAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $updateScriptPath,
            [ref] $tokens,
            [ref] $parseErrors
        )
        foreach ($functionName in @(
                'Resolve-AutopilotUpdateConfigPath',
                'Get-AutopilotClientToolsPath',
                'ConvertTo-UpdateTagAuthorizationRules',
                'Get-UpdateRestrictedManagementAdministrativeUnitName',
                'Assert-AutopilotAppSettingsResponse',
                'Test-AzurePermissionPattern',
                'Assert-AzureUpdatePermissions'
            )) {
            $functionAst = $updateAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
            }, $true) | Select-Object -First 1
            Invoke-Expression $functionAst.Extent.Text
        }
    }

    It 'uses an explicitly supplied client configuration' {
        $configPath = Join-Path $TestDrive 'client.settings.json'
        '{}' | Set-Content -LiteralPath $configPath

        Resolve-AutopilotUpdateConfigPath -Path $configPath |
            Should -Be (Resolve-Path $configPath).Path
    }

    It 'derives the client package root from a versioned configuration' {
        $settingsPath = Join-Path $TestDrive `
            'AutopilotImport\Modules\AutopilotImport.Client\1.0.20260813.1\client.settings.json'

        Get-AutopilotClientToolsPath -SettingsPath $settingsPath |
            Should -Be (Join-Path $TestDrive 'AutopilotImport')
    }

    It 'converts the current policy into installer rules' {
        $rules = @(ConvertTo-UpdateTagAuthorizationRules -Policy @(
            [pscustomobject]@{
                groupId = '11111111-1111-1111-1111-111111111111'
                tags    = @('PAW-CSM', 'BG-Default')
            }
        ))

        $rules | Should -Be `
            '11111111-1111-1111-1111-111111111111=PAW-CSM,BG-Default'
    }

    It 'keeps a single preserved installer rule as an array' {
        $assignmentAst = $updateAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$tagAuthorizationRules'
        }, $true) | Select-Object -Last 1

        $assignmentAst.Extent.Text | Should -Match `
            '(?s)\$tagAuthorizationRules\s*=\s*@\('
    }

    It 'supports forcing an update without an execution confirmation' {
        $forceParameter = $updateAst.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'Force' }
        $forceParameter.StaticType | Should -Be ([switch])

        $updateAst.Extent.Text | Should -Match `
            '(?s)if\s*\(\s*-not\s+\$Force\s+-and\s+-not\s+\$PSCmdlet\.ShouldProcess'
        $updateAst.Extent.Text | Should -Match `
            '(?s)if\s*\(\$WhatIfPreference\).*?return.*?if\s*\(\s*-not\s+\$Force'
    }

    It 'supports an existing policy without RMAU metadata' {
        $policy = [pscustomobject]@{
            groupId = '11111111-1111-1111-1111-111111111111'
            tags    = @('Standard')
        }

        Get-UpdateRestrictedManagementAdministrativeUnitName `
            -Policy $policy | Should -BeNullOrEmpty
    }

    It 'preserves the configured RMAU name' {
        $policy = [pscustomobject]@{
            groupId = '11111111-1111-1111-1111-111111111111'
            tags    = @('Standard')
            restrictedManagementAdministrativeUnitName = `
                'RMAU-Autopilot'
        }

        Get-UpdateRestrictedManagementAdministrativeUnitName `
            -Policy $policy | Should -Be 'RMAU-Autopilot'
    }

    It 'reports a concise Function App settings permission error' {
        $response = [pscustomobject]@{
            StatusCode = 403
            Content = @{
                error = @{
                    message = "The client 'user@example.com' with object id '1234' does not have authorization."
                }
            } | ConvertTo-Json
        }

        $errorRecord = {
            Assert-AutopilotAppSettingsResponse -Response $response
        } | Should -Throw -PassThru

        $errorRecord.Exception.Message | Should -Match `
            'Microsoft.Web/sites/config/list/action permission'
        $errorRecord.Exception.Message | Should -Not -Match 'user@example.com|1234'
    }

    It 'shows Function App settings response details only with Verbose' {
        $response = [pscustomobject]@{
            StatusCode = 403
            Content = @{
                error = @{
                    message = "The client 'user@example.com' with object id '1234' does not have authorization."
                }
            } | ConvertTo-Json
        }

        $verboseOutput = try {
            Assert-AutopilotAppSettingsResponse -Response $response -Verbose 4>&1
        }
        catch {
        }

        $verboseOutput | Out-String | Should -Match 'user@example.com|1234'
    }

    It 'reports only missing Azure capabilities without Verbose' {
        Mock Invoke-AzRestMethod {
            [pscustomobject]@{
                StatusCode = 200
                Content = @{
                    value = @(@{
                        actions = @(
                            'Microsoft.Resources/*'
                            'Microsoft.Authorization/*'
                        )
                        notActions = @()
                    })
                } | ConvertTo-Json -Depth 5
            }
        }

        $errorRecord = {
            Assert-AzureUpdatePermissions `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -ResourceGroupName 'rg-test'
        } | Should -Throw -PassThru

        $errorRecord.Exception.Message | Should -Be `
            'Missing Azure permissions for: Storage accounts, Blob services, Blob containers, Application Insights, App Service plans, Function Apps, Function App configuration.'
        $errorRecord.Exception.Message | Should -Not -Match `
            'subscriptions|Microsoft\.|Assign|Connect-AzAccount'
        $errorRecord.Exception.Data['AutopilotUpdatePermissionError'] |
            Should -BeTrue
        $errorRecord.Exception.Data['PermissionDetails'] | Should -Match `
            '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-test'
        $errorRecord.Exception.Data['PermissionDetails'] | Should -Match `
            'Assign Contributor or Owner'
    }

    It 'requires an additional role administrator when role assignments are missing' {
        Mock Invoke-AzRestMethod {
            [pscustomobject]@{
                StatusCode = 200
                Content = @{
                    value = @(@{
                        actions = @('Microsoft.Resources/*')
                        notActions = @()
                    })
                } | ConvertTo-Json -Depth 5
            }
        }

        $errorRecord = {
            Assert-AzureUpdatePermissions `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -ResourceGroupName 'rg-test'
        } | Should -Throw -PassThru

        $errorRecord.Exception.Message | Should -Match 'Azure role assignments'
        $errorRecord.Exception.Data['PermissionDetails'] | Should -Match `
            'Contributor plus Role Based Access Control Administrator or User Access Administrator'
    }
}

Describe 'Azure deployment permission validation' {
    BeforeAll {
        $installerPath = Join-Path $PSScriptRoot '..\Install-AutopilotImport.ps1'
        $tokens = $null
        $parseErrors = $null
        $installerAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $installerPath,
            [ref] $tokens,
            [ref] $parseErrors
        )
        foreach ($functionName in @(
                'Test-AzurePermissionPattern'
                'Assert-AzureDeploymentPermissions'
            )) {
            $functionAst = $installerAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
            }, $true) | Select-Object -First 1
            Invoke-Expression $functionAst.Extent.Text
        }
    }

    It 'accepts wildcard permissions at the resource group scope' {
        Mock Invoke-AzRestMethod {
            [pscustomobject]@{
                StatusCode = 200
                Content = @{
                    value = @(@{
                        actions = @('*')
                        notActions = @()
                    })
                } | ConvertTo-Json -Depth 5
            }
        }

        {
            Assert-AzureDeploymentPermissions `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -ResourceGroupName 'rg-test' `
                -ResourceGroupExists
        } | Should -Not -Throw

        Should -Invoke Invoke-AzRestMethod -ParameterFilter {
            $Path -match '/resourceGroups/rg-test/providers/Microsoft.Authorization/permissions'
        }
    }

    It 'rejects permissions excluded through NotActions' {
        Mock Invoke-AzRestMethod {
            [pscustomobject]@{
                StatusCode = 200
                Content = @{
                    value = @(@{
                        actions = @('*')
                        notActions = @('Microsoft.Authorization/*')
                    })
                } | ConvertTo-Json -Depth 5
            }
        }

        {
            Assert-AzureDeploymentPermissions `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -ResourceGroupName 'rg-test' `
                -ResourceGroupExists
        } | Should -Throw '*Azure deployment permissions are insufficient*'
    }

    It 'uses a concise error when permissions cannot be queried' {
        Mock Invoke-AzRestMethod {
            throw "AuthorizationFailed for client 'user@example.com'"
        }

        $errorRecord = {
            Assert-AzureDeploymentPermissions `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -ResourceGroupName 'rg-test' `
                -ResourceGroupExists
        } | Should -Throw -PassThru

        $errorRecord.Exception.Message | Should -Match `
            'Azure deployment permissions could not be verified'
        $errorRecord.Exception.Message | Should -Not -Match 'user@example.com'
    }
}

Describe 'Installer Azure deployment diagnostics' {
    BeforeAll {
        $installerPath = Join-Path $PSScriptRoot '..\Install-AutopilotImport.ps1'
        $tokens = $null
        $parseErrors = $null
        $installerAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $installerPath,
            [ref] $tokens,
            [ref] $parseErrors
        )
        $functionAst = $installerAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Format-AzureDeploymentError'
        }, $true) | Select-Object -First 1
        Invoke-Expression $functionAst.Extent.Text
    }

    It 'preserves nested Azure Policy violation details' {
        $policyError = [pscustomobject]@{
            Code = 'InvalidTemplateDeployment'
            Details = @(
                [pscustomobject]@{
                    Code = 'RequestDisallowedByPolicy'
                    Message = "Resource 'func-autopilot-test' was disallowed by policy."
                    AdditionalInfo = [pscustomobject]@{
                        policyAssignmentDisplayName = 'Require approved Function plans'
                    }
                }
            )
        }

        $formattedError = Format-AzureDeploymentError -ErrorObject $policyError

        $formattedError | Should -Match 'RequestDisallowedByPolicy'
        $formattedError | Should -Match 'func-autopilot-test'
        $formattedError | Should -Match 'Require approved Function plans'
    }
}

Describe 'Installer Azure resource provider registration' {
    BeforeAll {
        $installerPath = Join-Path $PSScriptRoot '..\Install-AutopilotImport.ps1'
        $tokens = $null
        $parseErrors = $null
        $installerAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $installerPath,
            [ref] $tokens,
            [ref] $parseErrors
        )
        $functionAst = $installerAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Register-AzureResourceProvider'
        }, $true) | Select-Object -First 1
        Invoke-Expression $functionAst.Extent.Text
    }

    It 'does not register an already registered provider' {
        Mock Get-AzResourceProvider { [pscustomobject]@{ RegistrationState = 'Registered' } }
        Mock Register-AzResourceProvider

        Register-AzureResourceProvider -ProviderNamespace 'Microsoft.OperationalInsights'

        Should -Invoke Register-AzResourceProvider -Times 0
    }

    It 'registers a missing provider' {
        Mock Get-AzResourceProvider { [pscustomobject]@{ RegistrationState = 'NotRegistered' } }
        Mock Register-AzResourceProvider { [pscustomobject]@{ RegistrationState = 'Registered' } }

        Register-AzureResourceProvider -ProviderNamespace 'Microsoft.OperationalInsights'

        Should -Invoke Register-AzResourceProvider -Times 1 -ParameterFilter {
            $ProviderNamespace -eq 'Microsoft.OperationalInsights'
        }
    }
}

Describe 'Installer Azure resource group tags' {
    BeforeAll {
        $installerPath = Join-Path $PSScriptRoot '..\Install-AutopilotImport.ps1'
        $tokens = $null
        $parseErrors = $null
        $installerAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $installerPath,
            [ref] $tokens,
            [ref] $parseErrors
        )
        $functionAst = $installerAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Set-ResourceGroupTags'
        }, $true) | Select-Object -First 1
        Invoke-Expression $functionAst.Extent.Text
        $functionAst = $installerAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Initialize-AzureResourceGroup'
        }, $true) | Select-Object -First 1
        Invoke-Expression $functionAst.Extent.Text
    }

    It 'includes tags in the resource group creation request' {
        Mock Get-AzResourceGroup
        Mock New-AzResourceGroup {
            [pscustomobject]@{ ResourceId = '/subscriptions/test/resourceGroups/rg-autopilot' }
        }
        Mock Update-AzTag

        Initialize-AzureResourceGroup `
            -Name 'rg-autopilot' `
            -Location 'westeurope' `
            -Tags @{ Environment = 'Production'; Owner = 'Endpoint Team' }

        Should -Invoke New-AzResourceGroup -Times 1 -ParameterFilter {
            $Name -eq 'rg-autopilot' -and
            $Location -eq 'westeurope' -and
            $Tag.Environment -eq 'Production' -and
            $Tag.Owner -eq 'Endpoint Team'
        }
        Should -Invoke Update-AzTag -Times 0
    }

    It 'merges supplied tags without replacing unrelated tags' {
        Mock Update-AzTag

        Set-ResourceGroupTags `
            -ResourceId '/subscriptions/test/resourceGroups/rg-autopilot' `
            -Tags @{ Environment = 'Production'; Owner = 'Endpoint Team' }

        Should -Invoke Update-AzTag -Times 1 -ParameterFilter {
            $ResourceId -eq '/subscriptions/test/resourceGroups/rg-autopilot' -and
            $Operation -eq 'Merge' -and
            $Tag.Environment -eq 'Production' -and
            $Tag.Owner -eq 'Endpoint Team'
        }
    }

    It 'does not call Azure when no tags were supplied' {
        Mock Update-AzTag

        Set-ResourceGroupTags `
            -ResourceId '/subscriptions/test/resourceGroups/rg-autopilot' `
            -Tags @{}

        Should -Invoke Update-AzTag -Times 0
    }
}

Describe 'Tag authorization policy updates' {
    It 'identifies added and removed groups without changing retained groups' {
        $previousPolicy = ConvertTo-TagAuthorizationPolicy -Rules @(
            '11111111-1111-1111-1111-111111111111=Standard'
            '22222222-2222-2222-2222-222222222222=Kiosk'
        )
        $updatedPolicy = ConvertTo-TagAuthorizationPolicy -Rules @(
            '22222222-2222-2222-2222-222222222222=Privileged'
            '33333333-3333-3333-3333-333333333333=Standard'
        )

        $changes = Compare-TagAuthorizationPolicyGroups `
            -PreviousPolicy $previousPolicy `
            -UpdatedPolicy $updatedPolicy

        $changes.AddedGroupIds | Should -Be '33333333-3333-3333-3333-333333333333'
        $changes.RemovedGroupIds | Should -Be '11111111-1111-1111-1111-111111111111'
    }

    It 'does not change group assignments when only tags change' {
        $previousPolicy = ConvertTo-TagAuthorizationPolicy -Rules @(
            '11111111-1111-1111-1111-111111111111=Standard'
        )
        $updatedPolicy = ConvertTo-TagAuthorizationPolicy -Rules @(
            '11111111-1111-1111-1111-111111111111=Standard,Kiosk'
        )

        $changes = Compare-TagAuthorizationPolicyGroups `
            -PreviousPolicy $previousPolicy `
            -UpdatedPolicy $updatedPolicy

        $changes.AddedGroupIds.Count | Should -Be 0
        $changes.RemovedGroupIds.Count | Should -Be 0
    }
}

Describe 'Tag policy manager authorization' {
    BeforeAll {
        $managerPolicy = [pscustomobject]@{
            principalIds = @(
                '11111111-1111-1111-1111-111111111111'
                '22222222-2222-2222-2222-222222222222'
            )
        }
    }

    It 'allows an explicitly configured user' {
        $principal = [pscustomobject]@{
            claims = @(
                @{ typ = 'oid'; val = '11111111-1111-1111-1111-111111111111' }
            )
        }

        Test-TagPolicyManagerPrincipal `
            -Principal $principal `
            -ManagerPolicy $managerPolicy |
            Should -Be $true
    }

    It 'allows membership in an explicitly configured group' {
        $principal = [pscustomobject]@{
            claims = @(
                @{ typ = 'oid'; val = '33333333-3333-3333-3333-333333333333' }
                @{ typ = 'groups'; val = '22222222-2222-2222-2222-222222222222' }
            )
        }

        Test-TagPolicyManagerPrincipal `
            -Principal $principal `
            -ManagerPolicy $managerPolicy |
            Should -Be $true
    }

    It 'rejects an unconfigured principal' {
        $principal = [pscustomobject]@{
            claims = @(
                @{ typ = 'oid'; val = '33333333-3333-3333-3333-333333333333' }
            )
        }

        Test-TagPolicyManagerPrincipal `
            -Principal $principal `
            -ManagerPolicy $managerPolicy |
            Should -Be $false
    }
}

Describe 'Tag manager policy Azure administration' {
    BeforeAll {
        $functionResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-autopilot/providers/Microsoft.Web/sites/func-autopilot'
    }

    It 'allows Contributor inherited from the resource group' {
        $assignments = @([pscustomobject]@{
            RoleDefinitionName = 'Contributor'
            Scope = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-autopilot'
        })

        Test-TagManagerPolicyAdministratorRole `
            -RoleAssignment $assignments `
            -FunctionResourceId $functionResourceId |
            Should -Be $true
    }

    It 'allows Owner assigned directly to the Function' {
        $assignments = @([pscustomobject]@{
            RoleDefinitionName = 'Owner'
            Scope = $functionResourceId
        })

        Test-TagManagerPolicyAdministratorRole `
            -RoleAssignment $assignments `
            -FunctionResourceId $functionResourceId |
            Should -Be $true
    }

    It 'rejects other write roles' {
        $assignments = @([pscustomobject]@{
            RoleDefinitionName = 'Website Contributor'
            Scope = $functionResourceId
        })

        Test-TagManagerPolicyAdministratorRole `
            -RoleAssignment $assignments `
            -FunctionResourceId $functionResourceId |
            Should -Be $false
    }
}

Describe 'Intune Role Administrator authorization' {
    It 'allows a caller object ID included in the built-in role assignment' {
        $principal = [pscustomobject]@{
            claims = @(
                @{ typ = 'oid'; val = '11111111-1111-1111-1111-111111111111' }
            )
        }
        $assignments = @([pscustomobject]@{
            roleDefinition = [pscustomobject]@{
                displayName = 'Intune Role Administrator'
            }
            members = @('11111111-1111-1111-1111-111111111111')
        })

        Test-IntuneRoleAdministratorAssignment `
            -Principal $principal `
            -RoleAssignment $assignments |
            Should -Be $true
    }

    It 'allows a caller group included in the built-in role assignment' {
        $principal = [pscustomobject]@{
            claims = @(
                @{ typ = 'oid'; val = '11111111-1111-1111-1111-111111111111' }
                @{ typ = 'groups'; val = '22222222-2222-2222-2222-222222222222' }
            )
        }
        $assignments = @([pscustomobject]@{
            roleDefinition = [pscustomobject]@{
                displayName = 'Intune Role Administrator'
            }
            members = @('22222222-2222-2222-2222-222222222222')
        })

        Test-IntuneRoleAdministratorAssignment `
            -Principal $principal `
            -RoleAssignment $assignments |
            Should -Be $true
    }

    It 'rejects assignments for another Intune role' {
        $principal = [pscustomobject]@{
            claims = @(
                @{ typ = 'oid'; val = '11111111-1111-1111-1111-111111111111' }
            )
        }
        $assignments = @([pscustomobject]@{
            roleDefinition = [pscustomobject]@{
                displayName = 'Read Only Operator'
            }
            members = @('11111111-1111-1111-1111-111111111111')
        })

        Test-IntuneRoleAdministratorAssignment `
            -Principal $principal `
            -RoleAssignment $assignments |
            Should -Be $false
    }
}

Describe 'Storage Account update compatibility' {
    It 'does not redeclare immutable infrastructure encryption' {
        $projectRoot = Split-Path $PSScriptRoot -Parent
        $template = Get-Content `
            -LiteralPath (Join-Path $projectRoot 'infra\main.bicep') `
            -Raw

        $template | Should -Not -Match 'requireInfrastructureEncryption'
    }
}

Describe 'Setup activity logging' {
    It 'logs installation and update activity in the temporary directory' {
        $projectRoot = Split-Path $PSScriptRoot -Parent

        foreach ($scriptName in @(
                'Install-AutopilotImport.ps1'
                'Update-AutopilotImport.ps1'
            )) {
            $content = Get-Content `
                -LiteralPath (Join-Path $projectRoot $scriptName) `
                -Raw

            $content | Should -Match '\[IO\.Path\]::GetTempPath\(\)'
            $content | Should -Match 'Start-Transcript'
            $content | Should -Match '\[guid\]::NewGuid\(\)'
            $content | Should -Match 'Format-List \* -Force'
            $content | Should -Match 'Add-Content'
            $content | Should -Match 'Script stack trace:'
            $content | Should -Match 'Stop-Transcript'
            $content | Should -Match `
                'Stop-Transcript[\s\S]+\$setupTranscriptActive = \$false[\s\S]+Add-Content'
        }
    }

    It 'creates a separate transcript for each script invocation' {
        $projectRoot = Split-Path $PSScriptRoot -Parent
        $installer = Get-Content `
            -LiteralPath (Join-Path $projectRoot 'Install-AutopilotImport.ps1') `
            -Raw
        $update = Get-Content `
            -LiteralPath (Join-Path $projectRoot 'Update-AutopilotImport.ps1') `
            -Raw

        $installer | Should -Match `
            'Intune-Autopilotimport-install-.+NewGuid'
        $update | Should -Match `
            'Intune-Autopilotimport-update-.+NewGuid'
        $installer | Should -Not -Match 'INTUNE_AUTOPILOTIMPORT_SETUP_LOG'
        $update | Should -Not -Match 'INTUNE_AUTOPILOTIMPORT_SETUP_LOG'
    }
}

Describe 'Project metadata entries' {
    It 'uses the central version in every PowerShell file' {
        $projectRoot = Split-Path $PSScriptRoot -Parent
        $projectVersion = (Get-Content (Join-Path $projectRoot 'VERSION') -Raw).Trim()
        $projectVersion | Should -Match '^1\.0\.\d{8}\.\d+$'

        $powerShellFiles = @(
            Get-ChildItem -LiteralPath $projectRoot -Recurse -File |
                Where-Object Extension -in '.ps1', '.psm1', '.psd1'
        )
        foreach ($file in $powerShellFiles) {
            $content = Get-Content -LiteralPath $file.FullName -Raw
            $markers = [regex]::Matches(
                $content,
                '(?m)^# Project-Version: (?<version>\d+\.\d+\.\d{8}\.\d+)\r?$'
            )
            $markers.Count | Should -Be 1
            $markers[0].Groups['version'].Value | Should -Be $projectVersion
        }
    }

    It 'uses the central version as the client module version' {
        $projectRoot = Split-Path $PSScriptRoot -Parent
        $projectVersion = (Get-Content `
            (Join-Path $projectRoot 'VERSION') `
            -Raw).Trim()
        $manifest = Import-PowerShellDataFile `
            (Join-Path $projectRoot `
                'src\AutopilotImport.Client\AutopilotImport.Client.psd1')

        [string] $manifest.ModuleVersion | Should -Be $projectVersion
    }

    It 'uses the central author in every PowerShell file' {
        $projectRoot = Split-Path $PSScriptRoot -Parent
        $projectAuthor = (Get-Content (Join-Path $projectRoot 'AUTHOR') -Raw).Trim()

        $powerShellFiles = @(
            Get-ChildItem -LiteralPath $projectRoot -Recurse -File |
                Where-Object Extension -in '.ps1', '.psm1', '.psd1'
        )
        foreach ($file in $powerShellFiles) {
            $content = Get-Content -LiteralPath $file.FullName -Raw
            $markers = [regex]::Matches(
                $content,
                '(?m)^# Author: (?<author>[^\r\n]+)\r?$'
            )
            $markers.Count | Should -Be 1
            $markers[0].Groups['author'].Value | Should -Be $projectAuthor
        }
    }
}

Describe 'Deployment package' {
    It 'runs automatically for main but not for dev pushes' {
        $workflowPath = Join-Path `
            $PSScriptRoot `
            '..\.github\workflows\deployment-package.yml'
        $workflow = Get-Content -LiteralPath $workflowPath -Raw

        $workflow | Should -Match `
            '(?ms)^  push:\s+branches:\s+- main\s*$'
        $workflow | Should -Match `
            '(?ms)^  pull_request:\s+branches:\s+- main\s*$'
        $workflow | Should -Match '(?m)^  workflow_dispatch:\s*$'
        $workflow | Should -Not -Match '(?m)^\s+- dev\s*$'
        $workflow | Should -Match 'actions/upload-artifact@v4'
    }

    It 'allows pull requests to main only from dev' {
        $workflowPath = Join-Path `
            $PSScriptRoot `
            '..\.github\workflows\main-promotion-policy.yml'
        $workflow = Get-Content -LiteralPath $workflowPath -Raw

        $workflow | Should -Match `
            '(?ms)^  pull_request:\s+branches:\s+- main\s*$'
        $workflow | Should -Match `
            '(?m)^    name: Validate dev promotion\s*$'
        $workflow | Should -Match `
            '\[\[ "\$SOURCE_BRANCH" != "dev" \]\]'
        $workflow | Should -Match `
            'SOURCE_BRANCH: \$\{\{ github\.head_ref \}\}'
    }

    It 'contains installation and runtime files without local configuration' {
        $projectRoot = Join-Path $PSScriptRoot '..'
        $outputDirectory = Join-Path $TestDrive 'artifacts'
        $package = & (Join-Path `
            $projectRoot `
            'scripts\New-DeploymentPackage.ps1') `
            -ProjectRoot $projectRoot `
            -OutputDirectory $outputDirectory
        $packageRoot = "Intune-Autopilotimport-deployment-$((Get-Content `
            -LiteralPath (Join-Path $projectRoot 'VERSION') `
            -Raw).Trim())"

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($package.FullName)
        try {
            $entries = @($archive.Entries.FullName)
            foreach ($requiredEntry in @(
                    'README.md'
                    'Install-AutopilotImport.ps1'
                    'Update-AutopilotImport.ps1'
                    'infra/main.bicep'
                    'src/AutopilotImport/AutopilotImport.psm1'
                    'src/AutopilotImport.Client/AutopilotImport.Client.psd1'
                    'scripts/Ensure-EntraApiApplication.ps1'
                    'scripts/Grant-ManagedIdentityGraphPermission.ps1'
                    'scripts/Import-AutopilotDevice.ps1'
                    'scripts/Set-TagAuthorizationPolicy.ps1'
                    'scripts/Set-TagPolicyManagers.ps1'
                )) {
                $entries | Should -Contain "$packageRoot/$requiredEntry"
            }
            $entries | Where-Object {
                $_ -match `
                    '(^|/)(client\.settings\.json|local\.settings\.json|tests|\.git)(/|$)'
            } | Should -BeNullOrEmpty
                    foreach ($developmentScript in @(
                        'scripts/New-DeploymentPackage.ps1'
                        'scripts/New-SyntheticAutopilotTestCsv.ps1'
                        'scripts/Update-ProjectVersion.ps1'
                    )) {
                    $entries | Should -Not -Contain `
                        "$packageRoot/$developmentScript"
                    }
        }
        finally {
            $archive.Dispose()
        }
    }
}