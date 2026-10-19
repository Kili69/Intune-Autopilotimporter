# Project-Version: 1.4.20261019.7
# Author: andreas.lucas@outlook.com (aka Kili)

Import-Module (Join-Path $PSScriptRoot '..\Scripts\FunctionDeployment.psm1') -Force

BeforeAll {
    Import-Module Az.Accounts
    $functionRoot = Join-Path $PSScriptRoot '..\FunctionApp'
}

Describe 'Flex hosting selection' {
    InModuleScope FunctionDeployment {
        BeforeAll {
            if (-not (Get-Command Invoke-AzRestMethod -ErrorAction SilentlyContinue)) {
                function Invoke-AzRestMethod { [CmdletBinding(SupportsShouldProcess)] param($Method, $Path) }
            }
        }
        BeforeEach {
            Mock Invoke-AzRestMethod { @{ StatusCode = 200; Content = '{"sku":{"name":"Y1"},"properties":{"reserved":false}}' } }
        }
        It 'uses Flex for a new installation without reading a plan' {
            Get-AutopilotDeploymentHostingMode -ExistingFunctionApp $null | Should -Be 'FlexConsumption'
            Should -Invoke Invoke-AzRestMethod -Times 0
        }
        It 'preserves existing Windows Consumption hosting' {
            Get-AutopilotDeploymentHostingMode -ExistingFunctionApp @{ ServerFarmId = '/plans/old' } |
                Should -Be 'Consumption'
        }
        It 'recognizes an existing Linux Flex app' {
            Mock Invoke-AzRestMethod { @{ StatusCode = 200; Content = '{"sku":{"name":"FC1"},"properties":{"reserved":true}}' } }
            Get-AutopilotDeploymentHostingMode -ExistingFunctionApp @{ ServerFarmId = '/plans/flex' } |
                Should -Be 'FlexConsumption'
            Should -Invoke Invoke-AzRestMethod -Times 1 -ParameterFilter {
                $Path -eq '/plans/flex?api-version=2024-11-01' -and $ErrorAction -eq 'Stop'
            }
        }
        It 'does not convert an unsupported existing plan' -ForEach @(
            @{ Sku = 'EP1'; Reserved = $false }
            @{ Sku = 'Y1'; Reserved = $true }
            @{ Sku = 'FC1'; Reserved = $false }
        ) {
            Mock Invoke-AzRestMethod { @{
                StatusCode = 200
                Content = (ConvertTo-Json -InputObject @{ sku = @{ name = $Sku }; properties = @{ reserved = $Reserved } })
            } }
            { Get-AutopilotDeploymentHostingMode -ExistingFunctionApp @{ ServerFarmId = '/plans/existing' } } |
                Should -Throw '*explicit migration*'
        }
        It 'aborts on an unreadable plan rather than selecting a default' {
            Mock Invoke-AzRestMethod { @{ StatusCode = 403; Content = '{}' } }
            { Get-AutopilotDeploymentHostingMode -ExistingFunctionApp @{ ServerFarmId = '/plans/existing' } } |
                Should -Throw '*HTTP 403*'
        }
        It 'aborts when the existing plan identity is missing' {
            { Get-AutopilotDeploymentHostingMode -ExistingFunctionApp @{ ServerFarmId = '' } } |
                Should -Throw '*missing*'
        }
    }
}

Describe 'Hosting-specific Function runtime archive' {
    BeforeEach {
        Mock Save-AutopilotRuntimeDependencies -ModuleName FunctionDeployment {
            param($FunctionAppRoot, $DestinationPath)
            $path = Join-Path $DestinationPath 'Az.Accounts\4.2.0'
            [IO.Directory]::CreateDirectory($path) | Out-Null
            "@{ ModuleVersion = '4.2.0' }" | Set-Content -LiteralPath (Join-Path $path 'Az.Accounts.psd1')
        }
    }
    It 'bundles dependencies and disables managed dependency downloads only for Flex' {
        $package = New-AutopilotFunctionPackage -FunctionAppRoot $functionRoot `
            -DestinationPath (Join-Path $TestDrive 'flex.zip') -HostingMode FlexConsumption
        $zip = [IO.Compression.ZipFile]::OpenRead($package.FullName)
        try {
            $names = @($zip.Entries.FullName)
            $names | Should -Contain 'Modules/Az.Accounts/4.2.0/Az.Accounts.psd1'
            $names | Should -Contain 'RootRedirect/function.json'
            $names | Should -Not -Contain 'proxies.json'
            $names | Should -Contain 'GetImportHistory/run.ps1'
            $names | Should -Not -Contain 'client.settings.json'
            $reader = [IO.StreamReader]::new($zip.GetEntry('host.json').Open())
            try { ($reader.ReadToEnd() | ConvertFrom-Json).managedDependency.enabled | Should -BeFalse }
            finally { $reader.Dispose() }
        }
        finally { $zip.Dispose() }
        Should -Invoke Save-AutopilotRuntimeDependencies -ModuleName FunctionDeployment -Times 1
        (Get-Content -LiteralPath (Join-Path $functionRoot 'host.json') -Raw | ConvertFrom-Json).managedDependency.enabled |
            Should -BeTrue
    }
    It 'retains the legacy runtime package and proxy without downloading modules' {
        $package = New-AutopilotFunctionPackage -FunctionAppRoot $functionRoot `
            -DestinationPath (Join-Path $TestDrive 'legacy.zip') -HostingMode Consumption
        $zip = [IO.Compression.ZipFile]::OpenRead($package.FullName)
        try {
            $names = @($zip.Entries.FullName)
            $names | Should -Contain 'proxies.json'
            $names | Should -Not -Contain 'RootRedirect/function.json'
            @($names | Where-Object { $_ -like 'Modules/*' }).Count | Should -Be 0
            $reader = [IO.StreamReader]::new($zip.GetEntry('host.json').Open())
            try { ($reader.ReadToEnd() | ConvertFrom-Json).managedDependency.enabled | Should -BeTrue }
            finally { $reader.Dispose() }
        }
        finally { $zip.Dispose() }
        Should -Invoke Save-AutopilotRuntimeDependencies -ModuleName FunctionDeployment -Times 0
    }
    It 'fails explicitly when a required runtime entry is absent' {
        { New-AutopilotFunctionPackage -FunctionAppRoot $TestDrive `
                -DestinationPath (Join-Path $TestDrive 'broken.zip') -HostingMode FlexConsumption } |
            Should -Throw '*entry is missing*'
    }
}

Describe 'Flex runtime module provisioning' {
    InModuleScope FunctionDeployment {
        BeforeAll {
            if (-not (Get-Command Save-PSResource -ErrorAction SilentlyContinue)) {
                function Save-PSResource { [CmdletBinding()] param($Name, $Version, $Repository, $Path, [switch] $TrustRepository) }
            }
        }
        BeforeEach {
            $root = Join-Path $TestDrive 'source'
            $destination = Join-Path $TestDrive 'Modules'
            [IO.Directory]::CreateDirectory($root) | Out-Null
            [IO.Directory]::CreateDirectory($destination) | Out-Null
            "@{ 'Az.Accounts' = '4.*' }" | Set-Content -LiteralPath (Join-Path $root 'requirements.psd1')
            Mock Get-Module { @() }
            Mock Save-PSResource {
                $saved = Join-Path $Path 'Az.Accounts\4.2.0'
                [IO.Directory]::CreateDirectory($saved) | Out-Null
                "@{ ModuleVersion = '4.2.0' }" | Set-Content -LiteralPath (Join-Path $saved 'Az.Accounts.psd1')
            }
        }
        It 'saves the declared runtime version instead of whichever Az version the installer uses' {
            Save-AutopilotRuntimeDependencies -FunctionAppRoot $root -DestinationPath $destination
            Should -Invoke Save-PSResource -Times 1 -ParameterFilter {
                $Name -eq 'Az.Accounts' -and $Version -eq '4.*' -and $Repository -eq 'PSGallery' -and
                $TrustRepository -and $ErrorAction -eq 'Stop'
            }
            Test-Path -LiteralPath (Join-Path $destination 'Az.Accounts\4.2.0\Az.Accounts.psd1') | Should -BeTrue
        }
        It 'does not silently continue when the runtime dependency download fails' {
            Mock Save-PSResource { throw 'Gallery unavailable' }
            { Save-AutopilotRuntimeDependencies -FunctionAppRoot $root -DestinationPath $destination } |
                Should -Throw 'Gallery unavailable'
        }
        It 'copies a compatible installed module without downloading it' {
            $installed = Join-Path $TestDrive 'installed'
            [IO.Directory]::CreateDirectory($installed) | Out-Null
            "@{ ModuleVersion = '4.2.0' }" | Set-Content -LiteralPath (Join-Path $installed 'Az.Accounts.psd1')
            Mock Get-Module { [pscustomobject]@{ Version = [version]'4.2.0'; ModuleBase = $installed } }
            Save-AutopilotRuntimeDependencies -FunctionAppRoot $root -DestinationPath $destination
            Should -Invoke Save-PSResource -Times 0
            Test-Path -LiteralPath (Join-Path $destination 'Az.Accounts\4.2.0\Az.Accounts.psd1') | Should -BeTrue
        }
    }
}

Describe 'Flex OneDeploy publication' {
    InModuleScope FunctionDeployment {
        BeforeAll {
            if (-not (Get-Command Get-AzWebApp -ErrorAction SilentlyContinue)) {
                function Get-AzWebApp { [CmdletBinding()] param($ResourceGroupName, $Name) }
            }
        }
        BeforeEach {
            $id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            Mock Get-AzWebApp { [pscustomobject]@{ EnabledHostNames = @('app.azurewebsites.net', 'app-hash.scm.westeurope-01.azurewebsites.net') } }
            Mock Get-AzAccessToken { [pscustomobject]@{ Token = (ConvertTo-SecureString 'test' -AsPlainText -Force) } }
            Mock Invoke-WebRequest {
                if ($Method -eq 'POST') { @{ StatusCode = 202; Content = $id } }
                else { @{ StatusCode = 200; Content = '{"status":4}' } }
            }
            Mock Start-Sleep {}
        }
        It 'uses OneDeploy with bearer authentication and polls the exact unmodified deployment ID' {
            Publish-AutopilotFlexPackage -ResourceGroupName rg -FunctionAppName app -ArchivePath package.zip
            Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter {
                $Method -eq 'POST' -and
                $Uri -match '^https://app-hash\.scm\.westeurope-01\.azurewebsites\.net/api/publish\?RemoteBuild=false&Deployer=AutopilotImport-[a-f0-9]{32}$' -and
                $Authentication -eq 'Bearer' -and $Token -is [Security.SecureString] -and $InFile -eq 'package.zip'
            }
            Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter {
                $Method -eq 'GET' -and $Uri -eq "https://app-hash.scm.westeurope-01.azurewebsites.net/api/deployments/$id"
            }
        }
        It 'does not report accepted or failed publication as success' -ForEach @(
            @{ Status = -1 }; @{ Status = 3 }; @{ Status = 5 }; @{ Status = 6 }
        ) {
            Mock Invoke-WebRequest {
                if ($Method -eq 'POST') { @{ StatusCode = 202; Content = $id } }
                else { @{ StatusCode = 200; Content = "{`"status`":$Status}" } }
            }
            { Publish-AutopilotFlexPackage -ResourceGroupName rg -FunctionAppName app -ArchivePath package.zip } |
                Should -Throw '*failed or was cancelled*'
        }
        It 'decodes a binary response body without losing the exact deployment ID' {
            Mock Invoke-WebRequest {
                if ($Method -eq 'POST') { @{ StatusCode = 202; Content = [Text.Encoding]::UTF8.GetBytes($id) } }
                else { @{ StatusCode = 200; Content = '{"status":4}' } }
            }
            Publish-AutopilotFlexPackage -ResourceGroupName rg -FunctionAppName app -ArchivePath package.zip
            Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter {
                $Method -eq 'GET' -and $Uri -eq "https://app-hash.scm.westeurope-01.azurewebsites.net/api/deployments/$id"
            }
        }
        It 'correlates an ID-less upload with its unique deployer before accepting success' {
            Mock Invoke-WebRequest {
                if ($Method -eq 'POST') {
                    $script:acceptedDeployer = ($Uri -split '&Deployer=')[1]
                    @{ StatusCode = 202; Content = '' }
                } else {
                    @{ StatusCode = 200; Content = (ConvertTo-Json @{
                        status = 4; deployer = $script:acceptedDeployer; received_time = [datetimeoffset]::UtcNow.ToString('o')
                    }) }
                }
            }
            Publish-AutopilotFlexPackage -ResourceGroupName rg -FunctionAppName app -ArchivePath package.zip
            Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*/api/deployments/latest' }
        }
        It 'aborts on an ongoing deployment without retrying the upload' {
            Mock Invoke-WebRequest { @{ StatusCode = 409; Content = 'Conflict' } }
            { Publish-AutopilotFlexPackage -ResourceGroupName rg -FunctionAppName app -ArchivePath package.zip } |
                Should -Throw '*HTTP 409*'
            Should -Invoke Invoke-WebRequest -Times 1
        }
        It 'times out explicitly if publication never reaches a confirmed success state' {
            Mock Invoke-WebRequest {
                if ($Method -eq 'POST') { @{ StatusCode = 202; Content = $id } }
                else { @{ StatusCode = 200; Content = '{"status":1}' } }
            }
            { Publish-AutopilotFlexPackage -ResourceGroupName rg -FunctionAppName app -ArchivePath package.zip `
                    -MaximumPollAttempts 2 -PollIntervalSeconds 0 } | Should -Throw '*did not confirm success*'
            Should -Invoke Start-Sleep -Times 1
        }
        It 'does not accept a previous successful deployment when the response has no ID' {
            Mock Invoke-WebRequest {
                if ($Method -eq 'POST') { @{ StatusCode = 202; Content = '' } }
                else { @{ StatusCode = 200; Content = (ConvertTo-Json @{
                    status = 4; deployer = 'AutopilotImport'; received_time = [datetimeoffset]::UtcNow.ToString('o')
                }) } }
            }
            { Publish-AutopilotFlexPackage -ResourceGroupName rg -FunctionAppName app -ArchivePath package.zip `
                    -MaximumPollAttempts 1 -PollIntervalSeconds 0 } | Should -Throw '*did not confirm success*'
        }
        It 'rejects an ambiguous SCM hostname rather than guessing a publication endpoint' {
            Mock Get-AzWebApp { [pscustomobject]@{ EnabledHostNames = @('app.azurewebsites.net') } }
            { Publish-AutopilotFlexPackage -ResourceGroupName rg -FunctionAppName app -ArchivePath package.zip } |
                Should -Throw '*unambiguous SCM hostname*'
            Should -Invoke Invoke-WebRequest -Times 0
        }
    }

    Describe 'Private Flex deployment wiring' {
        BeforeAll {
            $template = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Infrastructure\main.bicep') -Raw
            $installer = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Installer\Install-AutopilotImport.ps1') -Raw
        }
        It 'defaults new infrastructure to Linux Flex while retaining the explicit legacy branch' {
            $template | Should -Match "param hostingMode string = 'FlexConsumption'"
            $template | Should -Match "name: isFlex \? 'FC1' : 'Y1'"
            $template | Should -Match "kind: isFlex \? 'functionapp,linux' : 'functionapp'"
            $template | Should -Match 'reserved: isFlex'
            $installer | Should -Match 'hostingMode\s*=\s*\$hostingMode'
        }
        It 'disables Storage public and local authentication for Flex' {
            $template | Should -Match "publicNetworkAccess: isFlex \? 'Disabled' : 'Enabled'"
            $template | Should -Match 'allowSharedKeyAccess: false'
            $template | Should -Match 'allowBlobPublicAccess: false'
            $template | Should -Match "minimumTlsVersion: 'TLS1_2'"
        }
        It 'wires three private Storage services to linked DNS zones' {
            $template | Should -Match "(?s)var storageServices = \[\s*'blob'\s*'queue'\s*'table'\s*\]"
            $template | Should -Match 'Microsoft.Network/privateEndpoints@'
            $template | Should -Match 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@'
            $template | Should -Match 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@'
            $template | Should -Match 'privateDnsZoneId: storagePrivateDns\[i\]\.id'
            $template | Should -Match "serviceName: 'Microsoft.App/environments'"
            $template | Should -Match "virtualNetworkSubnetId: isFlex \? '.+/subnets/functions'"
        }
        It 'allocates the VNet and both subnets within the private 172.16.0.0/12 range' {
            $prefixes = @([regex]::Matches($template, "'(?<prefix>(?:\d{1,3}\.){3}\d{1,3}/\d{1,2})'") |
                ForEach-Object { $_.Groups['prefix'].Value })
            $prefixes.Count | Should -Be 3
            $prefixes | Should -Contain '172.16.0.0/24'
            $prefixes | Should -Contain '172.16.0.0/26'
            $prefixes | Should -Contain '172.16.0.64/27'
            foreach ($prefix in $prefixes) {
                $address, $length = $prefix -split '/'
                $octets = ([ipaddress]::Parse($address)).GetAddressBytes()
                $octets[0] | Should -Be 172
                $octets[1] | Should -BeGreaterOrEqual 16
                $octets[1] | Should -BeLessOrEqual 31
                [int] $length | Should -BeGreaterOrEqual 12
            }
        }
        It 'uses identity-authenticated deployment storage without Azure Files or connection strings' {
            $template | Should -Match "name: 'deployment-packages'"
            $template | Should -Match "type: 'SystemAssignedIdentity'"
            $template | Should -Not -Match 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING|listKeys\('
            $installer | Should -Match "Register-AzureResourceProvider -ProviderNamespace 'Microsoft.App'"
            $installer | Should -Match "Register-AzureResourceProvider -ProviderNamespace 'Microsoft.Network'"
        }
        It 'routes Flex publishing through OneDeploy and preserves legacy publishing' {
            $installer | Should -Match '(?s)if \(\$hostingMode -eq ''FlexConsumption''\).*?Publish-AutopilotFlexPackage.*?else.*?Publish-AzWebApp'
        }
        It 'does not reintroduce pipeline rule configuration' {
            $pipeline = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\azure-pipelines.yml') -Raw
            $pipeline | Should -Not -Match 'TagAuthorizationRule|TAG_AUTHORIZATION_RULES_JSON|tagAuthorizationRulesJson'
        }
        It 'provides the same anonymous root redirect without Flex proxy support' {
            if (-not ('HttpResponseContext' -as [type])) {
                Add-Type 'public class HttpResponseContext {
                    public System.Net.HttpStatusCode StatusCode;
                    public System.Collections.Hashtable Headers;
                    public string Body;
                }'
            }
            function Push-OutputBinding { param($Name, $Value) }
            Mock Push-OutputBinding {}
            $binding = Get-Content -LiteralPath (Join-Path $functionRoot 'RootRedirect\function.json') -Raw | ConvertFrom-Json
            $binding.bindings[0].route | Should -Be '/'
            & (Join-Path $functionRoot 'RootRedirect\run.ps1') -Request @{}
            Should -Invoke Push-OutputBinding -Times 1 -ParameterFilter {
                $Value.StatusCode -eq 302 -and $Value.Headers.Location -eq '/api/ui/index.html' -and
                $Value.Headers['Cache-Control'] -eq 'no-store'
            }
        }
    }
}
