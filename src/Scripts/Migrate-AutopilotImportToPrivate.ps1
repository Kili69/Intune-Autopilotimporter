#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Resources, Az.Websites, Az.Storage
# Project-Version: 1.4.20261022.1
# Author: andreas.lucas@outlook.com (aka Kili)

<#
.SYNOPSIS
Recreates a Windows Consumption Function App as Linux Flex Consumption with private Storage.

.DESCRIPTION
Creates a metadata-only backup of the current deployment settings, then
removes the Windows Function App and its Y1 plan and invokes the regular
installer to create Flex Consumption using the same app name and Storage
account. The Storage account, policy blob, queues, audit table and data are
retained; the Function App's managed identity is replaced and its runtime
permissions are provisioned again by the installer.

This is a destructive, staged migration. The source app is unavailable between
deletion and successful recreation. An existing custom-domain binding and its
certificate cannot be carried over to Flex Consumption automatically. After
the new app is healthy, add the custom domain and create/bind a site-scoped
certificate in the Azure portal. The default azurewebsites.net hostname is
available for the migration smoke test.

.PARAMETER SubscriptionId
Subscription containing the existing Function App.

.PARAMETER TenantId
Entra tenant containing the deployment and application registrations.

.PARAMETER ResourceGroupName
Resource group containing the existing app and Storage account.

.PARAMETER FunctionAppName
Existing Windows Consumption Function App name. The same name is reused.

.PARAMETER BackupPath
Path for the metadata backup. The backup contains policy and manager settings,
application IDs, Storage account name and custom hostnames, but no tokens or
application secrets. When the source app is already absent, supply this file
to resume after a previously interrupted migration.

.PARAMETER ClientToolsPath
Local destination for the refreshed client module and configuration.

.PARAMETER VirtualNetworkAddressPrefix
Free private IPv4 /24 for the new Flex VNet. The /26 Functions integration
subnet and /27 private-endpoint subnet are derived from this address space.

.PARAMETER InstallMissingModules
Installs missing prerequisites through the regular installer.

.PARAMETER ForceGraphSignIn
Uses explicit device-code sign-in for Graph role assignment.

.PARAMETER GraphAccessToken
Optional in-memory Microsoft Graph token with Application.Read.All and
AppRoleAssignment.ReadWrite.All delegated permissions, used instead of
interactive sign-in. Never persist the token in the migration backup.

.PARAMETER AcceptCustomDomainCertificateReissue
Confirms that the existing custom-domain binding/certificate will be removed
and must be recreated manually after migration.

.EXAMPLE
.\Migrate-AutopilotImportToPrivate.ps1 -SubscriptionId '<subscription-guid>' `
  -TenantId '<tenant-guid>' -ResourceGroupName 'rg-autopilot-import' `
  -FunctionAppName 'func-autopilot-d89a354d' -WhatIf

Shows the planned migration without deleting the Function App or plan.

.EXAMPLE
.\Migrate-AutopilotImportToPrivate.ps1 -SubscriptionId '<subscription-guid>' `
  -TenantId '<tenant-guid>' -ResourceGroupName 'rg-autopilot-import' `
  -FunctionAppName 'func-autopilot-d89a354d' `
  -AcceptCustomDomainCertificateReissue

Runs the migration after interactive confirmation.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [guid] $SubscriptionId,

    [Parameter(Mandatory)]
    [guid] $TenantId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z0-9-]{2,60}$')]
    [string] $FunctionAppName,

    [string] $BackupPath,

    [string] $ClientToolsPath,

    [ValidatePattern('^(?:10|172\.(?:1[6-9]|2[0-9]|3[01])|192\.168)\.\d{1,3}\.0/24$')]
    [string] $VirtualNetworkAddressPrefix,

    [switch] $InstallMissingModules,

    [switch] $ForceGraphSignIn,

    [securestring] $GraphAccessToken,

    [switch] $AcceptCustomDomainCertificateReissue
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Validate mutually exclusive parameters before proceeding.
if ($ForceGraphSignIn -and $GraphAccessToken) {
    throw 'Specify either -ForceGraphSignIn or -GraphAccessToken, not both.'
}

function Invoke-MigrationArmRequest {
    <#
    .SYNOPSIS
    Invokes an Azure Resource Manager request for the migration.

    .PARAMETER Method
    The HTTP method to use (GET, POST, DELETE).

    .PARAMETER Path
    The ARM resource path for the request.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'DELETE')][string] $Method,
        [Parameter(Mandatory)][string] $Path
    )
    # Invoke the ARM request using the specified method and path.
    Invoke-AzRestMethod -Method $Method -Path $Path -WhatIf:$false -ErrorAction Stop
}

function Wait-MigrationResourceDeleted {
    <#
    .SYNOPSIS
    Waits for an Azure resource to be deleted.

    .PARAMETER ResourceId
    The resource ID of the Azure resource to check.

    .PARAMETER ApiVersion
    The API version to use for the request.

    .PARAMETER TimeoutSeconds
    The maximum number of seconds to wait for the resource to be deleted. Default is 300.
    #>
    param(
        [Parameter(Mandatory)][string] $ResourceId,
        [Parameter(Mandatory)][string] $ApiVersion,
        [int] $TimeoutSeconds = 300
    )
    # Wait for the Azure resource to be deleted until the timeout is reached.
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    # Calculate the deadline for the timeout.
    do {
        try {
            # Attempt to get the Azure resource to check if it still exists.
            $response = Invoke-MigrationArmRequest -Method GET `
                -Path "${ResourceId}?api-version=$ApiVersion"
            # Check if the response indicates that the resource was not found.
            if ($response.StatusCode -eq 404) { return }
        }
        catch {
            if ($_.Exception.Message -match '(?i)\b404\b|ResourceNotFound') { return }
            throw
        }
        Start-Sleep -Seconds 10
    } while ([datetime]::UtcNow -lt $deadline)

    throw "Timed out waiting for Azure resource '$ResourceId' to be deleted."
}

function Get-MigrationCustomHostNames {
    <#
    .SYNOPSIS
    Retrieves the custom hostnames for a given Azure resource.

    .PARAMETER ResourceId
    The resource ID of the Azure resource to check.
    #>
    param([Parameter(Mandatory)][string] $ResourceId)
    # Retrieve the custom hostnames for the specified Azure resource.
    $response = Invoke-MigrationArmRequest -Method GET `
        -Path "$ResourceId/hostNameBindings?api-version=2024-11-01"
    # Check if the response indicates an error.
    if ($response.StatusCode -ge 400) {
        throw "Unable to read existing custom hostnames (HTTP $($response.StatusCode))."
    }
    # Parse the response content as JSON.
    $document = $response.Content | ConvertFrom-Json -ErrorAction Stop
    # Extract and return the unique custom hostnames, excluding the default Azure ones.
    return @($document.value | ForEach-Object {
        $hostName = [string] $_.name
        if ($hostName -match '/') { $hostName = $hostName.Split('/')[-1] }
        if (-not [string]::IsNullOrWhiteSpace($hostName) -and
            $hostName -notlike '*.azurewebsites.net') {
            $hostName.ToLowerInvariant()
        }
    } | Sort-Object -Unique)
}

function Read-MigrationSettings {
    <#
    .SYNOPSIS
    Reads the migration settings for a given Function App.

    .PARAMETER SubscriptionId
    The subscription ID of the Azure resource.

    .PARAMETER ResourceGroupName
    The resource group name of the Function App.

    .PARAMETER FunctionAppName
    The name of the Function App.

    .PARAMETER TenantId
    The tenant ID of the Azure resource.
    #>
    param(
        [Parameter(Mandatory)][guid] $SubscriptionId,
        [Parameter(Mandatory)][string] $ResourceGroupName,
        [Parameter(Mandatory)][string] $FunctionAppName,
        [Parameter(Mandatory)][guid] $TenantId
    )
    # Construct the resource ID for the Function App.
    $resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName"
    # Send a request to list the app settings for the Function App.
    $response = Invoke-MigrationArmRequest -Method POST `
        -Path "$resourceId/config/appsettings/list?api-version=2023-12-01"
    # Check if the response indicates an error.
    if ($response.StatusCode -ne 200) {
        throw "Unable to read the existing Function App settings (HTTP $($response.StatusCode))."
    }
    # Parse the response content as JSON.
    $document = $response.Content | ConvertFrom-Json -ErrorAction Stop
    # Ensure the response contains the expected properties object.
    if ($null -eq $document.properties) {
        throw 'The Function App settings response has no properties object.'
    }
    # Extract the app settings from the response.
    $settings = $document.properties
    # Validate and parse the API_AUDIENCE setting.
    $audience = [string] $settings.API_AUDIENCE
    # Validate and parse the WEB_CLIENT_ID setting.
    $clientId = [guid]::Empty
    # Validate and parse the TENANT_ID setting.
    if ($audience -notmatch '^api://' -or
        -not [guid]::TryParse(($audience -replace '^api://', ''), [ref] $clientId)) {
        throw 'API_AUDIENCE is missing or does not use the api://<client-guid> format.'
    }
    # Validate and parse the TAG_AUTHORIZATION_POLICY setting.
    $webClientId = [guid]::Empty
    if (-not [guid]::TryParse([string] $settings.WEB_CLIENT_ID, [ref] $webClientId)) {
        throw 'WEB_CLIENT_ID is missing or invalid.'
    }
    # Validate and parse the MANAGER_AUTHORIZATION_POLICY setting.
    if ([guid] $settings.TENANT_ID -ne $TenantId) {
        throw 'The configured TENANT_ID does not match the requested tenant.'
    }
    # Validate and parse the installer principal ID and additional manager principal IDs.
    $tagFallback = [string] $settings.TAG_AUTHORIZATION_POLICY
    # Ensure the TAG_AUTHORIZATION_POLICY setting is valid JSON.
    if ([string]::IsNullOrWhiteSpace($tagFallback)) { $tagFallback = '[]' }
    try {
        $null = $tagFallback | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "TAG_AUTHORIZATION_POLICY is not valid JSON: $($_.Exception.Message)"
    }
    # Validate and parse the MANAGER_AUTHORIZATION_POLICY setting as JSON.
    $managerPolicyJson = [string] $settings.MANAGER_AUTHORIZATION_POLICY
    # Ensure the MANAGER_AUTHORIZATION_POLICY setting is not empty.
    if ([string]::IsNullOrWhiteSpace($managerPolicyJson)) {
        throw 'MANAGER_AUTHORIZATION_POLICY is missing. Refusing to migrate without preserving policy administration.'
    }
    try {
        $managerPolicy = $managerPolicyJson | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        throw "MANAGER_AUTHORIZATION_POLICY is not valid JSON: $($_.Exception.Message)"
    }
    # Validate the structure and content of the MANAGER_AUTHORIZATION_POLICY setting.
    $installerId = [guid]::Empty
    if ($managerPolicy -isnot [System.Collections.IDictionary] -or
        -not [guid]::TryParse([string] $managerPolicy.installerPrincipalId, [ref] $installerId) -or
        $managerPolicy.additionalPrincipalIds -isnot [array] -or
        $managerPolicy.allowIntuneRoleAdministrators -isnot [bool]) {
        throw 'MANAGER_AUTHORIZATION_POLICY is missing a valid installer principal, manager array, or Intune administrator setting.'
    }
    # Validate each additional manager principal ID as a GUID.
    foreach ($principalId in $managerPolicy.additionalPrincipalIds) {
        # Parse and validate the current additional manager principal ID as a GUID.
        $parsedId = [guid]::Empty
        if (-not [guid]::TryParse([string] $principalId, [ref] $parsedId)) {
            throw "Invalid manager object ID in MANAGER_AUTHORIZATION_POLICY: '$principalId'."
        }
    }
    # Validate and parse the AzureWebJobsStorage__accountName setting.
    $storageAccountName = [string] $settings.AzureWebJobsStorage__accountName
    # Ensure the AzureWebJobsStorage__accountName setting is not empty and follows the required format.
    if ($storageAccountName -notmatch '^[a-z0-9]{3,24}$') {
        throw 'AzureWebJobsStorage__accountName is missing or invalid.'
    }
    # Validate and parse the DEVICE_TAG_EXTENSION_ATTRIBUTE setting.
    $extensionAttribute = [string] $settings.DEVICE_TAG_EXTENSION_ATTRIBUTE
    # Set a default value for the DEVICE_TAG_EXTENSION_ATTRIBUTE setting if it is not specified.
    if ([string]::IsNullOrWhiteSpace($extensionAttribute)) {
        $extensionAttribute = 'extensionAttribute1'
    }
    # Ensure the DEVICE_TAG_EXTENSION_ATTRIBUTE setting follows the required format.
    if ($extensionAttribute -notmatch '^extensionAttribute(?:[1-9]|1[0-5])$') {
        throw "Invalid DEVICE_TAG_EXTENSION_ATTRIBUTE '$extensionAttribute'."
    }
    # Return the validated and parsed configuration as an ordered hashtable.
    return [ordered]@{
        apiAudience             = $audience
        entraClientId           = $clientId.ToString()
        webClientId             = $webClientId.ToString()
        tenantId                = $TenantId.ToString()
        tagAuthorizationPolicy  = $tagFallback
        managerPolicy           = $managerPolicyJson
        installerPrincipalId    = $installerId.ToString()
        managerPrincipalIds     = @($managerPolicy.additionalPrincipalIds)
        storageAccountName      = $storageAccountName
        deviceTagExtensionAttribute = $extensionAttribute
    }
}

function Read-MigrationBackup {
    <#
    .SYNOPSIS
    Reads and validates a migration backup file.

    .PARAMETER Path
    The path to the migration backup file.

    .PARAMETER SubscriptionId
    The subscription ID associated with the migration backup.

    .PARAMETER TenantId
    The tenant ID associated with the migration backup.

    .PARAMETER ResourceGroupName
    The resource group name associated with the migration backup.

    .PARAMETER FunctionAppName
    The function app name associated with the migration backup.

    .OUTPUTS
    Hashtable representing the validated migration backup.
    #>
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][guid] $SubscriptionId,
        [Parameter(Mandatory)][guid] $TenantId,
        [Parameter(Mandatory)][string] $ResourceGroupName,
        [Parameter(Mandatory)][string] $FunctionAppName
    )
    # Ensure the migration backup file exists at the specified path.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Migration backup '$Path' was not found."
    }
    # Read and parse the migration backup file as JSON.
    $backup = Get-Content -LiteralPath $Path -Raw |
        ConvertFrom-Json -AsHashtable -ErrorAction Stop
    # Validate the top-level structure and required fields of the migration backup.
    if ($backup.format -cne 'autopilot-import-private-endpoint-migration' -or
        $backup.schemaVersion -ne 1 -or
        $backup.subscriptionId -ne $SubscriptionId.ToString() -or
        $backup.tenantId -ne $TenantId.ToString() -or
        $backup.resourceGroupName -ne $ResourceGroupName -or
        $backup.functionAppName -ne $FunctionAppName -or
        $backup.configuration -isnot [System.Collections.IDictionary]) {
        throw 'The supplied migration backup does not match this target or has an unsupported format.'
    }
    # Return the validated migration backup.
    return $backup
}

function Get-MigrationSourceManagedIdentityId {
    <#
    .SYNOPSIS
    Retrieves the managed identity ID of the source migration storage account.

    .PARAMETER StorageResourceId
    The resource ID of the source storage account.

    .PARAMETER KnownPrincipalId
    The known principal ID of the source managed identity, if available.

    .OUTPUTS
    The managed identity ID of the source migration storage account.
    #>
    param(
        [Parameter(Mandatory)][string] $StorageResourceId,
        [string] $KnownPrincipalId
    )
    # If a known principal ID is provided, validate and return it.
    if (-not [string]::IsNullOrWhiteSpace($KnownPrincipalId)) {
        $parsedId = [guid]::Empty
        if (-not [guid]::TryParse($KnownPrincipalId, [ref] $parsedId)) {
            throw "Invalid source managed identity object ID '$KnownPrincipalId'."
        }
        return $parsedId.ToString()
    }

    # Define the set of required roles for the source managed identity.
    $requiredRoles = @(
        'Storage Blob Data Owner'
        'Storage Queue Data Contributor'
        'Storage Table Data Contributor'
    )
    $assignments = @(Get-AzRoleAssignment -Scope $StorageResourceId -ErrorAction Stop |
        Where-Object {
            $_.ObjectType -eq 'ServicePrincipal' -and
            $_.RoleDefinitionName -in $requiredRoles -and
            ([string] $_.Scope).TrimEnd('/') -ieq $StorageResourceId.TrimEnd('/')
        })
    if ($assignments.Count -eq 0) { return $null }
    # Group the role assignments by object ID and identify candidates that have all required roles.
    $candidates = @($assignments | Group-Object ObjectId | Where-Object {
        $assignedRoles = @($_.Group | ForEach-Object { [string] $_.RoleDefinitionName })
        @($requiredRoles | Where-Object { $_ -notin $assignedRoles }).Count -eq 0
    })
    # Ensure that exactly one candidate is identified as the source managed identity.
    if ($candidates.Count -ne 1) {
        throw 'Could not uniquely identify the old Function managed identity from its complete set of Storage roles. No role assignments were changed.'
    }
    return [string] $candidates[0].Name
}

function Remove-MigrationSourceStorageRoleAssignments {
    <#
    .SYNOPSIS
    Removes the obsolete role assignments for the source migration storage account.

    .PARAMETER StorageResourceId
    The resource ID of the source storage account.

    .PARAMETER PrincipalId
    The principal ID of the source managed identity.

    .NOTES
    This function ensures that all required roles are removed and verifies that no obsolete role assignments remain.
    #>
    param(
        [Parameter(Mandatory)][string] $StorageResourceId,
        [Parameter(Mandatory)][guid] $PrincipalId
    )
    # Define the set of required roles for the source managed identity.
    $requiredRoles = @(
        'Storage Blob Data Owner'
        'Storage Queue Data Contributor'
        'Storage Table Data Contributor'
    )
    # Retrieve the current role assignments for the specified principal within the storage account scope.
    $assignments = @(Get-AzRoleAssignment -Scope $StorageResourceId -ErrorAction Stop |
        Where-Object {
            [string] $_.ObjectId -ieq $PrincipalId.ToString() -and
            $_.RoleDefinitionName -in $requiredRoles -and
            ([string] $_.Scope).TrimEnd('/') -ieq $StorageResourceId.TrimEnd('/')
        })
    # Remove each of the current role assignments for the specified principal.
    foreach ($assignment in $assignments) {
        Remove-AzRoleAssignment `
            -ObjectId $PrincipalId.ToString() `
            -RoleDefinitionName $assignment.RoleDefinitionName `
            -Scope $StorageResourceId `
            -Confirm:$false `
            -ErrorAction Stop |
            Out-Null
    }

    # Verify that no obsolete role assignments remain for the specified principal.
    $remainingAssignments = @(Get-AzRoleAssignment -Scope $StorageResourceId -ErrorAction Stop |
        Where-Object {
            [string] $_.ObjectId -ieq $PrincipalId.ToString() -and
            $_.RoleDefinitionName -in $requiredRoles -and
            ([string] $_.Scope).TrimEnd('/') -ieq $StorageResourceId.TrimEnd('/')
        })
    # If any remaining assignments are found, throw an error.
    if ($remainingAssignments.Count -gt 0) {
        throw "One or more obsolete Storage role assignments remain for managed identity '$PrincipalId'."
    }
}

function Get-MigrationIPv4Range {
    <#
    .SYNOPSIS
    Calculates the IPv4 address range for a given CIDR block.

    .PARAMETER Cidr
    The CIDR block for which to calculate the IPv4 range.

    .OUTPUTS
    A custom object with 'Start' and 'End' properties representing the IPv4 range.
    #>
    param([Parameter(Mandatory)][string] $Cidr)
    # Split the CIDR block into the base IP address and the prefix length.
    $parts = $Cidr.Split('/')
    if ($parts.Count -ne 2 -or $parts[1] -notmatch '^\d{1,2}$') {
        throw "Invalid VNet CIDR '$Cidr'."
    }
    # Parse the base IP address and validate the prefix length.
    $ip = [System.Net.IPAddress]::Parse($parts[0])

    $bytes = $ip.GetAddressBytes()
    if ($bytes.Length -ne 4) { return $null }
    $prefixLength = [int] $parts[1]
    if ($prefixLength -lt 0 -or $prefixLength -gt 32) {
        throw "Invalid IPv4 prefix length in '$Cidr'."
    }
    # Calculate the numeric representation of the IP address.
    $address = [uint64] $bytes[0] * 16777216 +
        [uint64] $bytes[1] * 65536 +
        [uint64] $bytes[2] * 256 +
        [uint64] $bytes[3]
    # Calculate the size of the address block and the network start address.
    $blockSize = [uint64] [math]::Pow(2, 32 - $prefixLength)
    # Calculate the network start address based on the block size.
    $networkStart = [uint64] ([math]::Floor($address / $blockSize) * $blockSize)
    # Return the calculated network range as a custom object.
    return [pscustomobject]@{
        Start = $networkStart
        End = $networkStart + $blockSize - 1
    }
}

function Assert-MigrationNetworkPrefix {
    <#
    .SYNOPSIS
    Asserts that the specified VNet CIDR is a valid private /24 network and does not overlap with existing VNets.

    .PARAMETER Cidr
    The CIDR block of the VNet to validate.

    .PARAMETER ExistingTargetVNetName
    The name of the existing target VNet to exclude from overlap checks.

    .PARAMETER ExistingTargetVNetResourceGroup
    The resource group of the existing target VNet to exclude from overlap checks.
    #>
    param(
        [Parameter(Mandatory)][string] $Cidr,
        [string] $ExistingTargetVNetName,
        [string] $ExistingTargetVNetResourceGroup
    )
    # Validate that the specified CIDR is a private /24 network and does not overlap with existing VNets.
    $candidate = Get-MigrationIPv4Range -Cidr $Cidr
    # Extract the base IP address and prefix length from the CIDR block.
    $baseAddress = [System.Net.IPAddress]::Parse(($Cidr -split '/')[0])
    # Get the individual octets of the base IP address.
    $octets = $baseAddress.GetAddressBytes()
    # Determine if the base IP address is within a private IP range.
    $isPrivate = $octets[0] -eq 10 -or
        ($octets[0] -eq 172 -and $octets[1] -ge 16 -and $octets[1] -le 31) -or
        ($octets[0] -eq 192 -and $octets[1] -eq 168)
    # Ensure the CIDR is a private /24 network and aligned to the network boundary.
    if (-not $isPrivate -or $Cidr -notmatch '^\d{1,3}(?:\.\d{1,3}){2}\.0/24$' -or
        $candidate.Start -ne (
            [uint64] $octets[0] * 16777216 +
            [uint64] $octets[1] * 65536 +
            [uint64] $octets[2] * 256
        )) {
        throw "VNet prefix '$Cidr' must be a private, network-aligned IPv4 /24."
    }
    # Retrieve all existing VNets in the subscription to check for overlapping CIDR blocks.
    $existingVnets = Get-AzVirtualNetwork -ErrorAction Stop
    # Iterate through each existing VNet and its address prefixes to check for overlaps.
    foreach ($vnet in $existingVnets) {
        # Skip the existing target VNet if specified.
        foreach ($existingCidr in $vnet.AddressSpace.AddressPrefixes) {
            # Check if the current existing CIDR overlaps with the candidate CIDR.
            if ($vnet.Name -eq $ExistingTargetVNetName -and
                $vnet.ResourceGroupName -eq $ExistingTargetVNetResourceGroup -and
                $existingCidr -eq $Cidr) {
                continue
            }
            # Convert the existing CIDR to a migration IPv4 range for overlap comparison.
            $existingRange = Get-MigrationIPv4Range -Cidr ([string] $existingCidr)
            # If the existing CIDR could not be converted to a range, skip the overlap check.
            if ($null -ne $existingRange -and
                $candidate.Start -le $existingRange.End -and
                $candidate.End -ge $existingRange.Start) {
                throw "VNet prefix '$Cidr' overlaps existing VNet '$($vnet.Name)' in resource group '$($vnet.ResourceGroupName)' ($existingCidr). Choose a different private /24."
            }
        }
    }
}

function Read-MigrationBackupForTarget {
    <#
    .SYNOPSIS
    Reads the migration backup for the target Function App.

    .PARAMETER Path
    The path to the migration backup file.
    #>
    param([Parameter(Mandatory)][string] $Path)
    # Read the migration backup for the target Function App from the specified path.
    Read-MigrationBackup `
        -Path $Path `
        -SubscriptionId $SubscriptionId `
        -TenantId $TenantId `
        -ResourceGroupName $ResourceGroupName `
        -FunctionAppName $FunctionAppName
}

# Retrieve the resource ID and context for the target Function App.
$resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName"
# Get the current Azure context and ensure it matches the target subscription and tenant.
$context = Get-AzContext
# If the current context does not match the target subscription and tenant, set the context accordingly.
if (-not $context -or
    [string] $context.Subscription.Id -ne $SubscriptionId.ToString() -or
    [string] $context.Tenant.Id -ne $TenantId.ToString()) {
    Set-AzContext -SubscriptionId $SubscriptionId -TenantId $TenantId -ErrorAction Stop | Out-Null
}
# Initialize variables for the target Function App and its migration backup.
$site = $null
$siteResponse = $null
$backupJson = $null
$resumeExistingFlex = $false
$sourceManagedIdentityId = $null
# Attempt to retrieve the existing Function App details from Azure.
try {
    $siteResponse = Invoke-MigrationArmRequest -Method GET `
        -Path "${resourceId}?api-version=2024-11-01"
    if ($siteResponse.StatusCode -eq 200) {
        $site = $siteResponse.Content | ConvertFrom-Json -ErrorAction Stop
    }
}
catch {
    if ($_.Exception.Message -notmatch '(?i)\b404\b|ResourceNotFound') { throw }
    # If the Function App does not exist (404), continue without throwing an error.
}
# If the Function App does not exist, read the migration backup to initialize the necessary variables.
if ($null -eq $site) {
    # Ensure that the migration backup path is provided and valid before attempting to read it.
    if ([string]::IsNullOrWhiteSpace($BackupPath) -or
        -not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        throw 'The source Function App is absent. Supply the migration backup using -BackupPath to resume.'
    }
    # Read the migration backup for the target Function App from the specified path.
    $backup = Read-MigrationBackupForTarget -Path $BackupPath
    $backupConfiguration = $backup.configuration
    $location = [string] $backup.location
    $customHostNames = @($backup.customHostNames)
    $planResourceId = [string] $backup.planResourceId
    # Initialize the virtual network address prefix from the backup if it was not provided as a parameter.
    if (-not $PSBoundParameters.ContainsKey('VirtualNetworkAddressPrefix')) {
        $VirtualNetworkAddressPrefix = [string] $backup.virtualNetworkAddressPrefix
    }
    # Mark that the source Function App was not present, as we are initializing from the backup.
    $sourceWasPresent = $false
}
else {
    # The source Function App exists, so retrieve its details and ensure it is in a valid state.
    $webApp = Get-AzWebApp -ResourceGroupName $ResourceGroupName -Name $FunctionAppName -ErrorAction Stop
    if ([string] $webApp.State -ne 'Running') {
        throw "Expected a running Function App, got state '$($webApp.State)'."
    }
    # Retrieve the hosting plan resource ID for the existing Function App.
    if ($webApp.Reserved -eq $true) {
        if ([string]::IsNullOrWhiteSpace($BackupPath)) {
            throw 'A Linux Flex Function App already exists. Supply its original migration backup using -BackupPath to resume safely.'
        }
        # Read the migration backup for the target Function App from the specified path.
        $backup = Read-MigrationBackupForTarget -Path $BackupPath
        $backupConfiguration = $backup.configuration
        $location = [string] $site.location
        $customHostNames = @($backup.customHostNames)
        $planResourceId = [string] $site.properties.serverFarmId
        # Validate that the hosting plan resource ID is in the expected format.
        if ($planResourceId -notmatch '/providers/Microsoft\.Web/serverfarms/[^/]+$') {
            throw 'The existing Flex Function App has no valid hosting plan resource ID.'
        }
        # Retrieve the details of the hosting plan using the Azure Resource Manager API.
        # Ensure that the hosting plan matches the expected configuration for a Linux Flex Function App.
        $planResponse = Invoke-MigrationArmRequest -Method GET `
            -Path "${planResourceId}?api-version=2024-11-01"
        $plan = $planResponse.Content | ConvertFrom-Json -ErrorAction Stop
        # Check that the retrieved hosting plan has the expected SKU, kind, and reserved properties for a Linux Flex Function App.
        if ($plan.sku.name -ne 'FC1' -or
            $plan.kind -notmatch 'functionapp' -or
            $plan.properties.reserved -ne $true) {
            throw "The existing Linux app does not use a Flex Consumption plan (found SKU '$($plan.sku.name)')."
        }
        # Initialize the virtual network address prefix from the backup if it was not provided as a parameter.
        if (-not $PSBoundParameters.ContainsKey('VirtualNetworkAddressPrefix')) {
            $VirtualNetworkAddressPrefix = [string] $backup.virtualNetworkAddressPrefix
        }
        # Retrieve the source managed identity ID from the backup.
        $sourceManagedIdentityId = [string] $backup['sourceManagedIdentityObjectId']
        $resumeExistingFlex = $true
        $sourceWasPresent = $false
    }
    else {
        # Retrieve the hosting plan resource ID for the existing Function App.
        $planResourceId = [string] $site.properties.serverFarmId
        # Validate that the hosting plan resource ID is in the expected format.
        if ($planResourceId -notmatch '/providers/Microsoft\.Web/serverfarms/[^/]+$') {
            throw 'The existing Function App has no valid hosting plan resource ID.'
        }
        # Retrieve the details of the hosting plan using the Azure Resource Manager API.
        $planResponse = Invoke-MigrationArmRequest -Method GET `
            -Path "${planResourceId}?api-version=2024-11-01"
        $plan = $planResponse.Content | ConvertFrom-Json -ErrorAction Stop
        # Ensure that the hosting plan matches the expected configuration for a Windows Y1 Function Consumption plan.
        if ($plan.sku.name -ne 'Y1' -or $plan.properties.reserved -eq $true -or
            $plan.kind -notmatch 'functionapp') {
            throw "Expected a Windows Y1 Function Consumption plan; found SKU '$($plan.sku.name)'."
        }
        # Ensure that the hosting plan is not shared with multiple sites.
        if ([int] $plan.properties.numberOfSites -gt 1) {
            throw "Hosting plan '$($plan.name)' has more than one site. Refusing to delete a shared plan."
        }
        # Retrieve the deployment slots for the existing Function App and ensure there are none.
        $slotsResponse = Invoke-MigrationArmRequest -Method GET `
            -Path "$resourceId/slots?api-version=2024-11-01"
        # Convert the response content to JSON and check if any deployment slots exist.
        if (@(($slotsResponse.Content | ConvertFrom-Json -ErrorAction Stop).value).Count -gt 0) {
            throw 'Deployment slots exist. Remove or migrate them separately before this operation.'
        }
        # Retrieve the location, custom host names, and backup configuration for the existing Function App.
        $location = [string] $site.location
        $customHostNames = @(Get-MigrationCustomHostNames -ResourceId $resourceId)
        $backupConfiguration = Read-MigrationSettings `
            -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ResourceGroupName `
            -FunctionAppName $FunctionAppName `
            -TenantId $TenantId
        # If the existing Function App has a managed identity, retrieve its principal ID.
        if ($null -ne $site.identity) {
            $sourceManagedIdentityId = [string] $site.identity.principalId
        }
        # Initialize the virtual network address prefix if it was not provided as a parameter.
        if ([string]::IsNullOrWhiteSpace($VirtualNetworkAddressPrefix)) {
            $VirtualNetworkAddressPrefix = '172.16.0.0/24'
        }
        # Determine the backup path for storing the migration backup document.
        $backupPath = if (-not [string]::IsNullOrWhiteSpace($BackupPath)) {
            [IO.Path]::GetFullPath($BackupPath)
        }
        else {
            Join-Path ([Environment]::GetFolderPath('MyDocuments')) `
                "AutopilotImport\migration-$FunctionAppName-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        }
        # Create the migration backup document with the collected information.
        $backupDocument = [ordered]@{
            format = 'autopilot-import-private-endpoint-migration'
            schemaVersion = 1
            createdAtUtc = [datetime]::UtcNow.ToString('o')
            subscriptionId = $SubscriptionId.ToString()
            tenantId = $TenantId.ToString()
            resourceGroupName = $ResourceGroupName
            functionAppName = $FunctionAppName
            location = $location
            planResourceId = $planResourceId
            virtualNetworkAddressPrefix = $VirtualNetworkAddressPrefix
            sourceManagedIdentityObjectId = $sourceManagedIdentityId
            customHostNames = $customHostNames
            configuration = $backupConfiguration
            retainedResources = @(
                $backupConfiguration.storageAccountName
                'configuration/tag-authorization-policy.json'
                'device-attribute-updates queue'
                'importaudit table'
            )
        }
        # Convert the migration backup document to JSON for storage.
        $backupJson = $backupDocument | ConvertTo-Json -Depth 12
        $sourceWasPresent = $true
    }
}
# Validate the existing storage account and network configuration before proceeding with the migration.
$storage = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName `
    -Name $backupConfiguration.storageAccountName -ErrorAction Stop
# Ensure that the retrieved storage account matches the expected configuration.
if ([string] $storage.StorageAccountName -ne $backupConfiguration.storageAccountName) {
    throw 'The existing Storage account does not match the deployment configuration.'
}
# Validate the virtual network address prefix before proceeding with the migration.
if ([string]::IsNullOrWhiteSpace($VirtualNetworkAddressPrefix)) {
    throw 'The migration backup does not specify a VNet address prefix. Supply -VirtualNetworkAddressPrefix.'
}
# Assert that the migration network prefix is correctly configured for the target environment.
Assert-MigrationNetworkPrefix `
    -Cidr $VirtualNetworkAddressPrefix `
    -ExistingTargetVNetName "vnet-$FunctionAppName" `
    -ExistingTargetVNetResourceGroup $ResourceGroupName
# Validate and retrieve the source managed identity ID if it was not provided.
if ([string]::IsNullOrWhiteSpace($sourceManagedIdentityId)) {
    $sourceManagedIdentityId = Get-MigrationSourceManagedIdentityId `
        -StorageResourceId ([string] $storage.Id)
}
# Parse and validate the source managed identity ID as a GUID.
$parsedSourceManagedIdentityId = [guid]::Empty
# Initialize the parsed source managed identity ID as an empty GUID.
if (-not [string]::IsNullOrWhiteSpace($sourceManagedIdentityId) -and
    -not [guid]::TryParse($sourceManagedIdentityId, [ref] $parsedSourceManagedIdentityId)) {
    throw "Invalid source managed identity object ID '$sourceManagedIdentityId'."
}
# Validate the custom host names and ensure that the user has accepted the custom domain certificate reissue if necessary.
if ($customHostNames.Count -gt 0 -and -not $AcceptCustomDomainCertificateReissue) {
    throw "Custom domains are bound ($($customHostNames -join ', ')). Re-run with -AcceptCustomDomainCertificateReissue after planning a manual Flex site-scoped certificate setup."
}
# Ensure that the migration backup path does not already exist to prevent accidental overwrites.
if ($sourceWasPresent -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
    throw "Migration backup '$backupPath' already exists. Choose a new -BackupPath so the original backup is never overwritten."
}
# Display the private endpoint migration plan to the user.
Write-Host "`nPrivate endpoint migration plan" -ForegroundColor Cyan
Write-Host "  Function app : $FunctionAppName (same name)"
Write-Host "  Existing plan: $planResourceId"
Write-Host "  Region       : $location"
Write-Host "  Storage      : $($backupConfiguration.storageAccountName) (retained; made private)"
Write-Host "  Flex VNet    : $VirtualNetworkAddressPrefix"
Write-Host "  Data         : policy blob, queues and importaudit table retained in place"
Write-Host "  Entra apps   : reused; API and SPA IDs preserved"
Write-Host "  Custom hosts : $(if ($customHostNames.Count) { $customHostNames -join ', ' } else { 'none' })"
Write-Host "  Backup       : $BackupPath"
Write-Host '  Downtime     : from Function App deletion until the Flex deployment and smoke test complete'
# Determine the action to take based on the current migration state.
$action = if ($sourceWasPresent) {
    'Delete the Windows Function App and Y1 plan, remove its Storage roles, then recreate as Linux Flex Consumption'
}
elseif ($resumeExistingFlex) {
    'Remove obsolete Storage roles for the old identity and resume deployment without deleting the existing Flex app or plan'
}
else {
    'Remove obsolete Storage roles for the old identity, delete any remaining source plan, then resume Linux Flex deployment from backup'
}
# Confirm with the user before proceeding with the determined action.
if (-not $PSCmdlet.ShouldProcess("$ResourceGroupName/$FunctionAppName", $action)) {
    return
}
# Perform the migration actions based on the user's confirmation.
if ($sourceWasPresent) {
    # Backup the current state before deleting the source Function App.
    $backupDirectory = Split-Path -Parent $backupPath
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    [IO.File]::WriteAllText($backupPath, $backupJson, [Text.UTF8Encoding]::new($false))
    Write-Host "Migration backup saved to '$BackupPath'."
    # Ensure that the backup was successfully created before proceeding with the deletion.
    $deleteSite = Invoke-MigrationArmRequest -Method DELETE `
        -Path "${resourceId}?api-version=2024-11-01"
    # Delete the source Function App using the ARM API.
    if ($deleteSite.StatusCode -ge 400) {
        throw "Function App deletion failed with HTTP $($deleteSite.StatusCode)."
    }
    # Wait for the source Function App to be fully deleted before proceeding.
    Wait-MigrationResourceDeleted -ResourceId $resourceId -ApiVersion '2024-11-01'
}
# Remove obsolete Storage role assignments for the source managed identity.
if ($null -ne $parsedSourceManagedIdentityId -and
    $parsedSourceManagedIdentityId -ne [guid]::Empty) {
    # Remove the Storage role assignments associated with the source managed identity.
    Remove-MigrationSourceStorageRoleAssignments `
        -StorageResourceId ([string] $storage.Id) `
        -PrincipalId $parsedSourceManagedIdentityId
}
# Delete the Y1 plan if it exists and the user has not opted to resume the existing Flex plan.
if (-not $resumeExistingFlex) {
    try {
        # Check if the Y1 plan exists before attempting to delete it.
        $planCheck = Invoke-MigrationArmRequest -Method GET `
            -Path "${planResourceId}?api-version=2024-11-01"
        # If the Y1 plan exists, proceed to delete it.
        if ($planCheck.StatusCode -eq 200) {
            $deletePlan = Invoke-MigrationArmRequest -Method DELETE `
                -Path "${planResourceId}?api-version=2024-11-01"
            if ($deletePlan.StatusCode -ge 400) {
                throw "Y1 plan deletion failed with HTTP $($deletePlan.StatusCode)."
            }
            # Wait for the Y1 plan to be fully deleted before proceeding.
            Wait-MigrationResourceDeleted -ResourceId $planResourceId -ApiVersion '2024-11-01'
        }
    }
    catch {
        if ($_.Exception.Message -notmatch '(?i)\b404\b|ResourceNotFound') { throw }
    }
}
# Prepare to recreate the Function App with the standard private Flex infrastructure.
$installerPath = Join-Path $PSScriptRoot '..\Installer\Install-AutopilotImport.ps1'
# Ensure that the regular installer script exists before attempting to run it.
if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    throw "The regular installer was not found at '$installerPath'. The backup is available at '$BackupPath'."
}
# Determine the path to the client's tools directory, defaulting to the Documents folder if not specified.
$documentsPath = [Environment]::GetFolderPath('MyDocuments')
# If the Documents folder path is not available, fall back to the user's home directory.
if ([string]::IsNullOrWhiteSpace($documentsPath)) { $documentsPath = $HOME }
$resolvedClientToolsPath = if (-not [string]::IsNullOrWhiteSpace($ClientToolsPath)) {
    $ClientToolsPath
}
else {
    Join-Path $documentsPath 'AutopilotImport'
}
# Prepare the parameters for the installer script.
$installerParameters = @{
    SubscriptionId = $SubscriptionId.ToString()
    TenantId = $TenantId.ToString()
    ResourceGroupName = $ResourceGroupName
    Location = $location
    FunctionAppName = $FunctionAppName
    EntraClientId = $backupConfiguration.entraClientId
    WebClientId = [guid] $backupConfiguration.webClientId
    InstallerPrincipalId = [guid] $backupConfiguration.installerPrincipalId
    ApiAudience = $backupConfiguration.apiAudience
    DeviceTagExtensionAttribute = $backupConfiguration.deviceTagExtensionAttribute
    TagManagerPrincipalId = @($backupConfiguration.managerPrincipalIds | ForEach-Object { [guid] $_ })
    TagAuthorizationPolicyFallback = $backupConfiguration.tagAuthorizationPolicy
    ManagerAuthorizationPolicyJson = $backupConfiguration.managerPolicy
    VirtualNetworkAddressPrefix = $VirtualNetworkAddressPrefix
    ClientToolsPath = $resolvedClientToolsPath
    SkipExistingDeploymentDetection = $true
    SkipEntraAppConfiguration = $true
    InstallMissingModules = $InstallMissingModules
    ForceGraphSignIn = $ForceGraphSignIn
    GraphAccessToken = $GraphAccessToken
}
# Add custom host names to the installer parameters if any are specified.
if ($customHostNames.Count -gt 0) {
    $installerParameters.AdditionalWebRedirectUri = @(
        $customHostNames | ForEach-Object { "https://$_/api/ui/index.html" }
    )
}

Write-Host 'Recreating the Function App with the standard private Flex infrastructure...'
# Invoke the installer script with the prepared parameters to recreate the Function App.
$installerResult = & $installerPath @installerParameters -Confirm:$false
if (-not $installerResult) {
    throw "The installer did not return a deployment result. Resume with -BackupPath '$BackupPath'."
}
# Verify that the Function App and its associated resources have been correctly recreated.
$newSite = Get-AzWebApp -ResourceGroupName $ResourceGroupName `
    -Name $FunctionAppName -ErrorAction Stop
# Check if the Function App is marked as Linux-reserved.
if ($newSite.Reserved -ne $true) {
    throw "Migration completed but the recreated Function App is not marked as Linux-reserved."
}
# Verify that the associated Storage account has the required private configuration.
$verifiedStorage = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName `
    -Name $backupConfiguration.storageAccountName -ErrorAction Stop
# Check if the Storage account has public network access disabled and shared key access disabled.
if ($verifiedStorage.PublicNetworkAccess -ne 'Disabled' -or
    $verifiedStorage.AllowSharedKeyAccess -ne $false) {
    throw 'The Function App was recreated, but Storage did not reach the required private configuration.'
}
# Output a completion message indicating that the private endpoint migration has finished successfully.
Write-Host "`nPrivate endpoint migration completed." -ForegroundColor Green
Write-Host "  Function URL : https://$FunctionAppName.azurewebsites.net/api/ui/index.html"
Write-Host "  Backup       : $BackupPath"
# Warn the user if there are custom host names that need to be manually configured.
if ($customHostNames.Count -gt 0) {
    Write-Warning "Custom domains are not bound to the new Flex app. In Azure Portal, add $($customHostNames -join ', ') under Custom domains, then create and bind a site-scoped certificate. Microsoft documents no automatic certificate migration path for pre-existing apps."
}
