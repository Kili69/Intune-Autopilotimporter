# Project-Version: 1.0.20260812.2
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
            -ClientSettingsJson $settings

        $modulePath = Join-Path $destinationPath `
            'Modules\AutopilotImport.Client\1.0.20260812.2'
        $settingsPath | Should -Be (Join-Path $modulePath 'client.settings.json')
        @(
            'scripts\Import-AutopilotDevice.ps1'
            'scripts\Set-TagAuthorizationPolicy.ps1'
            'scripts\Set-TagPolicyManagers.ps1'
            'Modules\AutopilotImport.Client\1.0.20260812.2\AutopilotImport.Client.psm1'
            'Modules\AutopilotImport.Client\1.0.20260812.2\AutopilotImport.Client.psd1'
            'Modules\AutopilotImport.Client\1.0.20260812.2\AutopilotImport.psm1'
            'Modules\AutopilotImport.Client\1.0.20260812.2\client.settings.json'
        ) | ForEach-Object {
            Join-Path $destinationPath $_ | Should -Exist
        }
        $installedSettings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        $installedSettings.functionAppName | Should -Be 'func-test'
        $installedSettings.subscriptionId | Should -Be `
            '33333333-3333-3333-3333-333333333333'

        Import-Module `
            (Join-Path $modulePath 'AutopilotImport.Client.psd1') `
            -Force
        (Get-Command -Module AutopilotImport.Client).Count | Should -Be 7
        Remove-Module AutopilotImport.Client
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