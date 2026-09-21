# Project-Version: 1.1.20260921.2
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
.SYNOPSIS
Runs unit tests for Autopilot import validation and authorization.

.DESCRIPTION
Pester tests covering Microsoft Graph payload construction, malformed hardware
hash rejection, Easy Auth role enforcement, Entra group-to-tag authorization,
tag casing, installer authorization-rule parsing, and project metadata markers.

.EXAMPLE
Invoke-Pester -Script .\src\Tests\AutopilotImport.Tests.ps1

Runs the test suite with Pester 5 syntax.

.INPUTS
None.

.OUTPUTS
Pester test results when invoked through Invoke-Pester.
#>

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath = Join-Path $PSScriptRoot '..\FunctionApp\src\AutopilotImport\AutopilotImport.psm1'
Remove-Module AutopilotImport -Force -ErrorAction SilentlyContinue
Import-Module $modulePath -Force

Describe 'Client API error messages' {
    BeforeAll {
        $clientModulePath = Join-Path $PSScriptRoot `
            '..\AutopilotImport.Client\AutopilotImport.Client.psd1'
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
            '..\AutopilotImport.Client\AutopilotImport.Client.psd1'
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

Describe 'Client CSV input validation' {
    BeforeAll {
        $clientModulePath = Join-Path $PSScriptRoot `
            '..\AutopilotImport.Client\AutopilotImport.Client.psd1'
        Import-Module $clientModulePath -Force
    }

    It 'explains when the CSV file does not exist' {
        $missingPath = Join-Path $TestDrive 'missing.csv'

        {
            Import-AutoPilotDevice `
                -CsvPath $missingPath `
                -GroupTag 'EUD' `
                -ValidateOnly
        } | Should -Throw `
            "The Autopilot CSV file '$missingPath' does not exist or is not a file. Verify the path and try again."
    }

    It 'explains when the CSV file is empty' {
        $emptyPath = Join-Path $TestDrive 'empty.csv'
        [IO.File]::WriteAllBytes($emptyPath, [byte[]]::new(0))

        {
            Import-AutoPilotDevice `
                -CsvPath $emptyPath `
                -GroupTag 'EUD' `
                -ValidateOnly
        } | Should -Throw `
            "The Autopilot CSV file '$emptyPath' is empty. Export the device data again and try again."
    }

    It 'validates but does not authenticate or submit devices with WhatIf' {
        $csvPath = Join-Path $TestDrive 'devices.csv'
        @'
"Device Serial Number","Hardware Hash"
"SERIAL-001","AQ=="
'@ | Set-Content -LiteralPath $csvPath
        Mock Get-ClientAccessToken -ModuleName AutopilotImport.Client
        Mock Invoke-RestMethod -ModuleName AutopilotImport.Client

        Import-AutoPilotDevice `
            -CsvPath $csvPath `
            -GroupTag 'EUD' `
            -FunctionUrl 'https://func.example/api/devices/import' `
            -ApiApplicationIdUri 'api://33333333-3333-3333-3333-333333333333' `
            -TenantId '44444444-4444-4444-4444-444444444444' `
            -WhatIf

        Should -Invoke Get-ClientAccessToken `
            -ModuleName AutopilotImport.Client `
            -Times 0
        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport.Client `
            -Times 0
    }
}

Describe 'Standalone REST import script' {
    BeforeAll {
        $standaloneRepositoryRoot = Split-Path `
            (Split-Path $PSScriptRoot -Parent) -Parent
        $importScriptPath = Join-Path $standaloneRepositoryRoot `
            'src\Scripts\Import-AutopilotDevice.ps1'
        $importScriptContent = Get-Content $importScriptPath -Raw
    }

    BeforeEach {
        $csvPath = Join-Path $TestDrive 'standalone-devices.csv'
        @'
"Device Serial Number","Hardware Hash"
"SERIAL-REST-001","AQ=="
'@ | Set-Content -LiteralPath $csvPath

        Mock Invoke-RestMethod {
            [pscustomobject]@{
                authority = `
                    'https://login.microsoftonline.com/22222222-2222-2222-2222-222222222222'
                scope = `
                    'api://33333333-3333-3333-3333-333333333333/DeviceHash.Import'
                importUrl = 'https://import.example/api/devices/import'
            }
        }
    }

    It 'uses REST directly, imports without a default confirmation, and retains WhatIf support' {
        $importScriptContent | Should -Match `
            '(?m)^#Requires -Version 5\.1\r?$'
        $importScriptContent | Should -Not -Match `
            'Import-Module\s+.*AutopilotImport\.Client'
        $importScriptContent | Should -Match `
            'Install-Module\s+`\s*-Name Az\.Accounts'
        $importScriptContent | Should -Not -Match `
            '(?m)^\s*-(Authentication|Token)\s'
        $importScriptContent | Should -Not -Match `
            'ConvertFrom-SecureString.*-AsPlainText'
        $importScriptContent | Should -Match `
            "CmdletBinding\(SupportsShouldProcess, ConfirmImpact = 'Low'\)"
        $importScriptContent | Should -Not -Match `
            '(?s)\[Parameter\(Mandatory\)\]\s*\[ValidateScript.*?\[string\] \$CsvPath'
        $importScriptContent | Should -Match `
            "else \{\s*Get-LocalAutoPilotDevice\s*\}"
        $importScriptContent | Should -Match '\$pollIntervalSeconds = 10'
        $importScriptContent | Should -Match 'Invoke-RestMethod'
    }

    It 'normalizes the application root and validates a CSV without authentication' {
        $result = & $importScriptPath `
            -ApplicationUrl 'https://import.example' `
            -CsvPath $csvPath `
            -GroupTag 'PAW' `
            -ValidateOnly

        $result.ApplicationUrl | Should -Be `
            'https://import.example/api/ui/index.html'
        $result.ImportUrl | Should -Be `
            'https://import.example/api/devices/import'
        $result.DeviceCount | Should -Be 1
        $result.SerialNumbers | Should -Be 'SERIAL-REST-001'
        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
            $Method -eq 'Get' -and
            [string] $Uri -eq 'https://import.example/api/ui/config'
        }
    }

    It 'stops before authentication and import when WhatIf is used' {
        & $importScriptPath `
            -ApplicationUrl 'https://import.example/api/ui' `
            -CsvPath $csvPath `
            -GroupTag 'PAW' `
            -WhatIf

        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
            $Method -eq 'Get'
        }
    }

    It 'writes non-sensitive execution details with Verbose' {
        $verboseOutput = & $importScriptPath `
            -ApplicationUrl 'https://import.example' `
            -CsvPath $csvPath `
            -GroupTag 'PAW' `
            -ValidateOnly `
            -Verbose 4>&1
        $verboseText = $verboseOutput | Out-String

        $verboseText | Should -Match 'Reading runtime configuration'
        $verboseText | Should -Match 'Validated 1 device record'
        $verboseText | Should -Match 'authentication and import were skipped'
        $verboseText | Should -Not -Match 'AQ=='
    }

    It 'explains a forbidden Group Tag and shows its correlation ID only with Verbose' {
        function global:Get-AzContext {
            [pscustomobject]@{
                Tenant = [pscustomobject]@{
                    Id = '22222222-2222-2222-2222-222222222222'
                }
            }
        }
        function global:Connect-AzAccount {}
        function global:Get-AzAccessToken {
            [pscustomobject]@{ Token = 'test-token' }
        }
        try {
            Mock Invoke-RestMethod {
                if ($Method -eq 'Post') {
                    $exception = [InvalidOperationException]::new(
                        'The remote server returned an error: (403) Forbidden.')
                    $apiError = [Management.Automation.ErrorRecord]::new(
                        $exception,
                        'HttpResponseException',
                        [Management.Automation.ErrorCategory]::PermissionDenied,
                        $null)
                    $apiError.ErrorDetails = `
                        [Management.Automation.ErrorDetails]::new(
                            '{"error":"groupTagNotAllowed","correlationId":"109ff31c-4392-415a-b39f-56d3d7776110"}')
                    throw $apiError
                }
                [pscustomobject]@{
                    authority = `
                        'https://login.microsoftonline.com/22222222-2222-2222-2222-222222222222'
                    scope = `
                        'api://33333333-3333-3333-3333-333333333333/DeviceHash.Import'
                    importUrl = 'https://import.example/api/devices/import'
                }
            }

            $global:LASTEXITCODE = 0
            $standardOutput = & $importScriptPath `
                -ApplicationUrl 'https://import.example' `
                -CsvPath $csvPath `
                -GroupTag 'paw/csm' 6>&1
            $standardText = $standardOutput | Out-String

            $standardText | Should -Match `
                "Group Tag 'paw/csm' is not allowed for the signed-in user"
            $standardText | Should -Not -Match 'Correlation ID'
            $standardText | Should -Not -Match `
                'CategoryInfo|FullyQualifiedErrorId|At .*Import-AutopilotDevice'
            $global:LASTEXITCODE | Should -Be 1

            $global:LASTEXITCODE = 0
            $verboseOutput = & $importScriptPath `
                -ApplicationUrl 'https://import.example' `
                -CsvPath $csvPath `
                -GroupTag 'paw/csm' `
                -Verbose 4>&1 6>&1
            $verboseText = $verboseOutput | Out-String

            $verboseText | Should -Match `
                'Correlation ID: 109ff31c-4392-415a-b39f-56d3d7776110'
            $verboseText | Should -Not -Match `
                'CategoryInfo|FullyQualifiedErrorId|At .*Import-AutopilotDevice'
            $global:LASTEXITCODE | Should -Be 1
        }
        finally {
            Remove-Item Function:\Get-AzContext -ErrorAction SilentlyContinue
            Remove-Item Function:\Connect-AzAccount -ErrorAction SilentlyContinue
            Remove-Item Function:\Get-AzAccessToken -ErrorAction SilentlyContinue
        }
    }

    It 'posts the hash and polls every ten seconds until the workflow completes' {
        function global:Get-AzContext {
            [pscustomobject]@{
                Tenant = [pscustomobject]@{
                    Id = '22222222-2222-2222-2222-222222222222'
                }
            }
        }
        function global:Connect-AzAccount {}
        function global:Get-AzAccessToken {
            [pscustomobject]@{
                Token = ConvertTo-SecureString `
                    'test-token' `
                    -AsPlainText `
                    -Force
            }
        }
        try {
            Mock Start-Sleep
            Mock Invoke-RestMethod {
                if ($Method -eq 'Post') {
                    return [pscustomobject]@{
                        importId = '44444444-4444-4444-4444-444444444444'
                        serialNumber = 'SERIAL-REST-001'
                        status = 'pending'
                    }
                }
                if ([string] $Uri -match '\?importId=') {
                    return [pscustomobject]@{
                        importId = '44444444-4444-4444-4444-444444444444'
                        serialNumber = 'SERIAL-REST-001'
                        status = 'complete'
                        workflowStatus = 'complete'
                        extensionAttributeStatus = 'complete'
                    }
                }
                return [pscustomobject]@{
                    authority = `
                        'https://login.microsoftonline.com/22222222-2222-2222-2222-222222222222'
                    scope = `
                        'api://33333333-3333-3333-3333-333333333333/DeviceHash.Import'
                    importUrl = 'https://import.example/api/devices/import'
                }
            }

            $result = & $importScriptPath `
                -ApplicationUrl 'https://import.example' `
                -CsvPath $csvPath `
                -GroupTag 'PAW'

            $result.workflowStatus | Should -Be 'complete'
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Method -eq 'Post' -and
                [string] $Uri -eq 'https://import.example/api/devices/import' -and
                $Headers.Authorization -eq 'Bearer test-token'
            }
            Should -Invoke Start-Sleep -Times 1 -ParameterFilter {
                $Seconds -eq 10
            }
        }
        finally {
            Remove-Item Function:\Get-AzContext -ErrorAction SilentlyContinue
            Remove-Item Function:\Connect-AzAccount -ErrorAction SilentlyContinue
            Remove-Item Function:\Get-AzAccessToken -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Client configuration creation' {
    BeforeAll {
        $clientModulePath = Join-Path $PSScriptRoot `
            '..\AutopilotImport.Client\AutopilotImport.Client.psd1'
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
        $settingsFile = New-AutoPilotImporterClientConfiguration `
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
        $settings.webUrl | Should -Be `
            'https://func-autopilot-import.azurewebsites.net/api/ui/index.html'
        $warnings | Out-String | Should -Match `
            'AutopilotImport.Client.*client.settings.json'
    }

    It 'creates client.settings.json in the current directory by default' {
        $currentDirectory = Join-Path $TestDrive 'current'
        New-Item -Path $currentDirectory -ItemType Directory | Out-Null
        Push-Location $currentDirectory
        try {
            $settingsFile = New-AutoPilotImporterClientConfiguration `
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
            New-AutoPilotImporterClientConfiguration `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -ResourceGroupName 'rg-autopilot-import' `
                -TenantId '22222222-2222-2222-2222-222222222222' `
                -FunctionAppName 'func-autopilot-import' `
                -OutputPath $TestDrive
        } | Should -Throw '*already exists*Use -Force*'

        Get-Content -LiteralPath $settingsPath -Raw | Should -BeLike 'existing*'
    }
}

Describe 'Client configuration display' {
    BeforeAll {
        $clientModulePath = Join-Path $PSScriptRoot `
            '..\AutopilotImport.Client\AutopilotImport.Client.psd1'
        Import-Module $clientModulePath -Force
    }

    It 'exports the configuration display command' {
        Get-Command Get-AutoPilotImporterClientConfiguration `
            -Module AutopilotImport.Client |
            Should -Not -BeNullOrEmpty
    }

    It 'exports all client commands with consistent AutoPilot casing' {
        $expectedCommands = @(
            'Add-AutoPilotTagPolicy'
            'Add-AutoPilotTagPolicyManager'
            'Get-AutoPilotImporterClientConfiguration'
            'Get-AutoPilotImportHistory'
            'Get-AutoPilotImportStatus'
            'Get-AutoPilotTagPolicy'
            'Get-AutoPilotTagPolicyManager'
            'Import-AutoPilotDevice'
            'New-AutoPilotImporterClientConfiguration'
            'Remove-AutoPilotTagPolicy'
            'Remove-AutoPilotTagPolicyManager'
            'Set-AutoPilotTagPolicy'
            'Update-AutoPilotTagPolicyManager'
        )

        $actualCommands = @(Get-Command `
                -Module AutopilotImport.Client).Name | Sort-Object

        $actualCommands | Should -Be $expectedCommands
    }

    It 'bootstraps and persists configuration from the Function URL' {
        $settingsPath = Join-Path $TestDrive 'profile\client.settings.json'
        Mock Get-DefaultClientConfigurationPath `
            -ModuleName AutopilotImport.Client { $settingsPath }
        Mock Invoke-RestMethod -ModuleName AutopilotImport.Client {
            [pscustomobject]@{
                clientId = '44444444-4444-4444-4444-444444444444'
                authority = 'https://login.microsoftonline.com/22222222-2222-2222-2222-222222222222'
                scope = 'api://33333333-3333-3333-3333-333333333333/DeviceHash.Import'
                redirectUri = 'https://func-example.azurewebsites.net/api/ui/index.html'
                importUrl = 'https://func-example.azurewebsites.net/api/devices/import'
                tagsUrl = 'https://func-example.azurewebsites.net/api/devices/tags'
                functionVersion = '1.1.20260921.1'
            }
        }

        $configuration = Get-AutoPilotImporterClientConfiguration `
            -FunctionUrl 'https://func-example.azurewebsites.net/api/ui/index.html'
        $persistedConfiguration = `
            Get-AutoPilotImporterClientConfiguration

        Test-Path -LiteralPath $settingsPath -PathType Leaf | Should -BeTrue
        $configuration.ConfigPath | Should -Be `
            ([IO.Path]::GetFullPath($settingsPath))
        $persistedConfiguration.FunctionUrl | Should -Be `
            'https://func-example.azurewebsites.net/api/devices/import'
        $persistedConfiguration.ManagementUrl | Should -Be `
            'https://func-example.azurewebsites.net/api/management/tag-policy'
        $persistedConfiguration.ApiApplicationIdUri | Should -Be `
            'api://33333333-3333-3333-3333-333333333333'
        $persistedConfiguration.TenantId | Should -Be `
            '22222222-2222-2222-2222-222222222222'
        $persistedConfiguration.FunctionAppName | Should -Be 'func-example'
        $persistedConfiguration.WebClientId | Should -Be `
            '44444444-4444-4444-4444-444444444444'
        $persistedConfiguration.FunctionVersion | Should -Be `
            '1.1.20260921.1'
        $persistedConfiguration.SubscriptionId | Should -BeNullOrEmpty
        $persistedConfiguration.ResourceGroupName | Should -BeNullOrEmpty
        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport.Client `
            -ParameterFilter {
                $Method -eq 'Get' -and
                $Uri -eq 'https://func-example.azurewebsites.net/api/ui/config'
            } `
            -Times 1
    }

    It 'persists Azure deployment details for a custom Function domain' {
        $settingsPath = Join-Path $TestDrive `
            'custom-domain\client.settings.json'
        Mock Invoke-RestMethod -ModuleName AutopilotImport.Client {
            [pscustomobject]@{
                clientId = '44444444-4444-4444-4444-444444444444'
                authority = 'https://login.microsoftonline.com/22222222-2222-2222-2222-222222222222'
                scope = 'api://33333333-3333-3333-3333-333333333333/DeviceHash.Import'
                importUrl = 'https://autopilot.example/api/devices/import'
            }
        }

        $configuration = Get-AutoPilotImporterClientConfiguration `
            -FunctionUrl 'https://autopilot.example' `
            -SubscriptionId '11111111-1111-1111-1111-111111111111' `
            -ResourceGroupName 'rg-autopilot-import' `
            -FunctionAppName 'func-autopilot-import' `
            -ConfigPath $settingsPath

        $configuration.SubscriptionId | Should -Be `
            '11111111-1111-1111-1111-111111111111'
        $configuration.ResourceGroupName | Should -Be `
            'rg-autopilot-import'
        $configuration.FunctionAppName | Should -Be `
            'func-autopilot-import'
    }

    It 'preserves existing Azure deployment details during URL bootstrap' {
        $settingsPath = Join-Path $TestDrive `
            'existing-profile\client.settings.json'
        New-Item -Path (Split-Path $settingsPath -Parent) `
            -ItemType Directory -Force | Out-Null
        @{
            subscriptionId = '11111111-1111-1111-1111-111111111111'
            resourceGroupName = 'rg-autopilot-import'
            functionAppName = 'func-autopilot-import'
        } | ConvertTo-Json | Set-Content -LiteralPath $settingsPath
        Mock Invoke-RestMethod -ModuleName AutopilotImport.Client {
            [pscustomobject]@{
                clientId = '44444444-4444-4444-4444-444444444444'
                authority = 'https://login.microsoftonline.com/22222222-2222-2222-2222-222222222222'
                scope = 'api://33333333-3333-3333-3333-333333333333/DeviceHash.Import'
                importUrl = 'https://autopilot.example/api/devices/import'
            }
        }

        $configuration = Get-AutoPilotImporterClientConfiguration `
            -FunctionUrl 'https://autopilot.example' `
            -ConfigPath $settingsPath

        $configuration.SubscriptionId | Should -Be `
            '11111111-1111-1111-1111-111111111111'
        $configuration.ResourceGroupName | Should -Be `
            'rg-autopilot-import'
        $configuration.FunctionAppName | Should -Be `
            'func-autopilot-import'
    }

    It 'rejects a runtime import URL from a different origin' {
        Mock Invoke-RestMethod -ModuleName AutopilotImport.Client {
            [pscustomobject]@{
                clientId = '44444444-4444-4444-4444-444444444444'
                authority = 'https://login.microsoftonline.com/22222222-2222-2222-2222-222222222222'
                scope = 'api://33333333-3333-3333-3333-333333333333/DeviceHash.Import'
                importUrl = 'https://attacker.example/api/devices/import'
            }
        }

        {
            Get-AutoPilotImporterClientConfiguration `
                -FunctionUrl 'https://func-example.azurewebsites.net' `
                -ConfigPath (Join-Path $TestDrive 'rejected.settings.json')
        } | Should -Throw '*import URL from a different origin*'
    }

    It 'returns all deployment and endpoint values from the selected file' {
        $settingsPath = Join-Path $TestDrive 'client.settings.json'
        [ordered]@{
            functionUrl = 'https://func-example.azurewebsites.net/api/devices/import'
            managementUrl = 'https://func-example.azurewebsites.net/api/management/tag-policy'
            apiApplicationIdUri = 'api://33333333-3333-3333-3333-333333333333'
            tenantId = '22222222-2222-2222-2222-222222222222'
            subscriptionId = '11111111-1111-1111-1111-111111111111'
            resourceGroupName = 'rg-autopilot-import'
            functionAppName = 'func-example'
            webUrl = 'https://func-example.azurewebsites.net/api/ui/index.html'
            webClientId = '44444444-4444-4444-4444-444444444444'
            functionVersion = '1.1.20260921.1'
        } | ConvertTo-Json | Set-Content -LiteralPath $settingsPath

        $configuration = Get-AutoPilotImporterClientConfiguration `
            -ConfigPath $settingsPath

        $configuration.SubscriptionId | Should -Be `
            '11111111-1111-1111-1111-111111111111'
        $configuration.TenantId | Should -Be `
            '22222222-2222-2222-2222-222222222222'
        $configuration.ResourceGroupName | Should -Be 'rg-autopilot-import'
        $configuration.FunctionAppName | Should -Be 'func-example'
        $configuration.FunctionUrl | Should -Be `
            'https://func-example.azurewebsites.net/api/devices/import'
        $configuration.ManagementUrl | Should -Be `
            'https://func-example.azurewebsites.net/api/management/tag-policy'
        $configuration.ApiApplicationIdUri | Should -Be `
            'api://33333333-3333-3333-3333-333333333333'
        $configuration.WebUrl | Should -Be `
            'https://func-example.azurewebsites.net/api/ui/index.html'
        $configuration.WebClientId | Should -Be `
            '44444444-4444-4444-4444-444444444444'
        $configuration.FunctionVersion | Should -Be '1.1.20260921.1'
        $configuration.ConfigPath | Should -Be `
            ([IO.Path]::GetFullPath($settingsPath))
    }

    It 'explains when the selected configuration file is missing' {
        $settingsPath = Join-Path $TestDrive 'missing.settings.json'

        {
            Get-AutoPilotImporterClientConfiguration -ConfigPath $settingsPath
        } | Should -Throw "Client configuration '$settingsPath' was not found*"
    }

    It 'explains which required value is missing' {
        $settingsPath = Join-Path $TestDrive 'incomplete.settings.json'
        @{ tenantId = '22222222-2222-2222-2222-222222222222' } |
            ConvertTo-Json |
            Set-Content -LiteralPath $settingsPath

        {
            Get-AutoPilotImporterClientConfiguration -ConfigPath $settingsPath
        } | Should -Throw 'Function URL is missing*'
    }
}

Describe 'Client manager policy App Settings' {
    BeforeAll {
        $clientModulePath = Join-Path $PSScriptRoot `
            '..\AutopilotImport.Client\AutopilotImport.Client.psm1'
        Import-Module $clientModulePath -Force
        $tokens = $null
        $parseErrors = $null
        $clientModuleAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $clientModulePath,
            [ref] $tokens,
            [ref] $parseErrors
        )
        $managerFunctionAst = $clientModuleAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Update-AutoPilotTagPolicyManager'
        }, $true) | Select-Object -First 1
        $resolvedClientModulePath = (Resolve-Path $clientModulePath).Path
        $clientModule = Get-Module AutopilotImport.Client |
            Where-Object Path -eq $resolvedClientModulePath |
            Select-Object -First 1
    }

    It 'passes manager policy JSON to Az.Websites as a string value' {
        $managerFunctionAst.Extent.Text | Should -Match `
            '(?s)\$appSettings\[''MANAGER_AUTHORIZATION_POLICY''\]\s*=.*?\[string\]\s+\$updatedPolicyJson'
        $managerFunctionAst.Extent.Text | Should -Not -Match `
            '\$appSettings\.MANAGER_AUTHORIZATION_POLICY\s*='
    }

    It 'discovers Azure details missing after URL bootstrap' {
        $settingsPath = Join-Path $TestDrive 'client.settings.json'
        @{
            functionUrl = 'https://autopilot.example/api/devices/import'
            tenantId = '22222222-2222-2222-2222-222222222222'
        } | ConvertTo-Json | Set-Content -LiteralPath $settingsPath
        Mock Assert-ClientCommand -ModuleName AutopilotImport.Client
        Mock Resolve-ClientFunctionAppFromUrl `
            -ModuleName AutopilotImport.Client {
            [pscustomobject]@{
                SubscriptionId = '33333333-3333-3333-3333-333333333333'
                ResourceGroupName = 'rg-autopilot-import'
                FunctionAppName = 'func-autopilot-import'
            }
        }
        Mock Save-ClientDeploymentConfiguration `
            -ModuleName AutopilotImport.Client
        Mock Get-ClientAccessToken -ModuleName AutopilotImport.Client {
            ConvertTo-SecureString 'token' -AsPlainText -Force
        }
        Mock Set-AzContext -ModuleName AutopilotImport.Client
        Mock Get-AzWebApp -ModuleName AutopilotImport.Client {
            [pscustomobject]@{
                Id = '/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg-autopilot-import/providers/Microsoft.Web/sites/func-autopilot-import'
                SiteConfig = [pscustomobject]@{
                    AppSettings = @(
                        [pscustomobject]@{
                            Name = 'MANAGER_AUTHORIZATION_POLICY'
                            Value = '{"installerPrincipalId":"44444444-4444-4444-4444-444444444444","additionalPrincipalIds":[],"allowIntuneRoleAdministrators":true}'
                        }
                    )
                }
            }
        }
        Mock Get-AzAccessToken -ModuleName AutopilotImport.Client {
            [pscustomobject]@{
                Token = ConvertTo-SecureString `
                    'eyJhbGciOiJub25lIn0.eyJvaWQiOiI1NTU1NTU1NS01NTU1LTU1NTUtNTU1NS01NTU1NTU1NTU1NTUifQ.' `
                    -AsPlainText -Force
            }
        }
        Mock Get-AzRoleAssignment -ModuleName AutopilotImport.Client {
            [pscustomobject]@{
                RoleDefinitionName = 'Owner'
                Scope = '/subscriptions/33333333-3333-3333-3333-333333333333'
            }
        }
        Mock Import-Module -ModuleName AutopilotImport.Client
        Mock Get-CoreModulePath -ModuleName AutopilotImport.Client {
            'AutopilotImport.psm1'
        }
        Mock Test-TagManagerPolicyAdministratorRole `
            -ModuleName AutopilotImport.Client { $true }
        Mock Set-AzWebApp -ModuleName AutopilotImport.Client

        $result = Update-AutoPilotTagPolicyManager `
            -AddPrincipalId '11111111-1111-1111-1111-111111111111' `
            -ConfigPath $settingsPath `
            -Confirm:$false

        $result.FunctionAppName | Should -Be 'func-autopilot-import'
        Should -Invoke Resolve-ClientFunctionAppFromUrl `
            -ModuleName AutopilotImport.Client `
            -Times 1 `
            -ParameterFilter {
                $FunctionUrl -eq `
                    'https://autopilot.example/api/devices/import' -and
                $TenantId -eq `
                    '22222222-2222-2222-2222-222222222222'
            }
        Should -Invoke Save-ClientDeploymentConfiguration `
            -ModuleName AutopilotImport.Client `
            -Times 1
    }

    It 'resolves a Function App by its custom hostname' {
        $azureContext = `
            [Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext]::new()
        Mock Assert-ClientCommand -ModuleName AutopilotImport.Client
        Mock Get-ClientAccessToken -ModuleName AutopilotImport.Client {
            ConvertTo-SecureString 'token' -AsPlainText -Force
        }
        Mock Get-AzContext -ModuleName AutopilotImport.Client {
            $azureContext
        }
        Mock Get-AzSubscription -ModuleName AutopilotImport.Client {
            [pscustomobject]@{
                Id = '33333333-3333-3333-3333-333333333333'
                TenantId = '22222222-2222-2222-2222-222222222222'
            }
        }
        Mock Set-AzContext -ModuleName AutopilotImport.Client {
            $azureContext
        }
        Mock Get-AzWebApp -ModuleName AutopilotImport.Client {
            @(
                [pscustomobject]@{
                    Kind = 'app'
                    Name = 'unrelated-web-app'
                    ResourceGroup = 'rg-web'
                    HostNames = @('autopilot.example')
                    DefaultHostName = 'unrelated.azurewebsites.net'
                }
                [pscustomobject]@{
                    Kind = 'functionapp'
                    Name = 'func-autopilot-import'
                    ResourceGroup = 'rg-autopilot-import'
                    HostNames = @(
                        'func-autopilot-import.azurewebsites.net'
                        'autopilot.example'
                    )
                    DefaultHostName = `
                        'func-autopilot-import.azurewebsites.net'
                }
            )
        }

        $deployment = & $clientModule {
            Resolve-ClientFunctionAppFromUrl `
                -FunctionUrl `
                    'https://autopilot.example/api/devices/import' `
                -TenantId '22222222-2222-2222-2222-222222222222'
        }

        $deployment.SubscriptionId | Should -Be `
            '33333333-3333-3333-3333-333333333333'
        $deployment.ResourceGroupName | Should -Be `
            'rg-autopilot-import'
        $deployment.FunctionAppName | Should -Be `
            'func-autopilot-import'
        Should -Invoke Set-AzContext `
            -ModuleName AutopilotImport.Client `
            -Times 1 `
            -ParameterFilter { $Context -eq $azureContext }
    }

    It 'persists discovered Azure deployment details in the client profile' {
        $settingsPath = Join-Path $TestDrive 'persisted.settings.json'
        @{
            functionUrl = 'https://autopilot.example/api/devices/import'
            tenantId = '22222222-2222-2222-2222-222222222222'
        } | ConvertTo-Json | Set-Content -LiteralPath $settingsPath

        & $clientModule {
            param($Path)
            Save-ClientDeploymentConfiguration `
                -Configuration @{
                    ConfigPath = $Path
                } `
                -Deployment ([pscustomobject]@{
                    SubscriptionId = `
                        '33333333-3333-3333-3333-333333333333'
                    ResourceGroupName = 'rg-autopilot-import'
                    FunctionAppName = 'func-autopilot-import'
                })
        } $settingsPath

        $settings = Get-Content -LiteralPath $settingsPath -Raw |
            ConvertFrom-Json
        $settings.subscriptionId | Should -Be `
            '33333333-3333-3333-3333-333333333333'
        $settings.resourceGroupName | Should -Be 'rg-autopilot-import'
        $settings.functionAppName | Should -Be 'func-autopilot-import'
        $settings.functionUrl | Should -Be `
            'https://autopilot.example/api/devices/import'
    }

    It 'returns the installer and additional tag policy managers' {
        $settingsPath = Join-Path $TestDrive 'manager.settings.json'
        @{
            subscriptionId = '33333333-3333-3333-3333-333333333333'
            tenantId = '22222222-2222-2222-2222-222222222222'
            resourceGroupName = 'rg-autopilot-import'
            functionAppName = 'func-autopilot-import'
        } | ConvertTo-Json | Set-Content -LiteralPath $settingsPath
        Mock Assert-ClientCommand -ModuleName AutopilotImport.Client
        Mock Get-ClientAccessToken -ModuleName AutopilotImport.Client {
            ConvertTo-SecureString 'token' -AsPlainText -Force
        }
        Mock Set-AzContext -ModuleName AutopilotImport.Client
        Mock Get-AzWebApp -ModuleName AutopilotImport.Client {
            [pscustomobject]@{
                SiteConfig = [pscustomobject]@{
                    AppSettings = @(
                        [pscustomobject]@{
                            Name = 'MANAGER_AUTHORIZATION_POLICY'
                            Value = '{"installerPrincipalId":"44444444-4444-4444-4444-444444444444","additionalPrincipalIds":["55555555-5555-5555-5555-555555555555"],"allowIntuneRoleAdministrators":true}'
                        }
                    )
                }
            }
        }

        $result = @(Get-AutoPilotTagPolicyManager `
            -ConfigPath $settingsPath)

        $result.Count | Should -Be 2
        $result[0].PrincipalId | Should -Be `
            '44444444-4444-4444-4444-444444444444'
        $result[0].ManagerType | Should -Be 'Installer'
        $result[1].PrincipalId | Should -Be `
            '55555555-5555-5555-5555-555555555555'
        $result[1].ManagerType | Should -Be 'Additional'
        $result[0].PSObject.TypeNames[0] | Should -Be `
            'AutopilotImport.TagPolicyManager'
    }
}

Describe 'Client import status metadata' {
    BeforeAll {
        $clientModulePath = Join-Path $PSScriptRoot `
            '..\AutopilotImport.Client\AutopilotImport.Client.psd1'
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

Describe 'Client import history' {
    BeforeAll {
        $clientModulePath = Join-Path $PSScriptRoot `
            '..\AutopilotImport.Client\AutopilotImport.Client.psd1'
        Import-Module $clientModulePath -Force
    }

    BeforeEach {
        Mock Get-ClientAccessToken -ModuleName AutopilotImport.Client {
            ConvertTo-SecureString 'token' -AsPlainText -Force
        }
        Mock Invoke-RestMethod -ModuleName AutopilotImport.Client {
            [pscustomobject]@{
                imports = @(
                    [pscustomobject]@{
                        importId     = '11111111-1111-1111-1111-111111111111'
                        serialNumber = 'SERIAL-001'
                        groupTag     = 'Standard'
                        status       = 'complete'
                        requestedBy  = 'ada@example.com'
                        requestedByObjectId = `
                            'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                        requestedByUserPrincipalName = 'ada@example.com'
                        requestedByDisplayName = 'Ada Lovelace'
                        requestReceivedAtUtc = '2026-09-18T10:00:00.0000000Z'
                        graphImportCreatedAtUtc = '2026-09-18T10:00:01.0000000Z'
                        queuedAtUtc = '2026-09-18T10:00:02.0000000Z'
                        processingStartedAtUtc = '2026-09-18T10:01:00.0000000Z'
                        entraDeviceResolvedAtUtc = '2026-09-18T10:02:00.0000000Z'
                        extensionAttributeUpdatedAtUtc = '2026-09-18T10:02:01.0000000Z'
                        administrativeUnitAssignedAtUtc = '2026-09-18T10:02:02.0000000Z'
                        processingCompletedAtUtc = '2026-09-18T10:02:03.0000000Z'
                    }
                    [pscustomobject]@{
                        importId     = '22222222-2222-2222-2222-222222222222'
                        serialNumber = 'SERIAL-002'
                        groupTag     = 'Kiosk'
                        status       = 'error'
                    }
                )
                count = 2
                correlationId = '33333333-3333-3333-3333-333333333333'
            }
        }
    }

    It 'returns manager-visible import operations as pipeline objects' {
        $result = @(Get-AutoPilotImportHistory `
            -Top 250 `
            -ImportHistoryUrl 'https://func.example/api/management/imports' `
            -ApiApplicationIdUri `
                'api://44444444-4444-4444-4444-444444444444' `
            -TenantId '55555555-5555-5555-5555-555555555555')

        $result.Count | Should -Be 2
        $result[0].serialNumber | Should -Be 'SERIAL-001'
        $result[0].ImportId | Should -Be `
            '11111111-1111-1111-1111-111111111111'
        $result[1].status | Should -Be 'error'
        $result[0].RequestedBy | Should -Be 'ada@example.com'
        $result[0].RequestedByDisplayName | Should -Be 'Ada Lovelace'
        $result[0].RequestReceivedAtUtc | Should -BeOfType [datetimeoffset]
        $result[0].ProcessingCompletedAtUtc.ToString('o') |
            Should -Be '2026-09-18T10:02:03.0000000+00:00'
        $result[1].RequestReceivedAtUtc | Should -BeNullOrEmpty
        $result[0].PSTypeNames | Should -Contain `
            'AutopilotImport.ImportHistoryRecord'
        $result[0].PSStandardMembers.DefaultDisplayPropertySet.ReferencedPropertyNames |
            Should -Be @(
                'ImportId'
                'SerialNumber'
                'GroupTag'
                'Status'
                'RequestedBy'
                'RequestReceivedAtUtc'
                'ProcessingCompletedAtUtc'
                'DeviceErrorName'
            )
        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport.Client `
            -Times 1 `
            -ParameterFilter {
                $Method -eq 'Get' -and
                $Uri -eq `
                    'https://func.example/api/management/imports?top=250'
            }
    }

    It 'requests all retained records only when ShowAll is specified' {
        Get-AutoPilotImportHistory `
            -ShowAll `
            -ImportHistoryUrl 'https://func.example/api/management/imports' `
            -ApiApplicationIdUri `
                'api://44444444-4444-4444-4444-444444444444' `
            -TenantId '55555555-5555-5555-5555-555555555555' |
            Out-Null

        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport.Client `
            -Times 1 `
            -ParameterFilter {
                $Method -eq 'Get' -and
                $Uri -eq `
                    'https://func.example/api/management/imports?top=100&showAll=true'
            }
    }

    It 'posts multiple import IDs as an explicit history filter' {
        Get-AutoPilotImportHistory `
            -ImportId @(
                '11111111-1111-1111-1111-111111111111'
                '22222222-2222-2222-2222-222222222222'
            ) `
            -ImportHistoryUrl 'https://func.example/api/management/imports' `
            -ApiApplicationIdUri `
                'api://44444444-4444-4444-4444-444444444444' `
            -TenantId '55555555-5555-5555-5555-555555555555' |
            Out-Null

        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport.Client `
            -Times 1 `
            -ParameterFilter {
                $payload = $Body | ConvertFrom-Json
                $Method -eq 'Post' -and
                @($payload.importIds).Count -eq 2 -and
                @($payload.serialNumbers).Count -eq 0 -and
                @($payload.deviceHashSha256).Count -eq 0
            }
    }

    It 'posts serial numbers as an explicit history filter' {
        Get-AutoPilotImportHistory `
            '7892-5288-2670-2860-4823-9507-73' `
            -ImportHistoryUrl 'https://func.example/api/management/imports' `
            -ApiApplicationIdUri `
                'api://44444444-4444-4444-4444-444444444444' `
            -TenantId '55555555-5555-5555-5555-555555555555' |
            Out-Null

        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport.Client `
            -Times 1 `
            -ParameterFilter {
                $payload = $Body | ConvertFrom-Json
                $Method -eq 'Post' -and
                $payload.serialNumbers -eq `
                    '7892-5288-2670-2860-4823-9507-73'
            }
    }

    It 'posts users as an explicit history filter' {
        Get-AutoPilotImportHistory `
            -User 'aa@bloedgelaber.de' `
            -ImportHistoryUrl 'https://func.example/api/management/imports' `
            -ApiApplicationIdUri `
                'api://44444444-4444-4444-4444-444444444444' `
            -TenantId '55555555-5555-5555-5555-555555555555' |
            Out-Null

        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport.Client `
            -Times 1 `
            -ParameterFilter {
                $payload = $Body | ConvertFrom-Json
                $Method -eq 'Post' -and
                $payload.users -eq 'aa@bloedgelaber.de'
            }
    }

    It 'posts only a SHA-256 index for a DeviceHash filter' {
        $deviceHash = [Convert]::ToBase64String([byte[]](1, 2, 3, 4))

        Get-AutoPilotImportHistory `
            -DeviceHash $deviceHash `
            -ImportHistoryUrl 'https://func.example/api/management/imports' `
            -ApiApplicationIdUri `
                'api://44444444-4444-4444-4444-444444444444' `
            -TenantId '55555555-5555-5555-5555-555555555555' |
            Out-Null

        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport.Client `
            -Times 1 `
            -ParameterFilter {
                $payload = $Body | ConvertFrom-Json
                $Method -eq 'Post' -and
                $Body -notlike "*$deviceHash*" -and
                $payload.deviceHashSha256 -eq `
                    '9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a'
            }
    }

    It 'derives the history endpoint from an existing client configuration' {
        $configPath = Join-Path $TestDrive 'client.settings.json'
        @{
            managementUrl = `
                'https://func.example/api/management/tag-policy'
            apiApplicationIdUri = `
                'api://44444444-4444-4444-4444-444444444444'
            tenantId = '55555555-5555-5555-5555-555555555555'
        } | ConvertTo-Json | Set-Content -LiteralPath $configPath

        Get-AutoPilotImportHistory -ConfigPath $configPath | Out-Null

        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport.Client `
            -ParameterFilter {
                $Uri -eq `
                    'https://func.example/api/management/imports?top=100'
            }
    }

    It 'returns the response envelope when Raw is specified' {
        $result = Get-AutoPilotImportHistory `
            -ImportHistoryUrl 'https://func.example/api/management/imports' `
            -ApiApplicationIdUri `
                'api://44444444-4444-4444-4444-444444444444' `
            -TenantId '55555555-5555-5555-5555-555555555555' `
            -Raw

        $result.count | Should -Be 2
        $result.correlationId | Should -Be `
            '33333333-3333-3333-3333-333333333333'
    }

    It 'reports how to authenticate when token acquisition fails' {
        Mock Get-ClientAccessToken -ModuleName AutopilotImport.Client {
            throw [InvalidOperationException]::new(
                'No active Azure account was found.')
        }

        {
            Get-AutoPilotImportHistory `
                -ImportHistoryUrl `
                    'https://func.example/api/management/imports' `
                -ApiApplicationIdUri `
                    'api://44444444-4444-4444-4444-444444444444' `
                -TenantId '55555555-5555-5555-5555-555555555555'
        } | Should -Throw `
            '*Authentication for the Autopilot import history failed*Connect-AzAccount*'
    }

    It 'preserves the original message for an unclassified API failure' {
        Mock Invoke-RestMethod -ModuleName AutopilotImport.Client {
            throw [InvalidOperationException]::new('Connection was closed.')
        }

        {
            Get-AutoPilotImportHistory `
                -ImportHistoryUrl `
                    'https://func.example/api/management/imports' `
                -ApiApplicationIdUri `
                    'api://44444444-4444-4444-4444-444444444444' `
                -TenantId '55555555-5555-5555-5555-555555555555'
        } | Should -Throw `
            '*Could not retrieve the Autopilot import history*Connection was closed*'
    }

    It 'explains that a missing history endpoint requires a Function update' {
        Mock Invoke-RestMethod -ModuleName AutopilotImport.Client {
            $exception = [InvalidOperationException]::new(
                'Response status code does not indicate success: 404 (Not Found).')
            $exception.Data['StatusCode'] = 404
            throw $exception
        }

        {
            Get-AutoPilotImportHistory `
                -ImportHistoryUrl `
                    'https://func.example/api/management/imports' `
                -ApiApplicationIdUri `
                    'api://44444444-4444-4444-4444-444444444444' `
                -TenantId '55555555-5555-5555-5555-555555555555'
        } | Should -Throw `
            "*endpoint was not found at 'https://func.example/api/management/imports?top=100'*Run Update-AutopilotImport.ps1 without -SkipPublish*"
    }
}

Describe 'Import history endpoint' {
    BeforeAll {
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $historyFunction = Get-Content `
            -LiteralPath (Join-Path `
                $projectRoot `
                'src\FunctionApp\GetImportHistory\run.ps1') `
            -Raw
        $installer = Get-Content `
            -LiteralPath (Join-Path `
                $projectRoot `
                'src\Installer\Install-AutopilotImport.ps1') `
            -Raw
        $historyBinding = Get-Content `
            -LiteralPath (Join-Path `
                $projectRoot `
                'src\FunctionApp\GetImportHistory\function.json') `
            -Raw | ConvertFrom-Json
    }

    It 'includes the import history Function in the Azure publish archive' {
        $installer.Contains(
            "Join-Path `$functionAppRoot 'GetImportHistory'") |
            Should -BeTrue
        $installer.Contains(
            "Join-Path `$functionAppRoot 'RemoveExpiredImportHistory'") |
            Should -BeTrue
        @($historyBinding.bindings[0].methods) | Should -Contain 'post'
    }

    It 'defaults to the caller and reserves broad history access for importer managers' {
        $historyFunction | Should -Match 'ActorObjectId = \$actorObjectId'
        $historyFunction | Should -Match '\$showAll'
        $historyFunction | Should -Match `
            'if \(\$showAll -or \$requestedUsers\.Count -gt 0\)'
        $historyFunction | Should -Match 'Test-TagPolicyManagerPrincipal'
        $historyFunction | Should -Match 'allowIntuneRoleAdministrators'
        $historyFunction | Should -Match 'Test-IntuneRoleAdministrator'
        $historyFunction | Should -Match "'historyAccessForbidden'"
    }

    It 'validates the result limit and stops Graph pagination after matching audit records' {
        $historyFunction | Should -Match '\$parsedTop -lt 1'
        $historyFunction | Should -Match '\$parsedTop -gt 1000'
        $historyFunction | Should -Match "'@odata\.nextLink'"
        $historyFunction | Should -Match '\$remainingIds\.Count -gt 0'
        $historyFunction | Should -Match '\$remainingIds\.Remove'
    }

    It 'queries and returns operational fields without sensitive import payloads' {
        $historyFunction | Should -Match `
            '\?\$select=id,importId,serialNumber,groupTag,state&\$top=100'
        $historyFunction | Should -Match 'deviceImportStatus'
        $historyFunction | Should -Match 'deviceErrorCode'
        $historyFunction | Should -Match 'Get-ImportAuditHistory'
        $historyFunction | Should -Match 'Get-ImportAuditRetentionCutoffUtc'
        $historyFunction | Should -Match 'requestedByUserPrincipalName'
        $historyFunction | Should -Match 'extensionAttributeUpdatedAtUtc'
        $historyFunction | Should -Match 'processingCompletedAtUtc'
        $historyFunction | Should -Not -Match '\.hardwareIdentifier'
        $historyFunction | Should -Not -Match '\.productKey'
    }
}

Describe 'Import audit workflow integration' {
    BeforeAll {
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $importFunction = Get-Content -LiteralPath (Join-Path `
                $projectRoot 'src\FunctionApp\ImportDevice\run.ps1') -Raw
        $processorFunction = Get-Content -LiteralPath (Join-Path `
                $projectRoot 'src\FunctionApp\ProcessDeviceAttribute\run.ps1') -Raw
        $retentionFunction = Get-Content -LiteralPath (Join-Path `
            $projectRoot 'src\FunctionApp\RemoveExpiredImportHistory\run.ps1') -Raw
        $retentionBinding = Get-Content -LiteralPath (Join-Path `
            $projectRoot 'src\FunctionApp\RemoveExpiredImportHistory\function.json') `
            -Raw | ConvertFrom-Json
        $infrastructure = Get-Content -LiteralPath (Join-Path `
                $projectRoot 'src\Infrastructure\main.bicep') -Raw
    }

    It 'queues the authenticated actor and initial UTC milestones' {
        $importFunction | Should -Match 'actorUserPrincipalName'
        $importFunction | Should -Match 'actorDisplayName'
        $importFunction | Should -Match 'requestReceivedAtUtc'
        $importFunction | Should -Match 'graphImportCreatedAtUtc'
        $importFunction | Should -Match 'queuedAtUtc'
        $importFunction | Should -Match 'deviceHashSha256'
        $importFunction | Should -Match 'deviceHash\s*='
        $importFunction | Should -Match 'audit\s*=\s*\$auditProperties'
    }

    It 'records each successful post-processing milestone' {
        $processorFunction | Should -Match 'Get-ImportAuditRecords'
        $processorFunction | Should -Match `
            'existingAuditRecord\.processingStartedAtUtc'
        $processorFunction | Should -Match 'processingStartedAtUtc'
        $processorFunction | Should -Match 'entraDeviceResolvedAtUtc'
        $processorFunction | Should -Match 'extensionAttributeUpdatedAtUtc'
        $processorFunction | Should -Match 'administrativeUnitAssignedAtUtc'
        $processorFunction | Should -Match 'processingCompletedAtUtc'
    }

    It 'provisions the audit table and managed identity data role' {
        $infrastructure | Should -Match `
            "Microsoft\.Storage/storageAccounts/tableServices/tables@"
        $infrastructure | Should -Match "name:\s*'importaudit'"
        $infrastructure | Should -Match 'storageTableDataContributorRoleId'
        $infrastructure | Should -Match "name:\s*'IMPORT_AUDIT_TABLE_NAME'"
    }

    It 'removes audit records after the 30-day retention period' {
        $retentionFunction | Should -Match `
            'Get-ImportAuditRetentionCutoffUtc'
        $retentionFunction | Should -Match 'Remove-ExpiredImportAuditRecords'
        $retentionBinding.bindings[0].type | Should -Be 'timerTrigger'
        $retentionBinding.bindings[0].schedule | Should -Be '0 17 * * * *'
    }
}

Describe 'Client Group Tag policy display' {
    BeforeAll {
        $clientModulePath = Join-Path $PSScriptRoot `
            '..\AutopilotImport.Client\AutopilotImport.Client.psd1'
        Import-Module $clientModulePath -Force
    }

    BeforeEach {
        Mock Get-ClientAccessToken -ModuleName AutopilotImport.Client {
            ConvertTo-SecureString 'token' -AsPlainText -Force
        }
        Mock Invoke-RestMethod -ModuleName AutopilotImport.Client {
            if ($Uri -like 'https://graph.microsoft.com/*') {
                return [pscustomobject]@{
                    id          = '11111111-1111-1111-1111-111111111111'
                    displayName = 'Autopilot Import Operators'
                }
            }
            return [pscustomobject]@{
                policy = @([pscustomobject]@{
                    groupId = '11111111-1111-1111-1111-111111111111'
                    tags    = @('Standard', 'Kiosk')
                })
                functionVersion = '1.1.20260913.9'
                correlationId = '22222222-2222-2222-2222-222222222222'
            }
        }
    }

    It 'shows the Entra group name while preserving its object ID' {
        $result = @(Get-AutoPilotTagPolicy `
            -ManagementUrl 'https://func.example/api/management/tag-policy' `
            -ApiApplicationIdUri 'api://33333333-3333-3333-3333-333333333333' `
            -TenantId '44444444-4444-4444-4444-444444444444')

        $result.Count | Should -Be 1
        $result[0].GroupName | Should -Be 'Autopilot Import Operators'
        $result[0].GroupId | Should -Be `
            '11111111-1111-1111-1111-111111111111'
        $result[0].Tags | Should -Be @('Standard', 'Kiosk')
        $result[0].AdministrativeUnitName |
            Should -BeNullOrEmpty
        $result[0].CorrelationId | Should -Be `
            '22222222-2222-2222-2222-222222222222'
        $result[0].PSObject.TypeNames[0] | Should -Be `
            'AutopilotImport.TagPolicyRule'
        $result[0].PSStandardMembers.DefaultDisplayPropertySet.ReferencedPropertyNames |
            Should -Be @(
                'GroupId'
                'GroupName'
                'Tags'
                'AdministrativeUnitName'
            )
    }

    It 'returns the unchanged API response when Raw is specified' {
        $result = Get-AutoPilotTagPolicy `
            -ManagementUrl 'https://func.example/api/management/tag-policy' `
            -ApiApplicationIdUri 'api://33333333-3333-3333-3333-333333333333' `
            -TenantId '44444444-4444-4444-4444-444444444444' `
            -Raw

        $result.policy[0].groupId | Should -Be `
            '11111111-1111-1111-1111-111111111111'
        $result.functionVersion | Should -Be '1.1.20260913.9'
        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport.Client `
            -ParameterFilter { $Uri -like 'https://graph.microsoft.com/*' } `
            -Times 0
    }
}

Describe 'Adding a Client Group Tag policy rule' {
    BeforeAll {
        $clientModulePath = Join-Path $PSScriptRoot `
            '..\AutopilotImport.Client\AutopilotImport.Client.psd1'
        Import-Module $clientModulePath -Force
    }

    BeforeEach {
        Mock Get-ClientAccessToken -ModuleName AutopilotImport.Client {
            ConvertTo-SecureString 'token' -AsPlainText -Force
        }
        Mock Invoke-RestMethod -ModuleName AutopilotImport.Client {
            if ($Method -eq 'Get') {
                return [pscustomobject]@{
                    policy = @([pscustomobject]@{
                        groupId = '11111111-1111-1111-1111-111111111111'
                        tags = @('Standard')
                        administrativeUnitName = `
                            'Autopilot Devices'
                    })
                }
            }
            return [pscustomobject]@{
                correlationId = '55555555-5555-5555-5555-555555555555'
            }
        }
    }

    It 'returns the added rule without requiring confirmation' {
        $result = Add-AutoPilotTagPolicy `
            -GroupId '22222222-2222-2222-2222-222222222222' `
            -GroupTag 'Kiosk' `
            -Mau 'Kiosk Devices' `
            -ManagementUrl 'https://func.example/api/management/tag-policy' `
            -ApiApplicationIdUri 'api://33333333-3333-3333-3333-333333333333' `
            -TenantId '44444444-4444-4444-4444-444444444444'

        $result.GroupId | Should -Be `
            '22222222-2222-2222-2222-222222222222'
        $result.GroupName | Should -BeNullOrEmpty
        $result.Tags | Should -Be @('Kiosk')
        $result.AdministrativeUnitName |
            Should -Be 'Kiosk Devices'
        $result.CorrelationId | Should -Be `
            '55555555-5555-5555-5555-555555555555'
        $result.PSObject.TypeNames[0] | Should -Be `
            'AutopilotImport.TagPolicyRule'
        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport.Client `
            -ParameterFilter {
                $Method -eq 'Put' -and
                $Body -match '11111111-1111-1111-1111-111111111111' -and
                $Body -match '22222222-2222-2222-2222-222222222222' -and
                $Body -match 'Standard' -and
                $Body -match 'Kiosk' -and
                $Body -match 'Autopilot Devices' -and
                $Body -match 'Kiosk Devices'
            } `
            -Times 1
            Should -Invoke Get-ClientAccessToken `
                -ModuleName AutopilotImport.Client `
                -Times 1
    }

    It 'supports WhatIf without requesting confirmation by default' {
        foreach ($commandName in @(
                'New-AutoPilotImporterClientConfiguration'
                'Import-AutoPilotDevice'
                'Add-AutoPilotTagPolicy'
                'Remove-AutoPilotTagPolicy'
                'Set-AutoPilotTagPolicy'
                'Update-AutoPilotTagPolicyManager'
                'Add-AutoPilotTagPolicyManager'
                'Remove-AutoPilotTagPolicyManager'
            )) {
            $command = Get-Command $commandName
            $binding = @($command.ScriptBlock.Attributes | Where-Object {
                $_ -is [Management.Automation.CmdletBindingAttribute]
            })[0]

            $command.Parameters.ContainsKey('WhatIf') |
                Should -BeTrue -Because "$commandName changes state"
            $binding.ConfirmImpact |
                Should -Be 'None' -Because "$commandName should not prompt automatically"
        }
    }

    It 'accepts comma-separated tags as separate values' {
        Add-AutoPilotTagPolicy `
            '22222222-2222-2222-2222-222222222222' `
            -Tag 'BG-Default, PAW, PAW-CSM' `
            -ManagementUrl 'https://func.example/api/management/tag-policy' `
            -ApiApplicationIdUri 'api://33333333-3333-3333-3333-333333333333' `
            -TenantId '44444444-4444-4444-4444-444444444444' |
            Out-Null

        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport.Client `
            -ParameterFilter {
                if ($Method -ne 'Put') {
                    return $false
                }
                $newRule = @(($Body | ConvertFrom-Json).policy |
                    Where-Object groupId -eq `
                        '22222222-2222-2222-2222-222222222222')[0]
                @($newRule.tags).Count -eq 3 -and
                    'BG-Default' -in $newRule.tags -and
                    'PAW' -in $newRule.tags -and
                    'PAW-CSM' -in $newRule.tags
            } `
            -Times 1
    }

    It 'accepts an object ID, merges tags, and sets the specified MAU' {
        Add-AutoPilotTagPolicy `
            -GroupId '11111111-1111-1111-1111-111111111111' `
            -GroupTag @('Standard', 'Shared') `
            -Mau 'Privileged Autopilot Devices' `
            -ManagementUrl 'https://func.example/api/management/tag-policy' `
            -ApiApplicationIdUri 'api://33333333-3333-3333-3333-333333333333' `
            -TenantId '44444444-4444-4444-4444-444444444444' `
            -Confirm:$false | Out-Null

        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport.Client `
            -ParameterFilter {
                $Method -eq 'Put' -and
                $Body -match '11111111-1111-1111-1111-111111111111' -and
                $Body -match 'Standard' -and
                $Body -match 'Shared' -and
                $Body -match 'Privileged Autopilot Devices'
            } `
            -Times 1
    }

    It 'assigns an RMAU only to the selected rule' {
        Mock Invoke-RestMethod -ModuleName AutopilotImport.Client {
            if ($Method -eq 'Get') {
                return [pscustomobject]@{
                    policy = @(
                        [pscustomobject]@{
                            groupId = '11111111-1111-1111-1111-111111111111'
                            tags = @('BG-Default', 'PAW')
                        }
                        [pscustomobject]@{
                            groupId = '22222222-2222-2222-2222-222222222222'
                            tags = @('BG-Default')
                        }
                    )
                }
            }
            return [pscustomobject]@{ correlationId = 'correlation-id' }
        }

        Add-AutoPilotTagPolicy `
            '33333333-3333-3333-3333-333333333333' `
            'BG-Default' `
            'BG-Devices' `
            -ManagementUrl 'https://func.example/api/management/tag-policy' `
            -ApiApplicationIdUri 'api://44444444-4444-4444-4444-444444444444' `
            -TenantId '55555555-5555-5555-5555-555555555555' |
            Out-Null

        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport.Client `
            -ParameterFilter {
                if ($Method -ne 'Put') {
                    return $false
                }
                $submittedPolicy = @(($Body | ConvertFrom-Json).policy)
                $rulesWithMau = @($submittedPolicy | Where-Object {
                    $_.PSObject.Properties[
                        'administrativeUnitName']
                })
                $rulesWithMau.Count -eq 1 -and
                    $rulesWithMau[0].groupId -eq `
                        '33333333-3333-3333-3333-333333333333' -and
                    $rulesWithMau[0].administrativeUnitName -eq `
                        'BG-Devices'
            } `
            -Times 1
    }

    It 'retains Group as an alias and does not update with WhatIf' {
        Add-AutoPilotTagPolicy `
            -Group '11111111-1111-1111-1111-111111111111' `
            -GroupTag 'Shared' `
            -ManagementUrl 'https://func.example/api/management/tag-policy' `
            -ApiApplicationIdUri 'api://33333333-3333-3333-3333-333333333333' `
            -TenantId '44444444-4444-4444-4444-444444444444' `
            -WhatIf

        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport.Client `
            -ParameterFilter { $Method -eq 'Put' } `
            -Times 0
    }

    It 'supports an existing policy without an MAU' {
        Mock Invoke-RestMethod -ModuleName AutopilotImport.Client {
            if ($Method -eq 'Get') {
                return [pscustomobject]@{
                    policy = @([pscustomobject]@{
                        groupId = '11111111-1111-1111-1111-111111111111'
                        tags = @('Standard')
                    })
                }
            }
            return [pscustomobject]@{ updated = $true }
        }

        {
            Add-AutoPilotTagPolicy `
                -GroupId '11111111-1111-1111-1111-111111111111' `
                -GroupTag 'Shared' `
                -ManagementUrl 'https://func.example/api/management/tag-policy' `
                -ApiApplicationIdUri 'api://33333333-3333-3333-3333-333333333333' `
                -TenantId '44444444-4444-4444-4444-444444444444' `
                -Confirm:$false
        } | Should -Not -Throw

        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport.Client `
            -ParameterFilter {
                $Method -eq 'Put' -and
                $Body -notmatch 'administrativeUnitName'
            } `
            -Times 1
    }

    It 'removes the RMAU only from the selected rule when Mau is empty' {
        Add-AutoPilotTagPolicy `
            -GroupId '11111111-1111-1111-1111-111111111111' `
            -GroupTag 'Shared' `
            -Mau '' `
            -ManagementUrl 'https://func.example/api/management/tag-policy' `
            -ApiApplicationIdUri 'api://33333333-3333-3333-3333-333333333333' `
            -TenantId '44444444-4444-4444-4444-444444444444' `
            -Confirm:$false | Out-Null

        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport.Client `
            -ParameterFilter {
                $Method -eq 'Put' -and
                $Body -notmatch 'administrativeUnitName'
            } `
            -Times 1
    }
}

Describe 'Removing a Client Group Tag policy rule' {
    BeforeAll {
        $clientModulePath = Join-Path $PSScriptRoot `
            '..\AutopilotImport.Client\AutopilotImport.Client.psd1'
        Import-Module $clientModulePath -Force
    }

    BeforeEach {
        Mock Get-ClientAccessToken -ModuleName AutopilotImport.Client {
            ConvertTo-SecureString 'token' -AsPlainText -Force
        }
        Mock Invoke-RestMethod -ModuleName AutopilotImport.Client {
            if ($Uri -like 'https://graph.microsoft.com/*') {
                return [pscustomobject]@{
                    value = @([pscustomobject]@{
                        id          = '22222222-2222-2222-2222-222222222222'
                        displayName = 'Obsolete Autopilot Group'
                    })
                }
            }
            if ($Method -eq 'Get') {
                return [pscustomobject]@{
                    policy = @(
                        [pscustomobject]@{
                            groupId = '11111111-1111-1111-1111-111111111111'
                            tags = @('Standard')
                            administrativeUnitName = `
                                'Autopilot Devices'
                        }
                        [pscustomobject]@{
                            groupId = '22222222-2222-2222-2222-222222222222'
                            tags = @('Legacy')
                            administrativeUnitName = `
                                'Autopilot Devices'
                        }
                    )
                }
            }
            return [pscustomobject]@{ updated = $true }
        }
    }

    It 'resolves a group name and removes only its policy rule' {
        $result = Remove-AutoPilotTagPolicy `
            -Group 'Obsolete Autopilot Group' `
            -ManagementUrl 'https://func.example/api/management/tag-policy' `
            -ApiApplicationIdUri 'api://33333333-3333-3333-3333-333333333333' `
            -TenantId '44444444-4444-4444-4444-444444444444' `
            -Confirm:$false

        $result.updated | Should -BeTrue
        [string] $result | Should -Be `
            "The tag policy for group 'Obsolete Autopilot Group' was removed."
        ($result | Out-String).Trim() | Should -Be `
            "The tag policy for group 'Obsolete Autopilot Group' was removed."
        $result.GroupId | Should -Be `
            '22222222-2222-2222-2222-222222222222'
        $result.GroupName | Should -Be 'Obsolete Autopilot Group'
        $result.RuleRemoved | Should -BeTrue
        $result.RemovedTags | Should -BeNullOrEmpty
        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport.Client `
            -ParameterFilter {
                $Method -eq 'Put' -and
                $Body -match '11111111-1111-1111-1111-111111111111' -and
                $Body -match 'Standard' -and
                $Body -notmatch '22222222-2222-2222-2222-222222222222' -and
                $Body -match 'Autopilot Devices'
            } `
            -Times 1
    }

    It 'accepts a group object ID without a Graph lookup' {
        Remove-AutoPilotTagPolicy `
            -Group '22222222-2222-2222-2222-222222222222' `
            -ManagementUrl 'https://func.example/api/management/tag-policy' `
            -ApiApplicationIdUri 'api://33333333-3333-3333-3333-333333333333' `
            -TenantId '44444444-4444-4444-4444-444444444444' `
            -Confirm:$false | Out-Null

        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport.Client `
            -ParameterFilter { $Uri -like 'https://graph.microsoft.com/*' } `
            -Times 0
    }

    It 'removes only the selected tag from an existing group rule' {
        Mock Invoke-RestMethod -ModuleName AutopilotImport.Client {
            if ($Method -eq 'Get') {
                return [pscustomobject]@{
                    policy = @(
                        [pscustomobject]@{
                            groupId = '11111111-1111-1111-1111-111111111111'
                            tags = @('Standard', 'Kiosk', 'Shared')
                            administrativeUnitName = `
                                'Autopilot Devices'
                        }
                        [pscustomobject]@{
                            groupId = '22222222-2222-2222-2222-222222222222'
                            tags = @('Legacy')
                            administrativeUnitName = `
                                'Autopilot Devices'
                        }
                    )
                }
            }
            return [pscustomobject]@{ updated = $true }
        }

        $result = Remove-AutoPilotTagPolicy `
            -Group '11111111-1111-1111-1111-111111111111' `
            -GroupTag 'Kiosk' `
            -ManagementUrl 'https://func.example/api/management/tag-policy' `
            -ApiApplicationIdUri 'api://33333333-3333-3333-3333-333333333333' `
            -TenantId '44444444-4444-4444-4444-444444444444' `
            -Confirm:$false

        $result.updated | Should -BeTrue
        [string] $result | Should -Be `
            "Group Tag 'Kiosk' was removed from the tag policy for group '11111111-1111-1111-1111-111111111111'."
        $result.GroupId | Should -Be `
            '11111111-1111-1111-1111-111111111111'
        $result.RuleRemoved | Should -BeFalse
        $result.RemovedTags | Should -Be 'Kiosk'
        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport.Client `
            -ParameterFilter {
                $Method -eq 'Put' -and
                $Body -match '11111111-1111-1111-1111-111111111111' -and
                $Body -match 'Standard' -and
                $Body -match 'Shared' -and
                $Body -notmatch 'Kiosk' -and
                $Body -match '22222222-2222-2222-2222-222222222222' -and
                $Body -match 'Legacy' -and
                $Body -match 'Autopilot Devices'
            } `
            -Times 1
    }

    It 'accepts comma-separated tags when removing selected values' {
        Mock Invoke-RestMethod -ModuleName AutopilotImport.Client {
            if ($Method -eq 'Get') {
                return [pscustomobject]@{
                    policy = @(
                        [pscustomobject]@{
                            groupId = '11111111-1111-1111-1111-111111111111'
                            tags = @('BG-Default', 'PAW', 'PAW-CSM', 'Shared')
                        }
                        [pscustomobject]@{
                            groupId = '22222222-2222-2222-2222-222222222222'
                            tags = @('Legacy')
                        }
                    )
                }
            }
            return [pscustomobject]@{ updated = $true }
        }

        Remove-AutoPilotTagPolicy `
            -Group '11111111-1111-1111-1111-111111111111' `
            -GroupTag 'BG-Default, PAW, PAW-CSM' `
            -ManagementUrl 'https://func.example/api/management/tag-policy' `
            -ApiApplicationIdUri 'api://33333333-3333-3333-3333-333333333333' `
            -TenantId '44444444-4444-4444-4444-444444444444' `
            -Confirm:$false | Out-Null

        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport.Client `
            -ParameterFilter {
                if ($Method -ne 'Put') {
                    return $false
                }
                $updatedRule = @(($Body | ConvertFrom-Json).policy |
                    Where-Object groupId -eq `
                        '11111111-1111-1111-1111-111111111111')[0]
                @($updatedRule.tags).Count -eq 1 -and
                    $updatedRule.tags[0] -eq 'Shared'
            } `
            -Times 1
    }

    It 'does not remove an individual tag with WhatIf' {
        Mock Invoke-RestMethod -ModuleName AutopilotImport.Client {
            if ($Method -eq 'Get') {
                return [pscustomobject]@{
                    policy = @([pscustomobject]@{
                        groupId = '22222222-2222-2222-2222-222222222222'
                        tags = @('Legacy', 'Shared')
                    })
                }
            }
            return [pscustomobject]@{ updated = $true }
        }

        Remove-AutoPilotTagPolicy `
            -Group '22222222-2222-2222-2222-222222222222' `
            -GroupTag 'Legacy' `
            -ManagementUrl 'https://func.example/api/management/tag-policy' `
            -ApiApplicationIdUri 'api://33333333-3333-3333-3333-333333333333' `
            -TenantId '44444444-4444-4444-4444-444444444444' `
            -WhatIf

        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport.Client `
            -ParameterFilter { $Method -eq 'Put' } `
            -Times 0
    }

    It 'rejects removing a tag that is not assigned to the group' {
        {
            Remove-AutoPilotTagPolicy `
                -Group '22222222-2222-2222-2222-222222222222' `
                -GroupTag 'Unknown' `
                -ManagementUrl 'https://func.example/api/management/tag-policy' `
                -ApiApplicationIdUri 'api://33333333-3333-3333-3333-333333333333' `
                -TenantId '44444444-4444-4444-4444-444444444444' `
                -Confirm:$false
        } | Should -Throw '*does not contain Group Tag(s): Unknown*'
    }

    It 'refuses to remove the last tag from a group rule' {
        {
            Remove-AutoPilotTagPolicy `
                -Group '22222222-2222-2222-2222-222222222222' `
                -GroupTag 'Legacy' `
                -ManagementUrl 'https://func.example/api/management/tag-policy' `
                -ApiApplicationIdUri 'api://33333333-3333-3333-3333-333333333333' `
                -TenantId '44444444-4444-4444-4444-444444444444' `
                -Confirm:$false
        } | Should -Throw '*last Group Tag cannot be removed*'
    }

    It 'does not remove the rule with WhatIf' {
        Remove-AutoPilotTagPolicy `
            -Group '22222222-2222-2222-2222-222222222222' `
            -ManagementUrl 'https://func.example/api/management/tag-policy' `
            -ApiApplicationIdUri 'api://33333333-3333-3333-3333-333333333333' `
            -TenantId '44444444-4444-4444-4444-444444444444' `
            -WhatIf

        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport.Client `
            -ParameterFilter { $Method -eq 'Put' } `
            -Times 0
    }

    It 'refuses to remove the last policy rule' {
        Mock Invoke-RestMethod -ModuleName AutopilotImport.Client {
            if ($Method -eq 'Get') {
                return [pscustomobject]@{
                    policy = @([pscustomobject]@{
                        groupId = '22222222-2222-2222-2222-222222222222'
                        tags = @('Legacy')
                    })
                }
            }
        }

        {
            Remove-AutoPilotTagPolicy `
                -Group '22222222-2222-2222-2222-222222222222' `
                -ManagementUrl 'https://func.example/api/management/tag-policy' `
                -ApiApplicationIdUri 'api://33333333-3333-3333-3333-333333333333' `
                -TenantId '44444444-4444-4444-4444-444444444444' `
                -Confirm:$false
        } | Should -Throw '*last Group Tag policy rule cannot be removed*'
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

Describe 'Import audit table storage' {
    BeforeAll {
        $auditToken = ConvertTo-SecureString 'storage-token' `
            -AsPlainText `
            -Force
    }

    BeforeEach {
        $env:AzureWebJobsStorage__accountName = 'staudit'
        $env:IMPORT_AUDIT_TABLE_NAME = 'importaudit'
    }

    AfterEach {
        Remove-Item Env:AzureWebJobsStorage__accountName `
            -ErrorAction SilentlyContinue
        Remove-Item Env:IMPORT_AUDIT_TABLE_NAME `
            -ErrorAction SilentlyContinue
    }

    It 'resolves and validates the configured table endpoint' {
        Get-ImportAuditTableUri |
            Should -Be 'https://staudit.table.core.windows.net/importaudit'

        $env:IMPORT_AUDIT_TABLE_NAME = 'invalid-name'
        { Get-ImportAuditTableUri } | Should -Throw '*is invalid*'
    }

    It 'merges audit properties into an existing import record' {
        Mock Invoke-RestMethod -ModuleName AutopilotImport {}
        $importId = [guid] '11111111-1111-1111-1111-111111111111'

        Set-ImportAuditRecord `
            -ImportId $importId `
            -Properties @{
                actorUserPrincipalName = 'user@example.com'
                processingCompletedAtUtc = '2026-09-18T12:00:00.0000000Z'
            } `
            -AccessToken $auditToken

        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport `
            -Times 1 `
            -ParameterFilter {
                $Method -eq 'Merge' -and
                $Uri -eq "https://staudit.table.core.windows.net/importaudit(PartitionKey='imports',RowKey='$importId')" -and
                $Body -match 'user@example\.com' -and
                $Headers['If-Match'] -eq '*'
            }
    }

    It 'inserts an audit record when the merge target does not exist' {
        Mock Invoke-RestMethod -ModuleName AutopilotImport {
            if ($Method -eq 'Merge') {
                $exception = [InvalidOperationException]::new('Not found')
                $exception.Data['StatusCode'] = 404
                throw $exception
            }
        }

        Set-ImportAuditRecord `
            -ImportId ([guid] '22222222-2222-2222-2222-222222222222') `
            -Properties @{ actorObjectId = 'actor-id' } `
            -AccessToken $auditToken

        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport `
            -Times 1 `
            -ParameterFilter { $Method -eq 'Merge' }
        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport `
            -Times 1 `
            -ParameterFilter {
                $Method -eq 'Post' -and
                $Uri -eq 'https://staudit.table.core.windows.net/importaudit' -and
                -not $Headers.ContainsKey('If-Match')
            }
    }

    It 'returns audit records indexed by import ID' {
        Mock Invoke-RestMethod -ModuleName AutopilotImport {
            [pscustomobject]@{
                value = @(
                    [pscustomobject]@{
                        PartitionKey = 'imports'
                        RowKey = '33333333-3333-3333-3333-333333333333'
                        actorDisplayName = 'Ada Lovelace'
                    }
                )
            }
        }

        $records = Get-ImportAuditRecords `
            -ImportId @(
                [guid] '33333333-3333-3333-3333-333333333333'
                [guid] '44444444-4444-4444-4444-444444444444'
            ) `
            -AccessToken $auditToken

        $records['33333333-3333-3333-3333-333333333333'].actorDisplayName |
            Should -Be 'Ada Lovelace'
        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport `
            -Times 1 `
            -ParameterFilter {
                $Method -eq 'Get' -and $Uri -match '\$filter='
            }
    }

    It 'creates the same SHA-256 index for equivalent Base64 device hashes' {
        $deviceHash = [Convert]::ToBase64String([byte[]](1, 2, 3, 4))

        Get-DeviceHashSha256 -DeviceHash $deviceHash |
            Should -Be '9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a'
    }

    It 'returns recent owner records in newest-first order' {
        Mock Invoke-RestMethod -ModuleName AutopilotImport {
            [pscustomobject]@{
                value = @(
                    [pscustomobject]@{
                        RowKey = '55555555-5555-5555-5555-555555555555'
                        requestReceivedAtUtc = '2026-09-17T10:00:00Z'
                    }
                    [pscustomobject]@{
                        RowKey = '66666666-6666-6666-6666-666666666666'
                        requestReceivedAtUtc = '2026-09-18T10:00:00Z'
                    }
                )
            }
        }

        $records = @(Get-ImportAuditHistory `
            -ActorObjectId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' `
            -SinceUtc ([datetimeoffset] '2026-08-19T00:00:00Z') `
            -Top 1 `
            -AccessToken $auditToken)

        $records.Count | Should -Be 1
        $records[0].RowKey | Should -Be `
            '66666666-6666-6666-6666-666666666666'
        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport `
            -ParameterFilter {
                $decodedUri = [uri]::UnescapeDataString($Uri)
                $Method -eq 'Get' -and
                $decodedUri.Contains("requestReceivedAtUtc ge '2026-08-19T00:00:00.0000000Z'") -and
                $decodedUri.Contains("actorObjectId eq 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'")
            }
    }

    It 'defaults import audit retention to 30 days' {
        $referenceUtc = [datetimeoffset] '2026-09-18T12:00:00Z'

        Get-ImportAuditRetentionCutoffUtc -ReferenceUtc $referenceUtc |
            Should -Be ([datetimeoffset] '2026-08-19T12:00:00Z')
        Get-ImportAuditRetentionCutoffUtc `
            -RetentionDays 60 `
            -ReferenceUtc $referenceUtc |
            Should -Be ([datetimeoffset] '2026-07-20T12:00:00Z')
    }

    It 'filters import audit history by serial number' {
        Mock Invoke-RestMethod -ModuleName AutopilotImport {
            [pscustomobject]@{ value = @() }
        }

        Get-ImportAuditHistory `
            -SerialNumber "SERIAL-'001" `
            -SinceUtc ([datetimeoffset] '2026-08-19T00:00:00Z') `
            -AccessToken $auditToken | Out-Null

        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport `
            -ParameterFilter {
                $decodedUri = [uri]::UnescapeDataString($Uri)
                $Method -eq 'Get' -and
                $decodedUri.Contains("serialNumber eq 'SERIAL-''001'")
            }
    }

    It 'filters import audit history by user principal name' {
        Mock Invoke-RestMethod -ModuleName AutopilotImport {
            [pscustomobject]@{ value = @() }
        }

        Get-ImportAuditHistory `
            -ActorUserPrincipalName "user'o@example.com" `
            -SinceUtc ([datetimeoffset] '2026-08-19T00:00:00Z') `
            -AccessToken $auditToken | Out-Null

        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport `
            -ParameterFilter {
                $decodedUri = [uri]::UnescapeDataString($Uri)
                $Method -eq 'Get' -and
                $decodedUri.Contains(
                    "actorUserPrincipalName eq 'user''o@example.com'")
            }
    }

    It 'deletes audit records older than the retention cutoff' {
        Mock Invoke-RestMethod -ModuleName AutopilotImport {
            if ($Method -eq 'Get') {
                return [pscustomobject]@{
                    value = @([pscustomobject]@{
                        RowKey = '77777777-7777-7777-7777-777777777777'
                    })
                }
            }
        }

        $removedCount = Remove-ExpiredImportAuditRecords `
            -BeforeUtc ([datetimeoffset] '2026-08-19T00:00:00Z') `
            -AccessToken $auditToken

        $removedCount | Should -Be 1
        Should -Invoke Invoke-RestMethod `
            -ModuleName AutopilotImport `
            -Times 1 `
            -ParameterFilter {
                $Method -eq 'Delete' -and
                ([string] $Uri).Contains(
                    "RowKey='77777777-7777-7777-7777-777777777777'")
            }
    }
}

Describe 'Autopilot import request validation' {
    It 'builds a Graph payload with the server-side group tag' {
        $requestBody = [pscustomobject]@{
            serialNumber       = '  PC-001  '
            hardwareIdentifier = [Convert]::ToBase64String([byte[]](1, 2, 3, 4))
            groupTag           = 'Untrusted-Client-Tag'
        }

        $payload = ConvertTo-AutoPilotImportPayload -RequestBody $requestBody -GroupTag 'Corporate'

        $payload.serialNumber | Should -Be 'PC-001'
        $payload.groupTag | Should -Be 'Corporate'
    }

    It 'rejects a malformed hardware hash' {
        $requestBody = [pscustomobject]@{
            serialNumber       = 'PC-001'
            hardwareIdentifier = 'not-base64'
        }

        { ConvertTo-AutoPilotImportPayload -RequestBody $requestBody -GroupTag 'Corporate' } |
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
        $registrationId = Get-AutoPilotDeviceRegistrationId -ImportedDevice `
            ([pscustomobject]@{
                state = [pscustomobject]@{
                    deviceRegistrationId = '11111111-1111-1111-1111-111111111111'
                }
            })

        $registrationId | Should -Be '11111111-1111-1111-1111-111111111111'
    }

    It 'rejects an import without a device registration ID' {
        {
            Get-AutoPilotDeviceRegistrationId -ImportedDevice `
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

    It 'returns all unique tags authorized through caller groups' {
        $principal.claims += @{
            typ = 'groups'
            val = '22222222-2222-2222-2222-222222222222'
        }

        $tags = @(Get-AuthorizedGroupTags -Principal $principal -Policy $policy)

        $tags | Should -Be @(
            'Autopilot-Kiosk'
            'Autopilot-Privileged'
            'Autopilot-Standard'
        )
    }

    It 'returns no tags for a caller without matching groups' {
        $unknownPrincipal = [pscustomobject]@{
            claims = @(@{
                typ = 'groups'
                val = '33333333-3333-3333-3333-333333333333'
            })
        }

        @(Get-AuthorizedGroupTags `
            -Principal $unknownPrincipal `
            -Policy $policy).Count | Should -Be 0
    }

    It 'uses a current Graph membership that is absent from the token' {
        Mock Invoke-RestMethod -ModuleName AutopilotImport {
            [pscustomobject]@{
                value = @('22222222-2222-2222-2222-222222222222')
            }
        }
        $principal.claims += @{
            typ = 'oid'
            val = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        }

        $resolvedPrincipal = Get-CurrentPolicyPrincipal `
            -Principal $principal `
            -Policy $policy `
            -AccessToken (ConvertTo-SecureString 'token' -AsPlainText -Force)

        @(Get-AuthorizedGroupTags `
            -Principal $resolvedPrincipal `
            -Policy $policy) | Should -Be @('Autopilot-Privileged')
    }

    It 'removes stale token memberships that Graph no longer returns' {
        Mock Invoke-RestMethod -ModuleName AutopilotImport {
            [pscustomobject]@{ value = @() }
        }
        $principal.claims += @{
            typ = 'oid'
            val = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        }

        $resolvedPrincipal = Get-CurrentPolicyPrincipal `
            -Principal $principal `
            -Policy $policy `
            -AccessToken (ConvertTo-SecureString 'token' -AsPlainText -Force)

        @(Get-AuthorizedGroupTags `
            -Principal $resolvedPrincipal `
            -Policy $policy).Count | Should -Be 0
    }

    It 'checks policy groups in batches of no more than twenty' {
        $largePolicy = @(1..21 | ForEach-Object {
            [pscustomobject]@{
                groupId = ([guid]::NewGuid()).ToString()
                tags    = @("Tag-$_")
            }
        })
        $principal.claims += @{
            typ = 'oid'
            val = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        }
        Mock Invoke-RestMethod -ModuleName AutopilotImport {
            [pscustomobject]@{ value = @() }
        }

        Get-CurrentPolicyPrincipal `
            -Principal $principal `
            -Policy $largePolicy `
            -AccessToken (ConvertTo-SecureString 'token' -AsPlainText -Force) |
            Out-Null

        Assert-MockCalled Invoke-RestMethod `
            -ModuleName AutopilotImport `
            -Times 2 `
            -Exactly
    }

    It 'grants both application permissions required to check other users groups' {
        $grantScript = Get-Content `
            -LiteralPath (Join-Path $PSScriptRoot `
                '..\Scripts\Grant-ManagedIdentityGraphPermission.ps1') `
            -Raw

        $grantScript | Should -Match "'GroupMember\.Read\.All'"
        $grantScript | Should -Match "'User\.ReadBasic\.All'"
    }
}

Describe 'Installer tag authorization rules' {
    BeforeAll {
        $installerPath = Join-Path $PSScriptRoot '..\Installer\Install-AutopilotImport.ps1'
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

    It 'accepts structured policy rule objects at the installer entry point' {
        $parameter = $installerAst.ParamBlock.Parameters | Where-Object {
            $_.Name.VariablePath.UserPath -eq 'TagAuthorizationRule'
        }

        $parameter.StaticType | Should -Be ([object[]])
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

    It 'preserves an optional administrative unit name' {
        $policy = ConvertTo-TagAuthorizationPolicy `
            -Rules @('11111111-1111-1111-1111-111111111111=Standard') `
            -AdministrativeUnitName ' RMAU-Autopilot '

        $policy.administrativeUnitName |
            Should -Be 'RMAU-Autopilot'
        AutopilotImport\Resolve-AdministrativeUnitName `
            -Policy $policy `
            -GroupTag 'Standard' | Should -Be 'RMAU-Autopilot'
    }

    It 'preserves a different administrative unit for each rule' {
        $policy = ConvertTo-TagAuthorizationPolicy -Rules @(
            [pscustomobject]@{
                groupId = '11111111-1111-1111-1111-111111111111'
                tags = @('Standard')
                administrativeUnitName = 'RMAU-Standard'
            }
            [pscustomobject]@{
                groupId = '22222222-2222-2222-2222-222222222222'
                tags = @('Kiosk')
                administrativeUnitName = 'RMAU-Kiosk'
            }
        )

        $policy[0].administrativeUnitName |
            Should -Be 'RMAU-Standard'
        $policy[1].administrativeUnitName |
            Should -Be 'RMAU-Kiosk'
        AutopilotImport\Resolve-AdministrativeUnitName `
            -Policy $policy `
            -GroupTag 'Kiosk' | Should -Be 'RMAU-Kiosk'
    }

    It 'accepts the administrative unit property name' {
        $policy = ConvertTo-TagAuthorizationPolicy -Rules @(
            [pscustomobject]@{
                groupId = '11111111-1111-1111-1111-111111111111'
                tags = @('Standard')
                administrativeUnitName = 'MAU-Standard'
            }
        )

        $policy.administrativeUnitName |
            Should -Be 'MAU-Standard'
    }

    It 'resolves the administrative unit from the caller group when rules share a tag' {
        $policy = ConvertTo-TagAuthorizationPolicy -Rules @(
            [pscustomobject]@{
                groupId = '11111111-1111-1111-1111-111111111111'
                tags = @('Shared')
                administrativeUnitName = 'RMAU-One'
            }
            [pscustomobject]@{
                groupId = '22222222-2222-2222-2222-222222222222'
                tags = @('Shared')
                administrativeUnitName = 'RMAU-Two'
            }
        )
        $principal = [pscustomobject]@{
            claims = @([pscustomobject]@{
                typ = 'groups'
                val = '22222222-2222-2222-2222-222222222222'
            })
        }

        AutopilotImport\Resolve-AdministrativeUnitName `
            -Policy $policy `
            -GroupTag 'Shared' `
            -Principal $principal | Should -Be 'RMAU-Two'
    }

    It 'keeps the current policy shape when no administrative unit is configured' {
        $policy = ConvertTo-TagAuthorizationPolicy `
            -Rules @('11111111-1111-1111-1111-111111111111=Standard')

        $policy.PSObject.Properties.Name |
            Should -Not -Contain 'administrativeUnitName'
        AutopilotImport\Resolve-AdministrativeUnitName `
            -Policy $policy `
            -GroupTag 'Standard' | Should -BeNullOrEmpty
    }
}

Describe 'Effective administrative unit resolution' {
    It 'binds the current tag policy to the queue worker' {
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $functionRoot = Join-Path `
            $projectRoot `
            'src\FunctionApp\ProcessDeviceAttribute'
        $configuration = Get-Content `
            -LiteralPath (Join-Path $functionRoot 'function.json') `
            -Raw |
            ConvertFrom-Json
        $policyBinding = @($configuration.bindings | Where-Object {
            $_.name -eq 'TagPolicyBlob'
        }) | Select-Object -First 1
        $worker = Get-Content `
            -LiteralPath (Join-Path $functionRoot 'run.ps1') `
            -Raw

        $policyBinding.type | Should -Be 'blob'
        $policyBinding.direction | Should -Be 'in'
        $policyBinding.path | Should -Be `
            'configuration/tag-authorization-policy.json'
        $worker | Should -Match `
            'Resolve-EffectiveAdministrativeUnitName'
    }

    It 'uses a current policy mapping when the queued value is empty' {
        $policy = @([pscustomobject]@{
            groupId = '11111111-1111-1111-1111-111111111111'
            tags = @('PAW-CSM')
            administrativeUnitName = 'PAW'
        })

        Resolve-EffectiveAdministrativeUnitName `
            -Policy $policy `
            -GroupTag 'PAW-CSM' | Should -Be 'PAW'
    }

    It 'prefers a changed current policy mapping over the queued value' {
        $policy = @([pscustomobject]@{
            groupId = '11111111-1111-1111-1111-111111111111'
            tags = @('PAW-CSM')
            administrativeUnitName = 'PAW-Current'
        })

        Resolve-EffectiveAdministrativeUnitName `
            -Policy $policy `
            -GroupTag 'PAW-CSM' `
            -QueuedAdministrativeUnitName 'PAW-Old' |
            Should -Be 'PAW-Current'
    }

    It 'retains the queued value when the current policy has no mapping' {
        Resolve-EffectiveAdministrativeUnitName `
            -Policy @() `
            -GroupTag 'PAW-CSM' `
            -QueuedAdministrativeUnitName 'PAW' | Should -Be 'PAW'
    }

    It 'uses the queued value to disambiguate shared tag mappings' {
        $policy = @(
            [pscustomobject]@{
                groupId = '11111111-1111-1111-1111-111111111111'
                tags = @('Shared')
                administrativeUnitName = 'RMAU-One'
            }
            [pscustomobject]@{
                groupId = '22222222-2222-2222-2222-222222222222'
                tags = @('Shared')
                administrativeUnitName = 'RMAU-Two'
            }
        )

        Resolve-EffectiveAdministrativeUnitName `
            -Policy $policy `
            -GroupTag 'Shared' `
            -QueuedAdministrativeUnitName 'RMAU-Two' |
            Should -Be 'RMAU-Two'
    }
}

Describe 'Administrative unit membership' {
    InModuleScope AutopilotImport {
        BeforeEach {
            $script:administrativeUnit = [pscustomobject]@{
                id                           = '22222222-2222-2222-2222-222222222222'
                displayName                  = 'RMAU-Autopilot'
                isMemberManagementRestricted = $true
            }
            $script:administrativeUnits = @($script:administrativeUnit)
            $script:existingMembers = @()
            Mock Invoke-RestMethod {
                if ($Uri -match '/members\?') {
                    return @{ value = @($script:existingMembers) }
                }
                if ($Method -eq 'Get') {
                    return @{ value = @($script:administrativeUnits) }
                }
                return $null
            }
        }

        It 'adds a new Entra device member to the named RMAU' {
            $deviceObjectId = [guid] `
                '11111111-1111-1111-1111-111111111111'
            $result = `
                Add-EntraDeviceToAdministrativeUnit `
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
                Add-EntraDeviceToAdministrativeUnit `
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
                Add-EntraDeviceToAdministrativeUnit `
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

        It 'adds a device to a regular administrative unit' {
            $script:administrativeUnit.isMemberManagementRestricted = $false

            $result = `
                Add-EntraDeviceToAdministrativeUnit `
                    -AdministrativeUnitName 'RMAU-Autopilot' `
                    -DeviceObjectId '11111111-1111-1111-1111-111111111111' `
                    -AccessToken (ConvertTo-SecureString 'token' `
                        -AsPlainText -Force)

            $result.MembershipAdded | Should -BeTrue
            Assert-MockCalled Invoke-RestMethod -Times 1 `
                -ParameterFilter { $Method -eq 'Post' }
        }

        It 'rejects a missing administrative unit' {
            $script:administrativeUnits = @()

            {
                Resolve-EntraAdministrativeUnit `
                    -AdministrativeUnitName 'Missing' `
                    -AccessToken (ConvertTo-SecureString 'token' `
                        -AsPlainText -Force)
            } | Should -Throw "*Administrative unit 'Missing' was not found*"
        }

        It 'rejects a non-unique administrative unit display name' {
            $script:administrativeUnits = @(
                $script:administrativeUnit
                [pscustomobject]@{
                    id = '33333333-3333-3333-3333-333333333333'
                    displayName = 'RMAU-Autopilot'
                    isMemberManagementRestricted = $false
                }
            )

            {
                Resolve-EntraAdministrativeUnit `
                    -AdministrativeUnitName 'RMAU-Autopilot' `
                    -AccessToken (ConvertTo-SecureString 'token' `
                        -AsPlainText -Force)
            } | Should -Throw '*Administrative unit name*is not unique*'
        }
    }

}

Describe 'Installer Function App naming' {
    BeforeAll {
        $installerPath = Join-Path $PSScriptRoot '..\Installer\Install-AutopilotImport.ps1'
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
        $installerPath = Join-Path $PSScriptRoot '..\Installer\Install-AutopilotImport.ps1'
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
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $installerPath = Join-Path $projectRoot 'src\Installer\Install-AutopilotImport.ps1'
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
            $node.Name -eq 'Install-AutoPilotClientTools'
        }, $true) | Select-Object -First 1
        Invoke-Expression $functionAst.Extent.Text
    }

    It 'uses Documents AutopilotImport as the default client tools path' {
        $installerAst.Extent.Text | Should -Match `
            'Join-Path\s+\$documentsPath\s+''AutopilotImport'''
        $installerAst.Extent.Text | Should -Not -Match `
            'defaultClientToolsPath\s*=.*PowerShell\\Scripts\\AutopilotImport'
    }

    It 'keeps formatted status output out of the installer result stream' {
        $installerAst.Extent.Text | Should -Match `
            '(?s)Write-Host "`nInstallation completed\.".*?\$result\s*\|\s*Format-List\s*\|\s*Out-Host\s+\$result'
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

        $settingsPath = Install-AutoPilotClientTools `
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
            $autoloadedCommand = Get-Command Import-AutoPilotDevice `
                -ErrorAction Stop
            $autoloadedCommand.Module.Path | Should -Be `
                (Join-Path $autoloadModuleRoot `
                    "AutopilotImport.Client\$moduleVersion\AutopilotImport.Client.psm1")
            Get-Command Get-AutoPilotImportHistory `
                -Module AutopilotImport.Client `
                -ErrorAction Stop | Should -Not -BeNullOrEmpty
            Get-Command Get-AutoPilotTagPolicyManager `
                -Module AutopilotImport.Client `
                -ErrorAction Stop | Should -Not -BeNullOrEmpty
        }
        finally {
            Remove-Module AutopilotImport.Client -ErrorAction SilentlyContinue
            $env:PSModulePath = $originalModulePath
        }

        Import-Module `
            (Join-Path $modulePath 'AutopilotImport.Client.psd1') `
            -Force
            (Get-Command -Module AutopilotImport.Client).Count | Should -Be 13
        Remove-Module AutopilotImport.Client
    }
}

Describe 'Update script deployment discovery' {
    BeforeAll {
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $updateScriptPath = Join-Path $projectRoot 'src\Installer\Update-AutopilotImport.ps1'
        $tokens = $null
        $parseErrors = $null
        $updateAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $updateScriptPath,
            [ref] $tokens,
            [ref] $parseErrors
        )
        foreach ($functionName in @(
                'Resolve-AutoPilotUpdateConfigPath',
                'Resolve-AutoPilotFunctionAppFromUrl',
            'Read-AutoPilotUpdateValue',
            'Get-AutoPilotUpdateConfigurationValue',
                'Get-AutoPilotClientToolsPath',
                'Test-SystemWideClientModuleAccess',
                'Get-UserAutoPilotClientModuleRoots',
                'Resolve-AutoPilotDeploymentResult',
                'Install-SystemWideAutopilotClientModule',
                'ConvertTo-UpdateTagAuthorizationRules',
                'Assert-AutoPilotAppSettingsResponse',
                'Get-UpdateWebClientId',
                'Get-UpdateWebRedirectUri',
                'Get-UpdateWebAppHostName',
                'Get-UpdateWebAppHostNameBinding',
                'Get-UpdateApplicationInsightsWorkspaceResourceId',
                'Write-UpdateLogAnalyticsWorkspaceMigrationNotice',
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

        Resolve-AutoPilotUpdateConfigPath -Path $configPath |
            Should -Be (Resolve-Path $configPath).Path
    }

    It 'accepts deployment identity parameters without a configuration' {
        foreach ($parameterName in @(
                'SubscriptionId',
                'TenantId',
                'ResourceGroupName',
                'FunctionAppName',
                'FunctionUrl',
                'ApiAudience',
                'ManagementUrl'
            )) {
            $updateAst.ParamBlock.Parameters.Name.VariablePath.UserPath |
                Should -Contain $parameterName
        }
        $updateAst.Extent.Text | Should -Match `
            '(?s)Resolve-AutoPilotUpdateConfigPath\s+.*?-AllowMissing'
    }

    It 'does not require elevation before deployment changes are made' {
        $updateAst.Extent.Text | Should -Not -Match `
            '(?s)ShouldProcess.*?Assert-SystemWideClientModuleAccess\s+.*?\$installerOutput\s*='
    }

    It 'selects the structured deployment result from mixed installer output' {
        $expectedResult = [pscustomobject]@{
            InstalledClientSettingsPath = `
                'C:\Tools\AutopilotImport\client.settings.json'
        }

        $result = Resolve-AutoPilotDeploymentResult -InstallerOutput @(
            [pscustomobject]@{ Noise = 'Az command output' }
            $expectedResult
            'informational output'
        )

        $result.InstalledClientSettingsPath | Should -Be `
            $expectedResult.InstalledClientSettingsPath
    }

    It 'rejects installer output without a structured deployment result' {
        {
            Resolve-AutoPilotDeploymentResult -InstallerOutput @(
                [pscustomobject]@{ Noise = 'Az command output' }
            )
        } | Should -Throw `
            '*exactly one result with InstalledClientSettingsPath was expected*'
    }

    It 'resolves deployment identity from a Function URL' {
        Mock Get-AzSubscription {
            [pscustomobject]@{
                Id       = '11111111-1111-1111-1111-111111111111'
                TenantId = '22222222-2222-2222-2222-222222222222'
            }
        }
        Mock Set-AzContext { }
        Mock Invoke-AzRestMethod {
            [pscustomobject]@{
                StatusCode = 200
                Content    = @{
                    value = @(@{
                        id = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-autopilot/providers/Microsoft.Web/sites/func-autopilot-test'
                        name = 'func-autopilot-test'
                        type = 'Microsoft.Web/sites'
                    })
                } | ConvertTo-Json -Depth 5
            }
        }

        $deployment = Resolve-AutoPilotFunctionAppFromUrl `
            -Url 'https://func-autopilot-test.azurewebsites.net/api/ui/index.html'

        $deployment.SubscriptionId | Should -Be `
            '11111111-1111-1111-1111-111111111111'
        $deployment.TenantId | Should -Be `
            '22222222-2222-2222-2222-222222222222'
        $deployment.ResourceGroupName | Should -Be 'rg-autopilot'
        $deployment.FunctionAppName | Should -Be 'func-autopilot-test'
        Should -Invoke Get-AzSubscription -Times 1
        Should -Invoke Set-AzContext -Times 1
    }

    It 'rejects a Function URL outside azurewebsites.net' {
        {
            Resolve-AutoPilotFunctionAppFromUrl `
                -Url 'https://example.test/api/devices/import'
        } | Should -Throw '*azurewebsites.net*'
    }

    It 'passes FunctionUrl to the discovery helper as Url' {
        $updateAst.Extent.Text | Should -Match `
            '\$discoveryParameters\s*=\s*@\{\s*Url\s*=\s*\$FunctionUrl\s*\}'
        $updateAst.Extent.Text | Should -Match `
            '(?s)Resolve-AutoPilotFunctionAppFromUrl\s+.*?@discoveryParameters'
    }

    It 'requires an unambiguous Function URL discovery result' {
        Mock Get-AzSubscription {
            @(
                [pscustomobject]@{ Id = 'sub-one'; TenantId = 'tenant-one' }
                [pscustomobject]@{ Id = 'sub-two'; TenantId = 'tenant-two' }
            )
        }
        Mock Set-AzContext { }
        Mock Invoke-AzRestMethod {
            $subscriptionId = if ($Path -match '/subscriptions/([^/]+)/') {
                $Matches[1]
            }
            [pscustomobject]@{
                StatusCode = 200
                Content    = @{
                    value = @(@{
                        id = "/subscriptions/$subscriptionId/resourceGroups/rg-$subscriptionId/providers/Microsoft.Web/sites/func-shared"
                        name = 'func-shared'
                        type = 'Microsoft.Web/sites'
                    })
                } | ConvertTo-Json -Depth 5
            }
        }

        {
            Resolve-AutoPilotFunctionAppFromUrl `
                -Url 'https://func-shared.azurewebsites.net'
        } | Should -Throw '*Use -SubscriptionId*'
    }

    It 'uses Documents AutopilotImport when no client tools path is installed' {
        $updateAst.Extent.Text | Should -Match `
            'DefaultValue\s+\(Join-Path\s+\$documentsPath\s+''AutopilotImport''\)'
        $updateAst.Extent.Text | Should -Match `
            'AutopilotImport\\Modules\\AutopilotImport.Client'
        $updateAst.Extent.Text | Should -Match `
            'PowerShell\\Scripts\\AutopilotImport\\Modules\\AutopilotImport.Client'
    }

    It 'uses a supplied update value without prompting' {
        Mock Read-Host { throw 'Read-Host should not be called.' }

        Read-AutoPilotUpdateValue `
            -CurrentValue ' supplied-value ' `
            -Prompt 'Required value' | Should -Be 'supplied-value'

        Should -Invoke Read-Host -Times 0
    }

    It 'accepts the interactive default for a missing update value' {
        Mock Read-Host { '' }

        Read-AutoPilotUpdateValue `
            -Prompt 'Required value' `
            -DefaultValue 'default-value' | Should -Be 'default-value'

        Should -Invoke Read-Host `
            -ParameterFilter { $Prompt -eq 'Required value [default-value]' } `
            -Times 1
    }

    It 'reads deployment endpoints from Azure when no config is installed' {
        $updateAst.Extent.Text | Should -Match `
            '(?s)API_AUDIENCE.*?Use -ApiAudience'
        $updateAst.Extent.Text | Should -Match `
            'https://\$defaultHostName/api/management/tag-policy'
        $updateAst.Extent.Text | Should -Match `
            '(?s)Get-AutoPilotTagPolicy\s+.*?-ManagementUrl\s+\$resolvedManagementUrl\s+.*?-ApiApplicationIdUri\s+\$resolvedApiAudience\s+.*?-TenantId\s+\$TenantId'
    }

    It 'discovers a versioned configuration installed through PSModulePath' {
        $modulePathRoot = Join-Path $TestDrive 'PowerShell\Modules'
        $olderConfigPath = Join-Path $modulePathRoot `
            'AutopilotImport.Client\9998.0.0.0\client.settings.json'
        $newerConfigPath = Join-Path $modulePathRoot `
            'AutopilotImport.Client\9999.0.0.0\client.settings.json'
        [void] (New-Item `
            -Path (Split-Path $olderConfigPath -Parent) `
            -ItemType Directory `
            -Force)
        [void] (New-Item `
            -Path (Split-Path $newerConfigPath -Parent) `
            -ItemType Directory `
            -Force)
        '{}' | Set-Content -LiteralPath $olderConfigPath
        '{}' | Set-Content -LiteralPath $newerConfigPath

        $originalModulePath = $env:PSModulePath
        try {
            $env:PSModulePath = $modulePathRoot

            Resolve-AutoPilotUpdateConfigPath |
                Should -Be (Resolve-Path $newerConfigPath).Path
        }
        finally {
            $env:PSModulePath = $originalModulePath
        }
    }

    It 'derives the client package root from a versioned configuration' {
        $settingsPath = Join-Path $TestDrive `
            'AutopilotImport\Modules\AutopilotImport.Client\1.0.20260813.1\client.settings.json'

        Get-AutoPilotClientToolsPath -SettingsPath $settingsPath |
            Should -Be (Join-Path $TestDrive 'AutopilotImport')
    }

    It 'updates the system-wide client module and removes older versions' {
        $sourceVersion = '1.1.20260913.7'
        $sourceDirectory = Join-Path $TestDrive `
            "portable\Modules\AutopilotImport.Client\$sourceVersion"
        $systemModuleRoot = Join-Path $TestDrive `
            'Program Files\WindowsPowerShell\Modules\AutopilotImport.Client'
        $oldVersionDirectory = Join-Path $systemModuleRoot '1.1.20260911.1'
        [void] (New-Item -Path $sourceDirectory -ItemType Directory -Force)
        [void] (New-Item -Path $oldVersionDirectory -ItemType Directory -Force)
        Set-Content `
            -LiteralPath (Join-Path $sourceDirectory `
                'AutopilotImport.Client.psd1') `
            -Value "@{ ModuleVersion = '$sourceVersion' }"
        foreach ($fileName in @(
                'AutopilotImport.Client.psm1'
                'AutopilotImport.psm1'
                'client.settings.json'
            )) {
            Set-Content `
                -LiteralPath (Join-Path $sourceDirectory $fileName) `
                -Value $fileName
        }

        $installedSettingsPath = Install-SystemWideAutopilotClientModule `
            -SourceSettingsPath (Join-Path $sourceDirectory `
                'client.settings.json') `
            -DestinationRoot $systemModuleRoot

        $installedSettingsPath | Should -Be (Join-Path `
            $systemModuleRoot `
            "$sourceVersion\client.settings.json")
        foreach ($fileName in @(
                'AutopilotImport.Client.psm1'
                'AutopilotImport.Client.psd1'
                'AutopilotImport.psm1'
                'client.settings.json'
            )) {
            Join-Path $systemModuleRoot "$sourceVersion\$fileName" |
                Should -Exist
        }
        $oldVersionDirectory | Should -Not -Exist
    }

    It 'defines PowerShell 7 and Windows PowerShell per-user module roots' {
        $roots = @(Get-UserAutoPilotClientModuleRoots)

        $roots.Count | Should -Be 2
        $roots[0] | Should -BeLike `
            '*\PowerShell\Modules\AutopilotImport.Client'
        $roots[1] | Should -BeLike `
            '*\WindowsPowerShell\Modules\AutopilotImport.Client'
    }

    It 'falls back to user modules and warns when system-wide access is unavailable' {
        $updateAst.Extent.Text | Should -Match `
            '(?s)if \(Test-SystemWideClientModuleAccess\).*?if \(-not \$systemWideClientSettingsPath\).*?Get-UserAutoPilotClientModuleRoots'
        $updateAst.Extent.Text | Should -Match `
            'The system-wide modules under Program Files were not updated\.'
        $updateAst.Extent.Text | Should -Match `
            'Run Update-AutopilotImport\.ps1 later from an elevated PowerShell 7 session'
    }

    It 'synchronizes the system-wide module after the installer succeeds' {
        $updateAst.Extent.Text | Should -Match `
            '(?s)\$installerOutput\s*=\s*@\(&\s*\$installerPath.*?Resolve-AutoPilotDeploymentResult.*?\$sourceSettingsPath\s*=.*?InstalledClientSettingsPath.*?if \(Test-SystemWideClientModuleAccess\).*?Install-SystemWideAutopilotClientModule'
    }

    It 'converts the current policy into installer rules with individual RMAUs' {
        $rules = @(ConvertTo-UpdateTagAuthorizationRules -Policy @(
            [pscustomobject]@{
                groupId = '11111111-1111-1111-1111-111111111111'
                tags    = @('PAW-CSM', 'BG-Default')
                administrativeUnitName = 'RMAU-PAW'
            }
        ))

        $rules[0].groupId | Should -Be `
            '11111111-1111-1111-1111-111111111111'
        $rules[0].tags | Should -Be @('PAW-CSM', 'BG-Default')
        $rules[0].administrativeUnitName |
            Should -Be 'RMAU-PAW'
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

    It 'requests the raw policy response for deployment preservation' {
        $updateAst.Extent.Text | Should -Match `
            '(?s)Get-AutoPilotTagPolicy\s+.*?-Raw'
        $updateAst.Extent.Text | Should -Match `
            "did not return a Group Tag policy"
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

    It 'supports a fresh Graph sign-in after Entra role changes' {
        $forceGraphSignInParameter = $updateAst.ParamBlock.Parameters |
            Where-Object {
                $_.Name.VariablePath.UserPath -eq 'ForceGraphSignIn'
            }

        $forceGraphSignInParameter.StaticType | Should -Be ([switch])
        $updateAst.Extent.Text | Should -Match `
            'ForceGraphSignIn\s*=\s*\$ForceGraphSignIn'
    }

    It 'passes preserved identities when Entra configuration is skipped' {
        $webClientIdParameter = $updateAst.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'WebClientId' }

        $webClientIdParameter.StaticType | Should -Be ([guid])
        $updateAst.Extent.Text | Should -Match `
            'InstallerPrincipalId\s*=\s*\$installerPrincipalId'
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
            Assert-AutoPilotAppSettingsResponse -Response $response
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
            Assert-AutoPilotAppSettingsResponse -Response $response -Verbose 4>&1
        }
        catch {
        }

        $verboseOutput | Out-String | Should -Match 'user@example.com|1234'
    }

    It 'allows an older deployment without a web client ID to be updated' {
        $webClientId = Get-UpdateWebClientId -Properties ([pscustomobject]@{})

        $webClientId | Should -Be ([guid]::Empty)
    }

    It 'requires a deployed web client ID when Entra configuration is skipped' {
        {
            Get-UpdateWebClientId `
                -Properties ([pscustomobject]@{}) `
                -SkipEntraAppConfiguration
        } | Should -Throw '*valid WEB_CLIENT_ID*'
    }

    It 'preserves a valid deployed web client ID' {
        $expected = [guid]'22222222-2222-2222-2222-222222222222'
        $properties = [pscustomobject]@{
            WEB_CLIENT_ID = $expected.ToString()
        }

        Get-UpdateWebClientId -Properties $properties |
            Should -Be $expected
    }

    It 'builds redirect URIs only for custom Function App domains' {
        $redirectUris = @(Get-UpdateWebRedirectUri -HostName @(
            'func-example.azurewebsites.net'
            'func-example.scm.azurewebsites.net'
            'autopilot.example.com'
            'autopilot.example.com'
            ' imports.example.org '
            $null
        ))

        $redirectUris | Should -Be @(
            'https://autopilot.example.com/api/ui/index.html'
            'https://imports.example.org/api/ui/index.html'
        )
    }

    It 'discovers update hostnames from all Azure response shapes' {
        $site = [pscustomobject]@{
            properties = [pscustomobject]@{
                hostNames = @()
                enabledHostNames = @(
                    'func-example.azurewebsites.net'
                    'enabled.example.com'
                )
                hostNameSslStates = @(
                    [pscustomobject]@{ name = 'ssl.example.com' }
                )
            }
        }

        $hostNames = @(Get-UpdateWebAppHostName -WebApp $site)
        $redirectUris = @(Get-UpdateWebRedirectUri -HostName $hostNames)

        $redirectUris | Should -Be @(
            'https://enabled.example.com/api/ui/index.html'
            'https://ssl.example.com/api/ui/index.html'
        )
    }

    It 'discovers update hostnames from Azure hostname bindings' {
        Mock Invoke-AzRestMethod {
            [pscustomobject]@{
                StatusCode = 200
                Content = @{
                    value = @(
                        @{ name = 'func-example/func-example.azurewebsites.net' }
                        @{ name = 'func-example/autopilot.example.com' }
                    )
                } | ConvertTo-Json -Depth 4
            }
        }

        $hostNames = @(Get-UpdateWebAppHostNameBinding `
                -ResourceId '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Web/sites/func-example')

        $hostNames | Should -Be @(
            'func-example.azurewebsites.net'
            'autopilot.example.com'
        )
    }

    It 'passes discovered custom web redirects to the installer' {
        $updateAst.Extent.Text | Should -Match `
            'AdditionalWebRedirectUri\s*=\s*\$additionalWebRedirectUris'
    }

    It 'reads the workspace currently linked to Application Insights' {
        $expectedWorkspaceId = `
            '/subscriptions/sub-old/resourceGroups/ai-managed/providers/Microsoft.OperationalInsights/workspaces/managed-insights-ws'
        Mock Invoke-AzRestMethod {
            [pscustomobject]@{
                StatusCode = 200
                Content = @{
                    properties = @{
                        WorkspaceResourceId = $expectedWorkspaceId
                    }
                } | ConvertTo-Json -Depth 4
            }
        }

        $actualWorkspaceId = `
            Get-UpdateApplicationInsightsWorkspaceResourceId `
                -SubscriptionId 'sub-current' `
                -ResourceGroupName 'rg-autopilot-import' `
                -FunctionAppName 'func-autopilot-test'

        $actualWorkspaceId | Should -Be $expectedWorkspaceId
        Should -Invoke Invoke-AzRestMethod -Times 1 -ParameterFilter {
            $Method -eq 'GET' -and
            $Path -eq '/subscriptions/sub-current/resourceGroups/rg-autopilot-import/providers/Microsoft.Insights/components/func-autopilot-test-insights?api-version=2020-02-02'
        }
    }

    It 'warns after switching from a previously linked workspace' {
        $previousWorkspaceId = `
            '/subscriptions/sub-old/resourceGroups/ai-managed/providers/Microsoft.OperationalInsights/workspaces/managed-insights-ws'
        $integratedWorkspaceId = `
            '/subscriptions/sub-current/resourceGroups/rg-autopilot-import/providers/Microsoft.OperationalInsights/workspaces/func-autopilot-test-la'

        $warning = Write-UpdateLogAnalyticsWorkspaceMigrationNotice `
            -PreviousWorkspaceResourceId $previousWorkspaceId `
            -IntegratedWorkspaceResourceId $integratedWorkspaceId `
            3>&1

        $warning | Out-String | Should -Match `
            ([regex]::Escape($previousWorkspaceId))
        $warning | Out-String | Should -Match 'can be deleted'
        $warning | Out-String | Should -Match `
            'historical telemetry is no longer required'
    }

    It 'does not warn without a workspace migration' -TestCases @(
        @{ PreviousWorkspaceId = $null }
        @{
            PreviousWorkspaceId = `
                '/SUBSCRIPTIONS/sub-current/RESOURCEGROUPS/rg-autopilot-import/providers/Microsoft.OperationalInsights/workspaces/func-autopilot-test-la/'
        }
    ) {
        param($PreviousWorkspaceId)

        $warning = Write-UpdateLogAnalyticsWorkspaceMigrationNotice `
            -PreviousWorkspaceResourceId $PreviousWorkspaceId `
            -IntegratedWorkspaceResourceId `
                '/subscriptions/sub-current/resourceGroups/rg-autopilot-import/providers/Microsoft.OperationalInsights/workspaces/func-autopilot-test-la' `
            3>&1

        @($warning).Count | Should -Be 0
    }

    It 'emits the migration notice only after the installer succeeds' {
        $updateAst.Extent.Text | Should -Match `
            '(?s)\$installerOutput\s*=\s*@\(&\s*\$installerPath.+?\$deploymentResult\s*=\s*Resolve-AutoPilotDeploymentResult.+?Write-UpdateLogAnalyticsWorkspaceMigrationNotice.+?\$deploymentResult'
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
            'Missing Azure permissions for: Storage accounts, Blob services, Blob containers, Table services, Storage tables, Log Analytics workspaces, Application Insights, App Service plans, Function Apps, Function App configuration.'
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

Describe 'Entra web application Graph responses' {
    BeforeAll {
        $scriptPath = Join-Path `
            $PSScriptRoot `
            '..\Scripts\Ensure-EntraWebApplication.ps1'
        $tokens = $null
        $parseErrors = $null
        $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref] $tokens,
            [ref] $parseErrors
        )
        $functionAst = $scriptAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-GraphItems'
        }, $true) | Select-Object -First 1
        Invoke-Expression $functionAst.Extent.Text
        $redirectFunctionAst = $scriptAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Merge-WebRedirectUri'
        }, $true) | Select-Object -First 1
        Invoke-Expression $redirectFunctionAst.Extent.Text
        $permissionFunctionAst = $scriptAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'ConvertTo-ValidPermissionIds'
        }, $true) | Select-Object -First 1
        Invoke-Expression $permissionFunctionAst.Extent.Text
    }

    It 'unwraps dictionary collection responses from Microsoft Graph' {
        $application = @{
            id          = 'application-object-id'
            appId       = '22222222-2222-2222-2222-222222222222'
            displayName = 'Autopilot Import Web'
        }
        $response = @{ value = @($application) }

        $items = @(Get-GraphItems -Response $response)

        $items.Count | Should -Be 1
        $items[0].displayName | Should -Be 'Autopilot Import Web'
    }

    It 'keeps a single existing and additional SPA redirect as separate URIs' {
        $redirectUris = @(Merge-WebRedirectUri `
            -ExistingRedirectUri 'https://func-example.azurewebsites.net/api/ui/index.html' `
            -PrimaryRedirectUri 'https://func-example.azurewebsites.net/api/ui/index.html' `
            -AdditionalRedirectUri 'https://autopilot.example.com/api/ui/index.html')

        $redirectUris | Should -Be @(
            'https://func-example.azurewebsites.net/api/ui/index.html'
            'https://autopilot.example.com/api/ui/index.html'
        )
    }

    It 'keeps only well-formed permission IDs exposed by the API' {
        $scopeId = '11111111-1111-1111-1111-111111111111'
        $roleId = '22222222-2222-2222-2222-222222222222'

        $permissionIds = @(ConvertTo-ValidPermissionIds `
            -PermissionIds @(
                $scopeId,
                'not-a-guid',
                '33333333-3333-3333-3333-333333333333',
                $roleId,
                $scopeId,
                $null
            ) `
            -ValidPermissionIds @($scopeId, $roleId))

        $permissionIds | Should -Be @($scopeId, $roleId)
    }

    It 'always assigns the validated API scope to the target SPA' {
        $scriptText = Get-Content -LiteralPath $scriptPath -Raw

        $scriptText | Should -Match `
            '\$delegatedPermissionIds\s*=\s*@\(\[string\]\s*\$apiScope\[0\]\.id\)'
        $scriptText | Should -Not -Match `
            '\$existingDelegatedPermissionIds\s*\+\s*\$apiScopeIdString'
    }

    It 'adds custom-domain redirects without replacing existing SPA redirects' {
        $scriptText = Get-Content -LiteralPath $scriptPath -Raw

        $scriptText | Should -Match `
            'Merge-WebRedirectUri\s+`\s*-ExistingRedirectUri\s+\$existingRedirectUris'
    }
}

Describe 'Installer optional web client application' {
    BeforeAll {
        $installerPath = Join-Path $PSScriptRoot '..\Installer\Install-AutopilotImport.ps1'
        $tokens = $null
        $parseErrors = $null
        $installerAst = [Management.Automation.Language.Parser]::ParseFile(
            $installerPath,
            [ref] $tokens,
            [ref] $parseErrors
        )
        $redirectFunctionAst = $installerAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -in @(
                'Get-CustomWebRedirectUri',
                'Get-WebAppHostName',
                'Get-WebAppHostNameBinding'
            )
        }, $true)
        $redirectFunctionAst | ForEach-Object {
            Invoke-Expression $_.Extent.Text
        }
    }

    It 'does not pass a null client ID to the web application script' {
        $installerPath = Join-Path $PSScriptRoot '..\Installer\Install-AutopilotImport.ps1'
        $installer = Get-Content -LiteralPath $installerPath -Raw

        $installer | Should -Match `
            'if \(\$null -ne \$WebClientId -and \$WebClientId -ne \[guid\]::Empty\)'
        $installer | Should -Match `
            '\$webApplicationParameters\.ClientId = \$WebClientId'
        $installer | Should -Not -Match `
            '(?m)^\s*-ClientId \$WebClientId `\s*$'
    }

    It 'passes only nonempty custom-domain redirect URIs to the web application script' {
        $installer = Get-Content -LiteralPath $installerPath -Raw

        $installer | Should -Match `
            '@\(\$AdditionalWebRedirectUri\) \+ \$discoveredWebRedirectUris\s*\|\s*ForEach-Object[\s\S]*?\|\s*Where-Object'
        $installer | Should -Match `
            'if \(\$additionalRedirectUris\.Count -gt 0\)'
        $installer | Should -Match `
            '\$webApplicationParameters\.AdditionalRedirectUri = \$additionalRedirectUris'
        $installer | Should -Not -Match `
            'AdditionalRedirectUri\s*=\s*@\(\$AdditionalWebRedirectUri\)'
    }

    It 'discovers custom-domain redirects from an existing Function App' {
        $redirectUris = @(Get-CustomWebRedirectUri -HostName @(
                'func-example.azurewebsites.net'
                ' autopilot.example.com '
                'autopilot.example.com'
                ''
            ))

        $redirectUris | Should -Be @(
            'https://autopilot.example.com/api/ui/index.html'
        )
    }

    It 'handles missing and version-dependent Function App hostname properties' {
        @(Get-WebAppHostName -WebApp $null).Count | Should -Be 0
        @(Get-WebAppHostName -WebApp ([pscustomobject]@{
                    HostNames = @('direct.example.com')
                })) | Should -Be @('direct.example.com')
        @(Get-WebAppHostName -WebApp ([pscustomobject]@{
                    SiteConfig = [pscustomobject]@{
                        HostNames = @('site-config.example.com')
                    }
                })) | Should -Be @('site-config.example.com')
        @(Get-WebAppHostName -WebApp ([pscustomobject]@{
                    Properties = [pscustomobject]@{
                        HostNames = @('properties.example.com')
                        EnabledHostNames = @('enabled.example.com')
                        HostNameSslStates = @(
                            [pscustomobject]@{ Name = 'ssl.example.com' }
                        )
                    }
                })) | Should -Be @(
                    'properties.example.com'
                    'enabled.example.com'
                    'ssl.example.com'
                )
    }

    It 'discovers installer hostnames from Azure hostname bindings' {
        Mock Invoke-AzRestMethod {
            [pscustomobject]@{
                StatusCode = 200
                Content = @{
                    value = @(
                        @{ name = 'func-example/func-example.azurewebsites.net' }
                        @{ name = 'func-example/autopilot.example.com' }
                    )
                } | ConvertTo-Json -Depth 4
            }
        }

        $hostNames = @(Get-WebAppHostNameBinding `
                -ResourceId '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Web/sites/func-example')

        $hostNames | Should -Be @(
            'func-example.azurewebsites.net'
            'autopilot.example.com'
        )
    }

    It 'combines discovered and explicit redirects before configuring the SPA' {
        $installer = Get-Content -LiteralPath $installerPath -Raw

        $installer | Should -Match `
            'Get-AzWebApp\s+`\s*-ResourceGroupName\s+\$ResourceGroupName'
        $installer | Should -Match `
            'Get-WebAppHostName -WebApp \$existingFunctionApp'
        $installer | Should -Match `
            'Get-CustomWebRedirectUri -HostName \$existingFunctionAppHostNames'
        $installer | Should -Match `
            '@\(\$AdditionalWebRedirectUri\) \+ \$discoveredWebRedirectUris'
    }
}

Describe 'Installer packaged web frontend fallback' {
    BeforeAll {
        $installerPath = Join-Path $PSScriptRoot '..\Installer\Install-AutopilotImport.ps1'
        $tokens = $null
        $parseErrors = $null
        $installerAst = [Management.Automation.Language.Parser]::ParseFile(
            $installerPath,
            [ref] $tokens,
            [ref] $parseErrors
        )
        $functionAst = $installerAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Test-BuiltWebFrontend'
        }, $true) | Select-Object -First 1
        Invoke-Expression $functionAst.Extent.Text
    }

    It 'accepts the complete frontend bundle in the repository' {
        Test-BuiltWebFrontend -ProjectRoot (
            Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        ) |
            Should -BeTrue
    }

    It 'rejects a bundle whose index references a missing asset' {
        $webRoot = Join-Path $TestDrive 'WebFrontend\wwwroot'
        New-Item -Path $webRoot -ItemType Directory -Force | Out-Null
        Set-Content `
            -LiteralPath (Join-Path $webRoot 'index.html') `
            -Value '<script src="/api/ui/assets/missing.js"></script>'

        Test-BuiltWebFrontend -ProjectRoot $TestDrive | Should -BeFalse
    }

    It 'prefers a complete prebuilt bundle even when npm is installed' {
        $installer = Get-Content -LiteralPath $installerPath -Raw

        $installer | Should -Match `
            'if \(-not \$builtWebFrontendAvailable\) \{\s+Write-Host ''Building web frontend\.\.\.'''
        $installer | Should -Not -Match `
            'if \(\$npmCommand\) \{\s+Write-Host ''Building web frontend\.\.\.'''
    }

    It 'rebuilds the frontend in Azure CI only when its source changes' {
        $pipeline = Get-Content `
            -LiteralPath (Join-Path $PSScriptRoot '..\..\azure-pipelines.yml') `
            -Raw

        $pipeline | Should -Match `
            '(?s)git diff.*?HEAD\^.*?HEAD.*?src/Web.*?Detect web frontend changes'
        $pipeline | Should -Match `
            '(?s)Detect web frontend changes.*?Use Node\.js 22'
        $conditionMatches = [regex]::Matches(
            $pipeline,
            "condition: eq\(variables\['webFrontendChanged'\], 'true'\)"
        )
        $conditionMatches.Count | Should -Be 2
    }
}

Describe 'Installer web frontend readiness check' {
    BeforeAll {
        $installerPath = Join-Path $PSScriptRoot '..\Installer\Install-AutopilotImport.ps1'
        $tokens = $null
        $parseErrors = $null
        $installerAst = [Management.Automation.Language.Parser]::ParseFile(
            $installerPath,
            [ref] $tokens,
            [ref] $parseErrors
        )
        $functionAst = $installerAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-WebReadinessRequest'
        }, $true) | Select-Object -First 1
        Invoke-Expression $functionAst.Extent.Text
    }

    BeforeEach {
        $script:requestAttempt = 0
        Mock Start-Sleep
    }

    It 'retries a transient 404 until the published route is ready' {
        Mock Invoke-WebRequest {
            $script:requestAttempt++
            [pscustomobject]@{
                StatusCode = if ($script:requestAttempt -lt 3) { 404 } else { 200 }
            }
        }

        $response = Invoke-WebReadinessRequest `
            -Uri 'https://func.example/api/ui/index.html' `
            -RetryDelaySeconds 0

        $response.StatusCode | Should -Be 200
        Should -Invoke Invoke-WebRequest -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }

    It 'returns the final transient response after the attempt limit' {
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 404 } }

        $response = Invoke-WebReadinessRequest `
            -Uri 'https://func.example/api/ui/index.html' `
            -MaximumAttempts 2 `
            -RetryDelaySeconds 0

        $response.StatusCode | Should -Be 404
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }
}

Describe 'Installer Bicep bootstrap' {
    BeforeAll {
        $installerPath = Join-Path $PSScriptRoot '..\Installer\Install-AutopilotImport.ps1'
        $tokens = $null
        $parseErrors = $null
        $installerAst = [Management.Automation.Language.Parser]::ParseFile(
            $installerPath,
            [ref] $tokens,
            [ref] $parseErrors
        )
        $functionAst = $installerAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Install-BicepStandaloneCli'
        }, $true) | Select-Object -First 1
        Invoke-Expression $functionAst.Extent.Text
    }

    It 'downloads a non-empty standalone executable for the current architecture' {
        Mock Invoke-WebRequest {
            param($Uri, $OutFile)
            Set-Content -LiteralPath $OutFile -Value 'mock-bicep'
        }
        Mock Unblock-File
        $destinationPath = Join-Path $TestDrive 'Bicep CLI\bicep.exe'

        Install-BicepStandaloneCli -DestinationPath $destinationPath

        $destinationPath | Should -Exist
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -match `
                '^https://github\.com/Azure/bicep/releases/latest/download/bicep-win-(x64|arm64)\.exe$'
        }
    }

    It 'uses the standalone installer when winget is unavailable' {
        $installer = Get-Content `
            -LiteralPath (Join-Path $PSScriptRoot '..\Installer\Install-AutopilotImport.ps1') `
            -Raw

        $installer | Should -Match `
            '(?s)if \(\$winget\).*?else \{\s*Install-BicepStandaloneCli -DestinationPath \$knownPaths\[0\]'
        $installer | Should -Not -Match `
            'Bicep is missing and winget is not available'
    }
}

Describe 'Azure deployment permission validation' {
    BeforeAll {
        $installerPath = Join-Path $PSScriptRoot '..\Installer\Install-AutopilotImport.ps1'
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

        $errorRecord = {
            Assert-AzureDeploymentPermissions `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -ResourceGroupName 'rg-test' `
                -ResourceGroupExists
        } | Should -Throw -PassThru

        $errorRecord.Exception.Message | Should -Match `
            'Azure deployment permissions are insufficient'
        $errorRecord.Exception.Message | Should -Match `
            'Microsoft\.Authorization/roleAssignments/write'
        $errorRecord.Exception.Message | Should -Match `
            'Create or update Azure role assignments'
        $errorRecord.Exception.Message | Should -Match `
            'Contributor and Role Based Access Control Administrator'
        $errorRecord.Exception.Message | Should -Match `
            "Checked scope: /subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-test"
        $errorRecord.Exception.Data['MissingActions'] | Should -Be `
            'Microsoft.Authorization/roleAssignments/write'
        $errorRecord.Exception.Data[ `
            'AutopilotDeploymentPermissionError'] | Should -BeTrue
    }

    It 'requires permission to create the Log Analytics workspace' {
        Mock Invoke-AzRestMethod {
            [pscustomobject]@{
                StatusCode = 200
                Content = @{
                    value = @(@{
                        actions = @('*')
                        notActions = @(
                            'Microsoft.OperationalInsights/workspaces/write'
                        )
                    })
                } | ConvertTo-Json -Depth 5
            }
        }

        $errorRecord = {
            Assert-AzureDeploymentPermissions `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -ResourceGroupName 'rg-test' `
                -ResourceGroupExists
        } | Should -Throw -PassThru

        $errorRecord.Exception.Message | Should -Match `
            'Microsoft\.OperationalInsights/workspaces/write'
        $errorRecord.Exception.Message | Should -Match `
            'Create or update the Log Analytics workspace'
    }

    It 'recommends Contributor when only resource writes are missing' {
        Mock Invoke-AzRestMethod {
            [pscustomobject]@{
                StatusCode = 200
                Content = @{
                    value = @(@{
                        actions = @('*')
                        notActions = @('Microsoft.Web/sites/config/write')
                    })
                } | ConvertTo-Json -Depth 5
            }
        }

        $errorRecord = {
            Assert-AzureDeploymentPermissions `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -ResourceGroupName 'rg-test' `
                -ResourceGroupExists
        } | Should -Throw -PassThru

        $errorRecord.Exception.Message | Should -Match `
            'Microsoft\.Web/sites/config/write'
        $errorRecord.Exception.Message | Should -Match `
            'Assign Contributor or Owner'
        $errorRecord.Exception.Message | Should -Not -Match `
            'assign both Contributor'
    }

    It 'requires subscription scope when the resource group is missing' {
        Mock Invoke-AzRestMethod {
            [pscustomobject]@{
                StatusCode = 200
                Content = @{
                    value = @(@{
                        actions = @('*')
                        notActions = @(
                            'Microsoft.Resources/subscriptions/resourceGroups/write'
                        )
                    })
                } | ConvertTo-Json -Depth 5
            }
        }

        $errorRecord = {
            Assert-AzureDeploymentPermissions `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -ResourceGroupName 'rg-new'
        } | Should -Throw -PassThru

        $errorRecord.Exception.Message | Should -Match `
            'Microsoft\.Resources/subscriptions/resourceGroups/write'
        $errorRecord.Exception.Message | Should -Match `
            "subscription '/subscriptions/11111111-1111-1111-1111-111111111111', because the resource group does not exist"
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
        $installerPath = Join-Path $PSScriptRoot '..\Installer\Install-AutopilotImport.ps1'
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

Describe 'Installer Entra deployment diagnostics' {
    It 'distinguishes Microsoft Graph authorization from Azure RBAC failures' {
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $installer = Get-Content `
            -LiteralPath (Join-Path $projectRoot 'src\Installer\Install-AutopilotImport.ps1') `
            -Raw

        $installer | Should -Match 'Microsoft\\\.Graph'
        $installer | Should -Match 'graph\\\.microsoft\\\.com'
        $installer | Should -Match `
            'Application Administrator or Cloud Application Administrator'
        $installer | Should -Match `
            'Azure subscription or resource-group roles do not grant this permission'
        $installer | Should -Match `
            'Update-AutopilotImport\.ps1.*-ForceGraphSignIn'
        $installer | Should -Match `
            'Complete the device-code sign-in'
        $installer | Should -Match 'AutopilotGraphPermissionError'
        $installer | Should -Match "Data\['GraphAccount'\]"
        $installer | Should -Match "Data\['InstallerLogPath'\]"
    }

    It 'renders Graph permission guidance without a generic update error' {
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $updater = Get-Content `
            -LiteralPath (Join-Path $projectRoot 'src\Installer\Update-AutopilotImport.ps1') `
            -Raw

        $updater | Should -Match 'AutopilotGraphPermissionError'
        $updater | Should -Match `
            'Update stopped: Microsoft Entra permission required'
        $updater | Should -Match `
            'Rerun this update with -ForceGraphSignIn'
        $updater | Should -Match `
            '(?s)if \(\$isMicrosoftGraphPermissionError\).*?Write-Host.*?return'
    }

    It 'does not authenticate to Graph when Entra configuration is skipped' {
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $installer = Get-Content `
            -LiteralPath (Join-Path $projectRoot 'src\Installer\Install-AutopilotImport.ps1') `
            -Raw

        $installer | Should -Match `
            '(?s)elseif \(\$InstallerPrincipalId -eq \[guid\]::Empty\).*?else \{\s*\$installingUserObjectId = \$InstallerPrincipalId\s*Write-Host'
    }
}

Describe 'Installer Azure resource provider registration' {
    BeforeAll {
        $installerPath = Join-Path $PSScriptRoot '..\Installer\Install-AutopilotImport.ps1'
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
        $installerPath = Join-Path $PSScriptRoot '..\Installer\Install-AutopilotImport.ps1'
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

    It 'ignores null and malformed optional manager IDs' {
        $principal = [pscustomobject]@{
            claims = @(
                @{ typ = 'oid'; val = '33333333-3333-3333-3333-333333333333' }
            )
        }
        $policyWithEmptyManagers = [pscustomobject]@{
            installerPrincipalId   = '11111111-1111-1111-1111-111111111111'
            additionalPrincipalIds = @($null, '', 'not-a-guid')
        }

        Test-TagPolicyManagerPrincipal `
            -Principal $principal `
            -ManagerPolicy $policyWithEmptyManagers |
            Should -Be $false
    }
}

Describe 'Function version reporting' {
    It 'returns the deployed project version in management responses' {
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $managementFunction = Get-Content `
            -LiteralPath (Join-Path $projectRoot `
                'src\FunctionApp\ManageTagPolicy\run.ps1') `
            -Raw

        $managementFunction | Should -Match `
            '''X-AutopilotImport-Version''\s*=\s*\$functionVersion'
        ([regex]::Matches(
                $managementFunction,
                'functionVersion\s*=\s*\$functionVersion')).Count |
            Should -Be 2
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

    It 'ignores assignments without an expanded role definition' {
        $principal = [pscustomobject]@{
            claims = @(
                @{ typ = 'oid'; val = '11111111-1111-1111-1111-111111111111' }
            )
        }
        $assignments = @([pscustomobject]@{
            id      = 'assignment-without-role-definition'
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
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $template = Get-Content `
            -LiteralPath (Join-Path $projectRoot 'src\Infrastructure\main.bicep') `
            -Raw

        $template | Should -Not -Match 'requireInfrastructureEncryption'
    }
}

Describe 'Application Insights workspace infrastructure' {
    It 'creates and links Log Analytics in the Function resource group' {
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $template = Get-Content `
            -LiteralPath (Join-Path $projectRoot 'src\Infrastructure\main.bicep') `
            -Raw

        $template | Should -Match `
            "var logAnalyticsWorkspaceName = '\$\{functionAppName\}-la'"
        $template | Should -Match `
            "resource logAnalyticsWorkspace 'Microsoft\.OperationalInsights/workspaces@2023-09-01'"
        $template | Should -Match 'retentionInDays:\s*30'
        $template | Should -Match `
            "sku:\s*\{\s*name:\s*'PerGB2018'"
        $template | Should -Match `
            'WorkspaceResourceId:\s*logAnalyticsWorkspace\.id'
    }
}

Describe 'Updater web client ID fallback' {
    It 'checks whether WebClientId was supplied before comparing it as a GUID' {
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $updater = Get-Content `
            -LiteralPath (Join-Path $projectRoot 'src\Installer\Update-AutopilotImport.ps1') `
            -Raw

        $updater | Should -Match `
            '\$PSBoundParameters\.ContainsKey\(''WebClientId''\)\s+-and\s+\$WebClientId -ne \[guid\]::Empty'
    }
}

Describe 'Setup activity logging' {
    It 'logs installation and update activity in the temporary directory' {
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

        foreach ($scriptName in @(
                'Install-AutopilotImport.ps1'
                'Update-AutopilotImport.ps1'
            )) {
            $content = Get-Content `
                -LiteralPath (Join-Path `
                    $projectRoot `
                    "src\Installer\$scriptName") `
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
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $installer = Get-Content `
            -LiteralPath (Join-Path $projectRoot 'src\Installer\Install-AutopilotImport.ps1') `
            -Raw
        $update = Get-Content `
            -LiteralPath (Join-Path $projectRoot 'src\Installer\Update-AutopilotImport.ps1') `
            -Raw

        $installer | Should -Match `
            'Intune-Autopilotimport-install-.+NewGuid'
        $update | Should -Match `
            'Intune-Autopilotimport-update-.+NewGuid'
        $installer | Should -Not -Match 'INTUNE_AUTOPILOTIMPORT_SETUP_LOG'
        $update | Should -Not -Match 'INTUNE_AUTOPILOTIMPORT_SETUP_LOG'
    }
}

Describe 'Web frontend response types' {
    BeforeAll {
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $managementFunctionPath = Join-Path $projectRoot `
            'src\FunctionApp\ManageTagPolicy\run.ps1'
        $tokens = $null
        $parseErrors = $null
        $managementFunctionAst = `
            [Management.Automation.Language.Parser]::ParseFile(
                $managementFunctionPath,
                [ref] $tokens,
                [ref] $parseErrors
            )
        $parseErrors.Count | Should -Be 0
        foreach ($functionName in @(
                'Get-SubmittedTagPolicyRules'
                'ConvertTo-SubmittedTagPolicy'
            'Assert-SubmittedAdministrativeUnitsExist'
            )) {
            $functionAst = $managementFunctionAst.FindAll({
                param($node)
                $node -is `
                    [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
            }, $true) | Select-Object -First 1
            Invoke-Expression $functionAst.Extent.Text
        }
    }

    It 'keeps the device hash card level at every viewport width' {
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $style = Get-Content `
            -LiteralPath (Join-Path $projectRoot 'src\Web\src\style.css') `
            -Raw

        $style | Should -Not -Match 'transform:\s*rotate\('
    }

    It 'serves textual assets as strings so Azure preserves their MIME types' {
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $frontendFunction = Get-Content `
            -LiteralPath (Join-Path $projectRoot 'src\FunctionApp\WebFrontend\run.ps1') `
            -Raw

        $frontendFunction | Should -Match `
            "\$textExtensions = @\('\.html', '\.js', '\.css', '\.svg', '\.json'\)"
        $frontendFunction | Should -Match `
            '\[IO\.File\]::ReadAllText\(\$resolvedPath, \[Text\.Encoding\]::UTF8\)'
        $frontendFunction | Should -Match `
            "'\.html' = 'text/html; charset=utf-8'"
        $frontendFunction | Should -Match `
            "'\.js'\s+= 'text/javascript; charset=utf-8'"
        $frontendFunction | Should -Match `
            'ContentType\s*=\s*\$ContentType'
        $frontendFunction | Should -Not -Match `
            "Headers\['Content-Type'\]"
    }

    It 'uses the requested HTTPS origin for custom domain runtime URLs' {
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $frontendFunction = Get-Content `
            -LiteralPath (Join-Path $projectRoot 'src\FunctionApp\WebFrontend\run.ps1') `
            -Raw

        $frontendFunction | Should -Match `
            '\$Request\.Url'
        $frontendFunction | Should -Match `
            'GetLeftPart\(\[UriPartial\]::Authority\)'
        $frontendFunction | Should -Match `
            'redirectUri\s*=\s*"\$origin/api/ui/index\.html"'
        $frontendFunction | Should -Match `
            'importUrl\s*=\s*"\$origin/api/devices/import"'
    }

    It 'redirects the Function hostname root while preserving existing API URLs' {
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $hostConfiguration = Get-Content `
            -LiteralPath (Join-Path $projectRoot 'src\FunctionApp\host.json') `
            -Raw |
            ConvertFrom-Json

        $hostConfiguration.extensions.http.routePrefix | Should -Be ''
        $infrastructure = Get-Content `
            -LiteralPath (Join-Path $projectRoot 'src\Infrastructure\main.bicep') `
            -Raw
        $infrastructure | Should -Match `
            "name:\s*'AzureWebJobsDisableHomepage'\s+value:\s*'true'"
        $infrastructure | Should -Match `
            "name:\s*'AzureWebJobsFeatureFlags'\s+value:\s*'EnableProxies'"
        $expectedRoutes = @{
            'ImportDevice'      = 'api/devices/import'
            'GetAuthorizedTags' = 'api/devices/tags'
            'GetImportHistory'  = 'api/management/imports'
            'ManageTagPolicy'   = 'api/management/tag-policy'
            'WebFrontend'       = 'api/ui/{*path}'
        }
        foreach ($functionName in $expectedRoutes.Keys) {
            $functionConfiguration = Get-Content `
                -LiteralPath (Join-Path `
                    $projectRoot `
                    "src\FunctionApp\$functionName\function.json") `
                -Raw |
                ConvertFrom-Json
            $httpTrigger = @($functionConfiguration.bindings | Where-Object {
                $_.type -eq 'httpTrigger'
            }) | Select-Object -First 1

            $httpTrigger.route | Should -Be $expectedRoutes[$functionName]
        }

        $proxyConfiguration = Get-Content `
            -LiteralPath (Join-Path $projectRoot 'src\FunctionApp\proxies.json') `
            -Raw |
            ConvertFrom-Json
        $rootProxy = $proxyConfiguration.proxies.RootRedirect
        $rootProxy.matchCondition.methods | Should -Be 'GET'
        $rootProxy.matchCondition.route | Should -Be '/'
        $rootProxy.responseOverrides.'response.statusCode' | Should -Be '302'
        $rootProxy.responseOverrides.'response.headers.Location' |
            Should -Be '/api/ui/index.html'
    }

    It 'extracts policy rules from Functions dictionary request bodies' {
        $groupId = '11111111-1111-1111-1111-111111111111'
        $requestBody = [ordered]@{
            policy = @([ordered]@{
                groupId = $groupId
                tags = @('BG-Default')
            })
        }
        $submittedRules = @(
            Get-SubmittedTagPolicyRules -Body $requestBody
        )

        $submittedRules.Count | Should -Be 1
        $submittedRules[0].groupId | Should -Be $groupId
        $submittedRules[0].tags | Should -Be 'BG-Default'
        {
            ConvertTo-TagAuthorizationPolicy -Rules $submittedRules
        } | Should -Not -Throw
    }

    It 'applies an RMAU only to the rule that declares it' {
        $policy = @(ConvertTo-SubmittedTagPolicy -Rules @(
            [ordered]@{
                groupId = '11111111-1111-1111-1111-111111111111'
                tags = @('BG-Default', 'PAW')
            }
            [ordered]@{
                groupId = '22222222-2222-2222-2222-222222222222'
                tags = @('BG-Default')
            }
            [ordered]@{
                groupId = '33333333-3333-3333-3333-333333333333'
                tags = @('BG-Default')
                administrativeUnitName = 'BG-Devices'
            }
        ))

        $policy.Count | Should -Be 3
        @($policy | Where-Object {
            $_.PSObject.Properties[
                'administrativeUnitName']
        }).Count | Should -Be 1
        $policy[2].administrativeUnitName |
            Should -Be 'BG-Devices'
    }

    It 'validates each configured administrative unit once' {
        Mock Resolve-EntraAdministrativeUnit {
            [pscustomobject]@{ id = [guid]::NewGuid().ToString() }
        }
        $policy = @(ConvertTo-SubmittedTagPolicy -Rules @(
            [ordered]@{
                groupId = '11111111-1111-1111-1111-111111111111'
                tags = @('BG-Default')
                administrativeUnitName = 'Devices'
            }
            [ordered]@{
                groupId = '22222222-2222-2222-2222-222222222222'
                tags = @('Kiosk')
                administrativeUnitName = 'Devices'
            }
        ))

        Assert-SubmittedAdministrativeUnitsExist `
            -Policy $policy `
            -AccessToken (ConvertTo-SecureString 'token' -AsPlainText -Force)

        Should -Invoke Resolve-EntraAdministrativeUnit `
            -ParameterFilter { $AdministrativeUnitName -eq 'Devices' } `
            -Times 1
    }

    It 'rejects a policy when its administrative unit does not exist' {
        Mock Resolve-EntraAdministrativeUnit {
            throw "Administrative unit 'Missing' was not found."
        }
        $policy = @(ConvertTo-SubmittedTagPolicy -Rules @(
            [ordered]@{
                groupId = '11111111-1111-1111-1111-111111111111'
                tags = @('BG-Default')
                administrativeUnitName = 'Missing'
            }
        ))

        {
            Assert-SubmittedAdministrativeUnitsExist `
                -Policy $policy `
                -AccessToken (ConvertTo-SecureString 'token' `
                    -AsPlainText -Force)
        } | Should -Throw "*Administrative unit 'Missing' was not found*"
    }

    It 'retains the legacy rules property for object request bodies' {
        $requestBody = [pscustomobject]@{
            rules = @('11111111-1111-1111-1111-111111111111=Standard')
        }

        $submittedRules = @(
            Get-SubmittedTagPolicyRules -Body $requestBody
        )

        $submittedRules | Should -Be `
            '11111111-1111-1111-1111-111111111111=Standard'
    }
}

Describe 'OOBE web importer helper script' {
    BeforeAll {
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $helperPath = Join-Path $projectRoot `
            'src\Scripts\Start-IntuneAutopilotImporter.ps1'
        $tokens = $null
        $parseErrors = $null
        $helperAst = [Management.Automation.Language.Parser]::ParseFile(
            $helperPath,
            [ref] $tokens,
            [ref] $parseErrors
        )
        $parseErrors.Count | Should -Be 0
        foreach ($functionName in @(
                'Resolve-AutoPilotImporterWebUrl'
                'Get-AutoPilotImporterConfigUrl'
            )) {
            $functionAst = $helperAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
            }, $true) | Select-Object -First 1
            Invoke-Expression $functionAst.Extent.Text
        }
    }

    It 'has valid PowerShell Gallery metadata matching the project version' {
        $scriptInfo = Test-ScriptFileInfo -Path $helperPath
        $projectVersion = (Get-Content `
            -LiteralPath (Join-Path $projectRoot 'VERSION') `
            -Raw).Trim()

        $scriptInfo.Name | Should -Be 'Start-IntuneAutopilotImporter'
        [string] $scriptInfo.Version | Should -Be $projectVersion
        $scriptInfo.ProjectUri | Should -Be `
            'https://github.com/anluca_microsoft/Intune-Autopilotimporter'
    }

    It 'normalizes a Function App root URL to the frontend page' {
        $webUrl = Resolve-AutoPilotImporterWebUrl `
            -Url 'https://func-example.azurewebsites.net'

        $webUrl.AbsoluteUri | Should -Be `
            'https://func-example.azurewebsites.net/api/ui/index.html'
        (Get-AutoPilotImporterConfigUrl -WebUri $webUrl).AbsoluteUri |
            Should -Be `
                'https://func-example.azurewebsites.net/api/ui/config'
    }

    It 'rejects an insecure frontend URL' {
        {
            Resolve-AutoPilotImporterWebUrl `
                -Url 'http://func-example.azurewebsites.net'
        } | Should -Throw '*absolute HTTPS URL*'
    }
}

Describe 'Project metadata entries' {
    BeforeAll {
        $packageScriptPath = Join-Path `
            $PSScriptRoot `
            '..\Scripts\New-DeploymentPackage.ps1'
        $tokens = $null
        $parseErrors = $null
        $packageAst = [Management.Automation.Language.Parser]::ParseFile(
            $packageScriptPath,
            [ref] $tokens,
            [ref] $parseErrors
        )
        $parseErrors.Count | Should -Be 0
        foreach ($functionName in @(
                'Assert-BuiltWebFrontend'
                'Assert-ProjectVersionConsistency'
            )) {
            $functionAst = $packageAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
            }, $true) | Select-Object -First 1
            Invoke-Expression $functionAst.Extent.Text
        }
    }

    It 'accepts a prebuilt web frontend with an independent version' {
        $webRoot = Join-Path $TestDrive 'WebFrontend\wwwroot'
        $assetRoot = Join-Path $webRoot 'assets'
        New-Item -Path $assetRoot -ItemType Directory -Force | Out-Null
        Set-Content `
            -LiteralPath (Join-Path $webRoot 'index.html') `
            -Value '<script type="module" src="/api/ui/assets/index-test.js"></script>'
        Set-Content `
            -LiteralPath (Join-Path $assetRoot 'index-test.js') `
            -Value 'const version = "1.0.20260902.1";'

        { Assert-BuiltWebFrontend -Root $TestDrive } | Should -Not -Throw
    }

    It 'rejects a PowerShell marker that differs from the central version' {
        $projectRoot = Join-Path $TestDrive 'version-mismatch'
        $manifestRoot = Join-Path `
            $projectRoot `
            'src\AutopilotImport.Client'
        New-Item -Path $manifestRoot -ItemType Directory -Force | Out-Null
        Set-Content `
            -LiteralPath (Join-Path $projectRoot 'Install.ps1') `
            -Value '# Project-Version: 1.0.20260902.1'
        Set-Content `
            -LiteralPath (Join-Path `
                $manifestRoot `
                'AutopilotImport.Client.psd1') `
            -Value @(
                '# Project-' + 'Version: 1.1.20260911.1'
                '@{'
                "    ModuleVersion = '1.1.20260911.1'"
                '}'
            )

        {
            Assert-ProjectVersionConsistency `
                -Root $projectRoot `
                -ProjectVersion '1.1.20260911.1'
        } | Should -Throw '*uses project version 1.0.20260902.1 instead of 1.1.20260911.1*'
    }

    It 'uses the central version in every PowerShell file' {
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $projectVersion = (Get-Content (Join-Path $projectRoot 'VERSION') -Raw).Trim()
        $projectVersion | Should -Match '^1\.1\.\d{8}\.\d+$'

        $powerShellFiles = @(
            Get-ChildItem -LiteralPath $projectRoot -Recurse -File |
                Where-Object {
                    $_.Extension -in '.ps1', '.psm1', '.psd1' -and
                    $_.FullName -notmatch '[\\/]web[\\/]node_modules[\\/]'
                }
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
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $projectVersion = (Get-Content `
            (Join-Path $projectRoot 'VERSION') `
            -Raw).Trim()
        $manifest = Import-PowerShellDataFile `
            (Join-Path $projectRoot `
                'src\AutopilotImport.Client\AutopilotImport.Client.psd1')

        [string] $manifest.ModuleVersion | Should -Be $projectVersion
    }

    It 'updates PowerShell Gallery script metadata with the project version' {
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $versionScript = Get-Content `
            -LiteralPath (Join-Path $projectRoot `
                'src\Scripts\Update-ProjectVersion.ps1') `
            -Raw

        $versionScript | Should -Match 'scriptInfoVersionPattern'
        $versionScript | Should -Match 'PSScriptInfo VERSION entry'
        $versionScript | Should -Match `
            '\(''\$\{1\}'' \+ \$newVersion\)'
    }

    It 'excludes dependency and generated directories from version updates' {
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $versionScript = Get-Content `
            -LiteralPath (Join-Path $projectRoot `
                'src\Scripts\Update-ProjectVersion.ps1') `
            -Raw

        $versionScript | Should -Match `
            '\(\?:node_modules\|InstallationPackage\|\\\.git\)'
    }

    It 'uses the central author in every PowerShell file' {
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $projectAuthor = (Get-Content (Join-Path $projectRoot 'AUTHOR') -Raw).Trim()

        $powerShellFiles = @(
            Get-ChildItem -LiteralPath $projectRoot -Recurse -File |
                Where-Object {
                    $_.Extension -in '.ps1', '.psm1', '.psd1' -and
                    $_.FullName -notmatch '[\\/]web[\\/]node_modules[\\/]'
                }
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
    It 'does not define GitHub Actions workflows' {
        $workflowRoot = Join-Path $PSScriptRoot '..\..\.github\workflows'
        $workflowFiles = @(Get-ChildItem `
            -LiteralPath $workflowRoot `
            -File `
            -ErrorAction SilentlyContinue)

        $workflowFiles.Count | Should -Be 0
    }

    It 'requires History.md and VERSION in every pushed first-parent commit' {
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $historyCheck = Get-Content `
            -LiteralPath (Join-Path $projectRoot `
                'src\Scripts\Test-ChangeHistory.ps1') `
            -Raw

        $historyCheck | Should -Match `
            "'rev-list', '--reverse', '--first-parent'"
        $historyCheck | Should -Match `
            "'diff-tree', '--root', '--no-commit-id', '--name-only'"
        $historyCheck | Should -Match `
            "'History.md', 'VERSION'"
        $historyCheck | Should -Match `
            '\$changedPaths -notcontains \$_'
        $historyCheck | Should -Match `
            'History\.md must contain exactly one section for'
        $historyCheck | Should -Match `
            '\$_\.EndsWith\(" - \$versionDate"\)'
        $historyCheck | Should -Match `
            '\$dateHeadings\[0\] -cne \$expectedHeading'
        $historyCheck | Should -Match '\\\[skip ci\\\]'
    }

    It 'publishes a package for every branch in Azure Pipelines' {
        $pipelinePath = Join-Path $PSScriptRoot '..\..\azure-pipelines.yml'
        $pipeline = Get-Content -LiteralPath $pipelinePath -Raw

        $pipeline | Should -Match `
            "(?ms)^trigger:\s+branches:\s+include:\s+- '\*'\s*$"
        $pipeline | Should -Match `
            '(?m)^\s+displayName: Require change history and version update\s*$'
        $pipeline | Should -Match `
            '(?m)^\s+\./src/Scripts/Test-ChangeHistory\.ps1 `\s*$'
        $pipeline | Should -Match `
            '(?m)^\s+displayName: Build deployment package\s*$'
        $pipeline | Should -Match `
            '(?m)^\s+displayName: Publish deployment package\s*$'
        $pipeline | Should -Match `
            '(?m)^\s+SOURCE_BRANCH: \$\(Build\.SourceBranch\)\s*$'
        $pipeline | Should -Match `
            '(?m)^\s+condition: and\(succeeded\(\), eq\(variables\[''Build\.SourceBranch''\], ''refs/heads/main''\)\)\s*$'
    }

    It 'contains installation and runtime files without local configuration' {
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $outputDirectory = Join-Path $TestDrive 'InstallationPackage'
        $package = & (Join-Path `
            $projectRoot `
            'src\Scripts\New-DeploymentPackage.ps1') `
            -ProjectRoot $projectRoot `
            -OutputDirectory $outputDirectory `
            -BranchName 'feature/tag-policy'
        $packageRoot = "Intune-autopilotImporter-feature-tag-policy$((Get-Content `
            -LiteralPath (Join-Path $projectRoot 'VERSION') `
            -Raw).Trim())"

        $package.Name | Should -Be "$packageRoot.zip"

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($package.FullName)
        try {
            $entries = @($archive.Entries.FullName)
            foreach ($requiredEntry in @(
                    'History.md'
                    'README.md'
                    'Install-AutopilotImport.ps1'
                    'Update-AutopilotImport.ps1'
                    'infra/main.bicep'
                    'src/AutopilotImport/AutopilotImport.psm1'
                    'src/AutopilotImport.Client/AutopilotImport.Client.psd1'
                    'scripts/Ensure-EntraApiApplication.ps1'
                    'scripts/Ensure-EntraWebApplication.ps1'
                    'scripts/Grant-ManagedIdentityGraphPermission.ps1'
                    'scripts/Import-AutopilotDevice.ps1'
                    'scripts/Start-IntuneAutopilotImporter.ps1'
                    'scripts/Set-TagAuthorizationPolicy.ps1'
                    'scripts/Set-TagPolicyManagers.ps1'
                    'GetAuthorizedTags/function.json'
                    'GetImportHistory/function.json'
                    'GetImportHistory/run.ps1'
                    'RemoveExpiredImportHistory/function.json'
                    'RemoveExpiredImportHistory/run.ps1'
                    'proxies.json'
                    'WebFrontend/function.json'
                    'WebFrontend/wwwroot/index.html'
                    'web/package.json'
                    'web/src/main.ts'
                )) {
                $entries | Should -Contain "$packageRoot/$requiredEntry"
            }
            $entries | Where-Object {
                $_ -match '/WebFrontend/wwwroot/assets/.+\.(css|js)$'
            } | Should -Not -BeNullOrEmpty
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