# Project-Version: 1.4.20261019.5
# Author: andreas.lucas@outlook.com (aka Kili)

Set-StrictMode -Version Latest

function Get-AutopilotDeploymentHostingMode {
    [CmdletBinding()]
    param([AllowNull()][object] $ExistingFunctionApp)

    if ($null -eq $ExistingFunctionApp) { return 'FlexConsumption' }
    $planId = [string] $ExistingFunctionApp.ServerFarmId
    if ([string]::IsNullOrWhiteSpace($planId)) {
        throw 'The existing Function App is missing its hosting plan ID. Refusing to change its hosting model.'
    }
    $response = Invoke-AzRestMethod -Method GET -Path "${planId}?api-version=2024-11-01" -WhatIf:$false -ErrorAction Stop
    if ($response.StatusCode -ne 200) {
        throw "Unable to read the existing hosting plan: HTTP $($response.StatusCode)."
    }
    $plan = $response.Content | ConvertFrom-Json -ErrorAction Stop
    if ($plan.sku.name -eq 'FC1' -and $plan.properties.reserved -eq $true) {
        return 'FlexConsumption'
    }
    if ($plan.sku.name -eq 'Y1' -and $plan.properties.reserved -ne $true) {
        return 'Consumption'
    }
    throw "Hosting plan '$($plan.sku.name)' is not supported by this installer. Hosting and operating-system migrations require an explicit migration to a new app."
}

function Save-AutopilotRuntimeDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $FunctionAppRoot,
        [Parameter(Mandatory)][string] $DestinationPath
    )

    $requirements = Import-PowerShellDataFile -LiteralPath (Join-Path $FunctionAppRoot 'requirements.psd1')
    foreach ($name in $requirements.Keys) {
        $versionPattern = [string] $requirements[$name]
        if ($versionPattern -notmatch '^(\d+)\.\*$') {
            throw "Unsupported runtime dependency version '$versionPattern' for '$name'. Expected a major-version wildcard."
        }
        $major = [int] $Matches[1]
        $installed = Get-Module -ListAvailable -Name $name |
            Where-Object { $_.Version.Major -eq $major } |
            Sort-Object Version -Descending | Select-Object -First 1
        if ($installed) {
            $parent = Join-Path $DestinationPath $name
            [IO.Directory]::CreateDirectory($parent) | Out-Null
            Copy-Item -LiteralPath $installed.ModuleBase -Destination (Join-Path $parent $installed.Version.ToString()) -Recurse -Force -ErrorAction Stop
        }
        elseif (Get-Command Save-PSResource -ErrorAction SilentlyContinue) {
            Save-PSResource -Name $name -Version $versionPattern -Repository PSGallery `
                -Path $DestinationPath -TrustRepository -ErrorAction Stop | Out-Null
        }
        else {
            Save-Module -Name $name -MinimumVersion "$major.0.0" -MaximumVersion "$major.999.999" `
                -Repository PSGallery -Path $DestinationPath -Force -AcceptLicense -ErrorAction Stop
        }
        $manifests = @(Get-ChildItem -LiteralPath (Join-Path $DestinationPath $name) -Filter "$name.psd1" -Recurse -File -ErrorAction Stop)
        if ($manifests.Count -eq 0) { throw "Runtime module '$name' was not saved." }
        foreach ($manifest in $manifests) {
            $data = Import-PowerShellDataFile -LiteralPath $manifest.FullName
            if (([version] $data.ModuleVersion).Major -ne $major) {
                throw "Runtime module '$name' does not match required version '$versionPattern'."
            }
        }
    }
}

function New-AutopilotFunctionPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $FunctionAppRoot,
        [Parameter(Mandatory)][string] $DestinationPath,
        [Parameter(Mandatory)][ValidateSet('Consumption', 'FlexConsumption')][string] $HostingMode
    )

    $staging = Join-Path ([IO.Path]::GetTempPath()) "autopilot-runtime-$([guid]::NewGuid().ToString('N'))"
    [IO.Directory]::CreateDirectory($staging) | Out-Null
    try {
        $entries = @(
            'host.json', 'requirements.psd1', 'profile.ps1', 'ImportDevice',
            'ProcessDeviceAttribute', 'ManageTagPolicy', 'ManagePolicyManagers',
            'GetAuthorizedTags', 'ManageDeviceTags', 'GetImportHistory',
            'RemoveExpiredImportHistory', 'WebFrontend', 'src'
        )
        $entries += if ($HostingMode -eq 'FlexConsumption') { 'RootRedirect' } else { 'proxies.json' }
        foreach ($entry in $entries) {
            $source = Join-Path $FunctionAppRoot $entry
            if (-not (Test-Path -LiteralPath $source)) { throw "Runtime package entry is missing: $source" }
            Copy-Item -LiteralPath $source -Destination (Join-Path $staging $entry) -Recurse -Force -ErrorAction Stop
        }
        if ($HostingMode -eq 'FlexConsumption') {
            $hostPath = Join-Path $staging 'host.json'
            $hostConfiguration = Get-Content -LiteralPath $hostPath -Raw | ConvertFrom-Json -ErrorAction Stop
            $hostConfiguration.managedDependency.enabled = $false
            $hostConfiguration | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $hostPath -Encoding utf8NoBOM
            $modulesPath = Join-Path $staging 'Modules'
            [IO.Directory]::CreateDirectory($modulesPath) | Out-Null
            Save-AutopilotRuntimeDependencies -FunctionAppRoot $FunctionAppRoot -DestinationPath $modulesPath
        }
        $destination = [IO.Path]::GetFullPath($DestinationPath)
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
        if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force -ErrorAction Stop }
        [IO.Compression.ZipFile]::CreateFromDirectory($staging, $destination, [IO.Compression.CompressionLevel]::Optimal, $false)
        Get-Item -LiteralPath $destination
    }
    finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Stop
    }
}

function Publish-AutopilotFlexPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ResourceGroupName,
        [Parameter(Mandatory)][string] $FunctionAppName,
        [Parameter(Mandatory)][string] $ArchivePath,
        [ValidateRange(1, 900)][int] $MaximumPollAttempts = 180,
        [ValidateRange(0, 60)][int] $PollIntervalSeconds = 5
    )

    $app = Get-AzWebApp -ResourceGroupName $ResourceGroupName -Name $FunctionAppName -ErrorAction Stop
    $scmHosts = @($app.EnabledHostNames | Where-Object { $_ -match '\.scm\.' })
    if ($scmHosts.Count -ne 1) { throw 'The Function App did not return one unambiguous SCM hostname.' }
    $scmUri = "https://$($scmHosts[0])"
    $accessToken = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/' -ErrorAction Stop
    $token = if ($accessToken.Token -is [Security.SecureString]) { $accessToken.Token }
        else { ConvertTo-SecureString ([string] $accessToken.Token) -AsPlainText -Force }
    $startedAt = [datetimeoffset]::UtcNow
    $deployer = "AutopilotImport-$([guid]::NewGuid().ToString('N'))"
    $response = Invoke-WebRequest -Method POST -Uri "$scmUri/api/publish?RemoteBuild=false&Deployer=$deployer" `
        -Authentication Bearer -Token $token -InFile $ArchivePath -ContentType 'application/zip' `
        -Headers @{ 'Cache-Control' = 'no-cache' } -SkipHttpErrorCheck -ErrorAction Stop
    if ($response.StatusCode -ne 202) {
        throw "Flex publication was not accepted: HTTP $($response.StatusCode). $($response.Content)"
    }
    $deploymentId = [guid]::Empty
    $responseContent = if ($response.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($response.Content) }
        else { [string] $response.Content }
    $deploymentIdText = $responseContent.Trim().Trim('"')
    $hasDeploymentId = [guid]::TryParse($deploymentIdText, [ref] $deploymentId)
    $statusUri = if ($hasDeploymentId) { "$scmUri/api/deployments/$deploymentIdText" } else { "$scmUri/api/deployments/latest" }
    for ($attempt = 1; $attempt -le $MaximumPollAttempts; $attempt++) {
        $statusResponse = Invoke-WebRequest -Method GET -Uri $statusUri -Authentication Bearer -Token $token `
            -SkipHttpErrorCheck -ErrorAction Stop
        if ($statusResponse.StatusCode -eq 404) {
            Write-Verbose "Flex deployment status is not available yet ($attempt/$MaximumPollAttempts)."
        }
        elseif ($statusResponse.StatusCode -in 200, 202) {
            $status = $statusResponse.Content | ConvertFrom-Json -ErrorAction Stop
            $receivedAt = [datetimeoffset]::MinValue
            $matchesRequest = $hasDeploymentId
            if (-not $matchesRequest -and $status.PSObject.Properties['deployer'] -and
                $status.deployer -eq $deployer -and $status.PSObject.Properties['received_time']) {
                $receivedTime = $status.received_time
                if ($receivedTime -is [datetime] -and $receivedTime.Kind -eq [DateTimeKind]::Unspecified) {
                    $receivedTime = [datetime]::SpecifyKind($receivedTime, [DateTimeKind]::Utc)
                }
                $parsedTime = if ($receivedTime -is [datetime] -or $receivedTime -is [datetimeoffset]) {
                    $receivedAt = [datetimeoffset] $receivedTime
                    $true
                } else {
                    [datetimeoffset]::TryParse([string] $receivedTime, [cultureinfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::AssumeUniversal, [ref] $receivedAt)
                }
                $matchesRequest = $parsedTime -and $receivedAt -ge $startedAt.AddSeconds(-5)
            }
            if ($matchesRequest -and $status.PSObject.Properties['status']) {
                if ($status.status -eq 4) { return }
                if ($status.status -in -1, 3, 5, 6) {
                    throw "Flex deployment failed or was cancelled (status $($status.status)). See $statusUri/log for details."
                }
            }
        }
        else { throw "Unable to read Flex deployment status: HTTP $($statusResponse.StatusCode)." }
        if ($attempt -lt $MaximumPollAttempts) { Start-Sleep -Seconds $PollIntervalSeconds }
    }
    throw "Flex deployment did not confirm success within the polling limit. Check $statusUri before retrying."
}

Export-ModuleMember -Function Get-AutopilotDeploymentHostingMode, Save-AutopilotRuntimeDependencies, New-AutopilotFunctionPackage, Publish-AutopilotFlexPackage
