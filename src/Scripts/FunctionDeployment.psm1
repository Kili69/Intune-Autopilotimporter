# Project-Version: 1.4.20261020.15
# Author: andreas.lucas@outlook.com (aka Kili)

Set-StrictMode -Version Latest

function Get-AutopilotDeploymentHostingMode {
    <#
    .SYNOPSIS
    Determines the hosting mode of an existing Autopilot Function App.

    .DESCRIPTION
    This function inspects the hosting plan of the provided Function App and returns
    either 'Consumption' or 'FlexConsumption' based on the plan's SKU and configuration.

    .PARAMETER ExistingFunctionApp
    The existing Function App object to inspect. If $null, the function defaults to 'FlexConsumption'.

    .OUTPUTS
    [string] 'Consumption' or 'FlexConsumption'
    #>
    [CmdletBinding()]
    param([AllowNull()][object] $ExistingFunctionApp)
    # Begin processing the existing Function App to determine its hosting mode.
    if ($null -eq $ExistingFunctionApp) { return 'FlexConsumption' }
    # Extract the hosting plan ID from the existing Function App.
    $planId = [string] $ExistingFunctionApp.ServerFarmId
    # Ensure the hosting plan ID is not null or empty.
    if ([string]::IsNullOrWhiteSpace($planId)) {
        throw 'The existing Function App is missing its hosting plan ID. Refusing to change its hosting model.'
    }
    # Retrieve the hosting plan details from Azure.
    # This includes the SKU and reserved properties used to determine the hosting mode.
    $response = Invoke-AzRestMethod -Method GET -Path "${planId}?api-version=2024-11-01" -WhatIf:$false -ErrorAction Stop

    # Check if the hosting plan details were successfully retrieved.
    if ($response.StatusCode -ne 200) {
        throw "Unable to read the existing hosting plan: HTTP $($response.StatusCode)."
    }
    # Parse the hosting plan details from the response content.
    $plan = $response.Content | ConvertFrom-Json -ErrorAction Stop
    # Determine the hosting mode based on the SKU and reserved properties.
    if ($plan.sku.name -eq 'FC1' -and $plan.properties.reserved -eq $true) {
        return 'FlexConsumption'
    }
    # If the hosting plan does not match any known configuration, it is considered unsupported.
    if ($plan.sku.name -eq 'Y1' -and $plan.properties.reserved -ne $true) {
        return 'Consumption'
    }
    # Throw an error for unsupported hosting plans.
    throw "Hosting plan '$($plan.sku.name)' is not supported by this installer. Hosting and operating-system migrations require an explicit migration to a new app."
}

function Save-AutopilotRuntimeDependencies {
    <#
    .SYNOPSIS
    Saves the runtime dependencies of an Autopilot Function App to a specified destination path.

    .DESCRIPTION
    This function inspects the 'requirements.psd1' file in the Function App root and copies the installed modules
    matching the specified versions to the destination path. If a module is not installed, it attempts to save it
    from the PSGallery repository.

    .PARAMETER FunctionAppRoot
    The root directory of the Function App containing the 'requirements.psd1' file.

    .PARAMETER DestinationPath
    The path where the runtime dependencies should be saved.

    .OUTPUTS
    None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $FunctionAppRoot,
        [Parameter(Mandatory)][string] $DestinationPath
    )
    # Import the requirements from the 'requirements.psd1' file and process each module.
    $requirements = Import-PowerShellDataFile -LiteralPath (Join-Path $FunctionAppRoot 'requirements.psd1')
    # Iterate over each module specified in the requirements.
    foreach ($name in $requirements.Keys) {
        # Extract the major version from the version pattern specified in the requirements.
        $versionPattern = [string] $requirements[$name]
        # Validate that the version pattern follows the expected major-version wildcard format.
        if ($versionPattern -notmatch '^(\d+)\.\*$') {
            throw "Unsupported runtime dependency version '$versionPattern' for '$name'. Expected a major-version wildcard."
        }
        # Extract the major version number from the matched pattern.
        $major = [int] $Matches[1]
        # Check if the module with the required major version is already installed.
        $installed = Get-Module -ListAvailable -Name $name |
            Where-Object { $_.Version.Major -eq $major } |
            Sort-Object Version -Descending | Select-Object -First 1
        # If the module is installed, copy it to the destination path. Otherwise, attempt to save it from the PSGallery.
        if ($installed) {
            $parent = Join-Path $DestinationPath $name
            [IO.Directory]::CreateDirectory($parent) | Out-Null
            Copy-Item -LiteralPath $installed.ModuleBase -Destination (Join-Path $parent $installed.Version.ToString()) -Recurse -Force -ErrorAction Stop
        }
        # Attempt to save the module from the PSGallery if it is not already installed.
        elseif (Get-Command Save-PSResource -ErrorAction SilentlyContinue) {
            Save-PSResource -Name $name -Version $versionPattern -Repository PSGallery `
                -Path $DestinationPath -TrustRepository -ErrorAction Stop | Out-Null
        }
        else {
            # Fallback to using Save-Module if Save-PSResource is not available.
            Save-Module -Name $name -MinimumVersion "$major.0.0" -MaximumVersion "$major.999.999" `
                -Repository PSGallery -Path $DestinationPath -Force -AcceptLicense -ErrorAction Stop
        }
        # Verify that the module was successfully saved and matches the required major version.
        $manifests = @(Get-ChildItem -LiteralPath (Join-Path $DestinationPath $name) -Filter "$name.psd1" -Recurse -File -ErrorAction Stop)
        # Ensure that at least one manifest file was found for the module.
        if ($manifests.Count -eq 0) { throw "Runtime module '$name' was not saved." }
        # Verify that each manifest file corresponds to the required major version.
        foreach ($manifest in $manifests) {
            # Import the manifest data from the .psd1 file.
            $data = Import-PowerShellDataFile -LiteralPath $manifest.FullName
            # Check if the major version of the module matches the required major version.
            if (([version] $data.ModuleVersion).Major -ne $major) {
                throw "Runtime module '$name' does not match required version '$versionPattern'."
            }
        }
    }
}

function New-AutopilotFunctionPackage {
    <#
    .SYNOPSIS
        Creates a new Autopilot function package.

    .DESCRIPTION
        This function stages the necessary files and dependencies for an Autopilot function app,
        and then packages them into the specified destination path.

    .PARAMETER FunctionAppRoot
        The root directory of the function app containing the source files.

    .PARAMETER DestinationPath
        The path where the packaged function app should be saved.

    .PARAMETER HostingMode
        The hosting mode for the function app. Valid values are 'Consumption' and 'FlexConsumption'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $FunctionAppRoot,
        [Parameter(Mandatory)][string] $DestinationPath,
        [Parameter(Mandatory)][ValidateSet('Consumption', 'FlexConsumption')][string] $HostingMode
    )
    # Begin staging the function app files and dependencies.
    $staging = Join-Path ([IO.Path]::GetTempPath()) "autopilot-runtime-$([guid]::NewGuid().ToString('N'))"
    [IO.Directory]::CreateDirectory($staging) | Out-Null
    try {
        # Define the list of entries to include in the package.
        $entries = @(
            'host.json', 'requirements.psd1', 'profile.ps1', 'ImportDevice',
            'ProcessDeviceAttribute', 'ManageTagPolicy', 'ManagePolicyManagers',
            'GetAuthorizedTags', 'ManageDeviceTags', 'GetImportHistory',
            'RemoveExpiredImportHistory', 'WebFrontend', 'src'
        )
        # Include additional entries based on the hosting mode.
        $entries += if ($HostingMode -eq 'FlexConsumption') { 'RootRedirect' } else { 'proxies.json' }
        # Copy each entry from the function app root to the staging directory.
        foreach ($entry in $entries) {
            $source = Join-Path $FunctionAppRoot $entry
            if (-not (Test-Path -LiteralPath $source)) { throw "Runtime package entry is missing: $source" }
            Copy-Item -LiteralPath $source -Destination (Join-Path $staging $entry) -Recurse -Force -ErrorAction Stop
        }
        # If the hosting mode is FlexConsumption, modify the host.json and save the dependencies.
        if ($HostingMode -eq 'FlexConsumption') {
            $hostPath = Join-Path $staging 'host.json'
            $hostConfiguration = Get-Content -LiteralPath $hostPath -Raw | ConvertFrom-Json -ErrorAction Stop
            $hostConfiguration.managedDependency.enabled = $false
            $hostConfiguration | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $hostPath -Encoding utf8NoBOM
            $modulesPath = Join-Path $staging 'Modules'
            [IO.Directory]::CreateDirectory($modulesPath) | Out-Null
            Save-AutopilotRuntimeDependencies -FunctionAppRoot $FunctionAppRoot -DestinationPath $modulesPath
        }
        # Create the final package by compressing the staging directory into the destination path.
        $destination = [IO.Path]::GetFullPath($DestinationPath)
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
        # Remove the existing destination file if it exists before creating the new package.
        if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force -ErrorAction Stop }
        [IO.Compression.ZipFile]::CreateFromDirectory($staging, $destination, [IO.Compression.CompressionLevel]::Optimal, $false)
        Get-Item -LiteralPath $destination
    }
    finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Stop
    }
}

function Publish-AutopilotFlexPackage {
    <#
    .SYNOPSIS
        Publishes an Autopilot Flex package to the specified Function App.

    .DESCRIPTION
        This function uploads a pre-packaged Autopilot Flex package to the specified Azure Function App
        and monitors the deployment status until completion or until the maximum number of poll attempts is reached.

    .PARAMETER ResourceGroupName
        The name of the resource group containing the Function App.

    .PARAMETER FunctionAppName
        The name of the Function App to which the package should be published.

    .PARAMETER ArchivePath
        The path to the pre-packaged Autopilot Flex package (ZIP file) to be uploaded.

    .PARAMETER MaximumPollAttempts
        The maximum number of times to poll the deployment status before giving up. Default is 180.

    .PARAMETER PollIntervalSeconds
        The interval, in seconds, between each poll attempt. Default is 5.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ResourceGroupName,
        [Parameter(Mandatory)][string] $FunctionAppName,
        [Parameter(Mandatory)][string] $ArchivePath,
        [ValidateRange(1, 900)][int] $MaximumPollAttempts = 180,
        [ValidateRange(0, 60)][int] $PollIntervalSeconds = 5
    )
    # Retrieve the Function App details and SCM host information.
    $app = Get-AzWebApp -ResourceGroupName $ResourceGroupName -Name $FunctionAppName -ErrorAction Stop
    # Extract the SCM hostnames from the enabled hostnames of the Function App.
    $scmHosts = @($app.EnabledHostNames | Where-Object { $_ -match '\.scm\.' })
    # Ensure there is exactly one SCM hostname.
    if ($scmHosts.Count -ne 1) { throw 'The Function App did not return one unambiguous SCM hostname.' }
    # Construct the SCM URI using the single SCM hostname.
    $scmUri = "https://$($scmHosts[0])"
    # Acquire an access token for the Azure management API.
    $accessToken = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/' -ErrorAction Stop
    # Convert the access token to a secure string if it is not already.
    $token = if ($accessToken.Token -is [Security.SecureString]) { $accessToken.Token }
        else { ConvertTo-SecureString ([string] $accessToken.Token) -AsPlainText -Force }
    # Store the current timestamp to track when the deployment started.
    $startedAt = [datetimeoffset]::UtcNow
    # Generate a unique deployer identifier for this deployment attempt.
    $deployer = "AutopilotImport-$([guid]::NewGuid().ToString('N'))"
    # Initiate the deployment by invoking the publish API with the generated deployer identifier.
    $response = Invoke-WebRequest -Method POST -Uri "$scmUri/api/publish?RemoteBuild=false&Deployer=$deployer" `
        -Authentication Bearer -Token $token -InFile $ArchivePath -ContentType 'application/zip' `
        -Headers @{ 'Cache-Control' = 'no-cache' } -SkipHttpErrorCheck -ErrorAction Stop
    # Check if the deployment was accepted by the server.
    if ($response.StatusCode -ne 202) {
        throw "Flex publication was not accepted: HTTP $($response.StatusCode). $($response.Content)"
    }
    # Initialize the deployment ID and parse it from the response content.
    $deploymentId = [guid]::Empty
    $responseContent = if ($response.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($response.Content) }
        else { [string] $response.Content }
    $deploymentIdText = $responseContent.Trim().Trim('"')
    $hasDeploymentId = [guid]::TryParse($deploymentIdText, [ref] $deploymentId)
    # Determine the status URI based on whether a valid deployment ID was obtained.
    $statusUri = if ($hasDeploymentId) { "$scmUri/api/deployments/$deploymentIdText" } else { "$scmUri/api/deployments/latest" }
    # Poll the deployment status until it is available or the maximum number of attempts is reached.
    for ($attempt = 1; $attempt -le $MaximumPollAttempts; $attempt++) {
        $statusResponse = Invoke-WebRequest -Method GET -Uri $statusUri -Authentication Bearer -Token $token `
            -SkipHttpErrorCheck -ErrorAction Stop
        # If the status response is 404, the deployment status is not yet available.
        if ($statusResponse.StatusCode -eq 404) {
            Write-Verbose "Flex deployment status is not available yet ($attempt/$MaximumPollAttempts)."
        }
        # If the status response is 200 or 202, the deployment status is available.
        elseif ($statusResponse.StatusCode -in 200, 202) {
            # Parse the deployment status from the response content.
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
            # Check if the deployment status matches the current request and contains a status property.
            if ($matchesRequest -and $status.PSObject.Properties['status']) {
                # If the status indicates success, return from the function.
                if ($status.status -eq 4) { return }
                # If the status indicates failure or cancellation, throw an error with details.
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
# Export the specified functions from the module.
Export-ModuleMember -Function Get-AutopilotDeploymentHostingMode, Save-AutopilotRuntimeDependencies, New-AutopilotFunctionPackage, Publish-AutopilotFlexPackage
