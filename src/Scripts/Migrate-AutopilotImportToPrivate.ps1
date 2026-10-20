#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Resources, Az.Websites, Az.Storage
# Project-Version: 1.4.20261020.14
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
if ($ForceGraphSignIn -and $GraphAccessToken) {
    throw 'Specify either -ForceGraphSignIn or -GraphAccessToken, not both.'
}

function Invoke-MigrationArmRequest {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'DELETE')][string] $Method,
        [Parameter(Mandatory)][string] $Path
    )

    Invoke-AzRestMethod -Method $Method -Path $Path -WhatIf:$false -ErrorAction Stop
}

function Wait-MigrationResourceDeleted {
    param(
        [Parameter(Mandatory)][string] $ResourceId,
        [Parameter(Mandatory)][string] $ApiVersion,
        [int] $TimeoutSeconds = 300
    )

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $response = Invoke-MigrationArmRequest -Method GET `
                -Path "${ResourceId}?api-version=$ApiVersion"
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
    param([Parameter(Mandatory)][string] $ResourceId)

    $response = Invoke-MigrationArmRequest -Method GET `
        -Path "$ResourceId/hostNameBindings?api-version=2024-11-01"
    if ($response.StatusCode -ge 400) {
        throw "Unable to read existing custom hostnames (HTTP $($response.StatusCode))."
    }
    $document = $response.Content | ConvertFrom-Json -ErrorAction Stop
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
    param(
        [Parameter(Mandatory)][guid] $SubscriptionId,
        [Parameter(Mandatory)][string] $ResourceGroupName,
        [Parameter(Mandatory)][string] $FunctionAppName,
        [Parameter(Mandatory)][guid] $TenantId
    )

    $resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName"
    $response = Invoke-MigrationArmRequest -Method POST `
        -Path "$resourceId/config/appsettings/list?api-version=2023-12-01"
    if ($response.StatusCode -ne 200) {
        throw "Unable to read the existing Function App settings (HTTP $($response.StatusCode))."
    }
    $document = $response.Content | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $document.properties) {
        throw 'The Function App settings response has no properties object.'
    }
    $settings = $document.properties
    $audience = [string] $settings.API_AUDIENCE
    $clientId = [guid]::Empty
    if ($audience -notmatch '^api://' -or
        -not [guid]::TryParse(($audience -replace '^api://', ''), [ref] $clientId)) {
        throw 'API_AUDIENCE is missing or does not use the api://<client-guid> format.'
    }
    $webClientId = [guid]::Empty
    if (-not [guid]::TryParse([string] $settings.WEB_CLIENT_ID, [ref] $webClientId)) {
        throw 'WEB_CLIENT_ID is missing or invalid.'
    }
    if ([guid] $settings.TENANT_ID -ne $TenantId) {
        throw 'The configured TENANT_ID does not match the requested tenant.'
    }
    $tagFallback = [string] $settings.TAG_AUTHORIZATION_POLICY
    if ([string]::IsNullOrWhiteSpace($tagFallback)) { $tagFallback = '[]' }
    try {
        $null = $tagFallback | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "TAG_AUTHORIZATION_POLICY is not valid JSON: $($_.Exception.Message)"
    }

    $managerPolicyJson = [string] $settings.MANAGER_AUTHORIZATION_POLICY
    if ([string]::IsNullOrWhiteSpace($managerPolicyJson)) {
        throw 'MANAGER_AUTHORIZATION_POLICY is missing. Refusing to migrate without preserving policy administration.'
    }
    try {
        $managerPolicy = $managerPolicyJson | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        throw "MANAGER_AUTHORIZATION_POLICY is not valid JSON: $($_.Exception.Message)"
    }
    $installerId = [guid]::Empty
    if ($managerPolicy -isnot [System.Collections.IDictionary] -or
        -not [guid]::TryParse([string] $managerPolicy.installerPrincipalId, [ref] $installerId) -or
        $managerPolicy.additionalPrincipalIds -isnot [array] -or
        $managerPolicy.allowIntuneRoleAdministrators -isnot [bool]) {
        throw 'MANAGER_AUTHORIZATION_POLICY is missing a valid installer principal, manager array, or Intune administrator setting.'
    }
    foreach ($principalId in $managerPolicy.additionalPrincipalIds) {
        $parsedId = [guid]::Empty
        if (-not [guid]::TryParse([string] $principalId, [ref] $parsedId)) {
            throw "Invalid manager object ID in MANAGER_AUTHORIZATION_POLICY: '$principalId'."
        }
    }
    $storageAccountName = [string] $settings.AzureWebJobsStorage__accountName
    if ($storageAccountName -notmatch '^[a-z0-9]{3,24}$') {
        throw 'AzureWebJobsStorage__accountName is missing or invalid.'
    }
    $extensionAttribute = [string] $settings.DEVICE_TAG_EXTENSION_ATTRIBUTE
    if ([string]::IsNullOrWhiteSpace($extensionAttribute)) {
        $extensionAttribute = 'extensionAttribute1'
    }
    if ($extensionAttribute -notmatch '^extensionAttribute(?:[1-9]|1[0-5])$') {
        throw "Invalid DEVICE_TAG_EXTENSION_ATTRIBUTE '$extensionAttribute'."
    }

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
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][guid] $SubscriptionId,
        [Parameter(Mandatory)][guid] $TenantId,
        [Parameter(Mandatory)][string] $ResourceGroupName,
        [Parameter(Mandatory)][string] $FunctionAppName
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Migration backup '$Path' was not found."
    }
    $backup = Get-Content -LiteralPath $Path -Raw |
        ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($backup.format -cne 'autopilot-import-private-endpoint-migration' -or
        $backup.schemaVersion -ne 1 -or
        $backup.subscriptionId -ne $SubscriptionId.ToString() -or
        $backup.tenantId -ne $TenantId.ToString() -or
        $backup.resourceGroupName -ne $ResourceGroupName -or
        $backup.functionAppName -ne $FunctionAppName -or
        $backup.configuration -isnot [System.Collections.IDictionary]) {
        throw 'The supplied migration backup does not match this target or has an unsupported format.'
    }
    return $backup
}

function Get-MigrationSourceManagedIdentityId {
    param(
        [Parameter(Mandatory)][string] $StorageResourceId,
        [string] $KnownPrincipalId
    )

    if (-not [string]::IsNullOrWhiteSpace($KnownPrincipalId)) {
        $parsedId = [guid]::Empty
        if (-not [guid]::TryParse($KnownPrincipalId, [ref] $parsedId)) {
            throw "Invalid source managed identity object ID '$KnownPrincipalId'."
        }
        return $parsedId.ToString()
    }

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

    $candidates = @($assignments | Group-Object ObjectId | Where-Object {
        $assignedRoles = @($_.Group | ForEach-Object { [string] $_.RoleDefinitionName })
        @($requiredRoles | Where-Object { $_ -notin $assignedRoles }).Count -eq 0
    })
    if ($candidates.Count -ne 1) {
        throw 'Could not uniquely identify the old Function managed identity from its complete set of Storage roles. No role assignments were changed.'
    }
    return [string] $candidates[0].Name
}

function Remove-MigrationSourceStorageRoleAssignments {
    param(
        [Parameter(Mandatory)][string] $StorageResourceId,
        [Parameter(Mandatory)][guid] $PrincipalId
    )

    $requiredRoles = @(
        'Storage Blob Data Owner'
        'Storage Queue Data Contributor'
        'Storage Table Data Contributor'
    )
    $assignments = @(Get-AzRoleAssignment -Scope $StorageResourceId -ErrorAction Stop |
        Where-Object {
            [string] $_.ObjectId -ieq $PrincipalId.ToString() -and
            $_.RoleDefinitionName -in $requiredRoles -and
            ([string] $_.Scope).TrimEnd('/') -ieq $StorageResourceId.TrimEnd('/')
        })
    foreach ($assignment in $assignments) {
        Remove-AzRoleAssignment `
            -ObjectId $PrincipalId.ToString() `
            -RoleDefinitionName $assignment.RoleDefinitionName `
            -Scope $StorageResourceId `
            -Confirm:$false `
            -ErrorAction Stop |
            Out-Null
    }

    $remainingAssignments = @(Get-AzRoleAssignment -Scope $StorageResourceId -ErrorAction Stop |
        Where-Object {
            [string] $_.ObjectId -ieq $PrincipalId.ToString() -and
            $_.RoleDefinitionName -in $requiredRoles -and
            ([string] $_.Scope).TrimEnd('/') -ieq $StorageResourceId.TrimEnd('/')
        })
    if ($remainingAssignments.Count -gt 0) {
        throw "One or more obsolete Storage role assignments remain for managed identity '$PrincipalId'."
    }
}

function Get-MigrationIPv4Range {
    param([Parameter(Mandatory)][string] $Cidr)

    $parts = $Cidr.Split('/')
    if ($parts.Count -ne 2 -or $parts[1] -notmatch '^\d{1,2}$') {
        throw "Invalid VNet CIDR '$Cidr'."
    }
    $ip = [System.Net.IPAddress]::Parse($parts[0])
    $bytes = $ip.GetAddressBytes()
    if ($bytes.Length -ne 4) { return $null }
    $prefixLength = [int] $parts[1]
    if ($prefixLength -lt 0 -or $prefixLength -gt 32) {
        throw "Invalid IPv4 prefix length in '$Cidr'."
    }
    $address = [uint64] $bytes[0] * 16777216 +
        [uint64] $bytes[1] * 65536 +
        [uint64] $bytes[2] * 256 +
        [uint64] $bytes[3]
    $blockSize = [uint64] [math]::Pow(2, 32 - $prefixLength)
    $networkStart = [uint64] ([math]::Floor($address / $blockSize) * $blockSize)
    return [pscustomobject]@{
        Start = $networkStart
        End = $networkStart + $blockSize - 1
    }
}

function Assert-MigrationNetworkPrefix {
    param(
        [Parameter(Mandatory)][string] $Cidr,
        [string] $ExistingTargetVNetName,
        [string] $ExistingTargetVNetResourceGroup
    )

    $candidate = Get-MigrationIPv4Range -Cidr $Cidr
    $baseAddress = [System.Net.IPAddress]::Parse(($Cidr -split '/')[0])
    $octets = $baseAddress.GetAddressBytes()
    $isPrivate = $octets[0] -eq 10 -or
        ($octets[0] -eq 172 -and $octets[1] -ge 16 -and $octets[1] -le 31) -or
        ($octets[0] -eq 192 -and $octets[1] -eq 168)
    if (-not $isPrivate -or $Cidr -notmatch '^\d{1,3}(?:\.\d{1,3}){2}\.0/24$' -or
        $candidate.Start -ne (
            [uint64] $octets[0] * 16777216 +
            [uint64] $octets[1] * 65536 +
            [uint64] $octets[2] * 256
        )) {
        throw "VNet prefix '$Cidr' must be a private, network-aligned IPv4 /24."
    }

    $existingVnets = Get-AzVirtualNetwork -ErrorAction Stop
    foreach ($vnet in $existingVnets) {
        foreach ($existingCidr in $vnet.AddressSpace.AddressPrefixes) {
            if ($vnet.Name -eq $ExistingTargetVNetName -and
                $vnet.ResourceGroupName -eq $ExistingTargetVNetResourceGroup -and
                $existingCidr -eq $Cidr) {
                continue
            }
            $existingRange = Get-MigrationIPv4Range -Cidr ([string] $existingCidr)
            if ($null -ne $existingRange -and
                $candidate.Start -le $existingRange.End -and
                $candidate.End -ge $existingRange.Start) {
                throw "VNet prefix '$Cidr' overlaps existing VNet '$($vnet.Name)' in resource group '$($vnet.ResourceGroupName)' ($existingCidr). Choose a different private /24."
            }
        }
    }
}

function Read-MigrationBackupForTarget {
    param([Parameter(Mandatory)][string] $Path)

    Read-MigrationBackup `
        -Path $Path `
        -SubscriptionId $SubscriptionId `
        -TenantId $TenantId `
        -ResourceGroupName $ResourceGroupName `
        -FunctionAppName $FunctionAppName
}

$resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName"
$context = Get-AzContext
if (-not $context -or
    [string] $context.Subscription.Id -ne $SubscriptionId.ToString() -or
    [string] $context.Tenant.Id -ne $TenantId.ToString()) {
    Set-AzContext -SubscriptionId $SubscriptionId -TenantId $TenantId -ErrorAction Stop | Out-Null
}

$site = $null
$siteResponse = $null
$backupJson = $null
$resumeExistingFlex = $false
$sourceManagedIdentityId = $null
try {
    $siteResponse = Invoke-MigrationArmRequest -Method GET `
        -Path "${resourceId}?api-version=2024-11-01"
    if ($siteResponse.StatusCode -eq 200) {
        $site = $siteResponse.Content | ConvertFrom-Json -ErrorAction Stop
    }
}
catch {
    if ($_.Exception.Message -notmatch '(?i)\b404\b|ResourceNotFound') { throw }
}

if ($null -eq $site) {
    if ([string]::IsNullOrWhiteSpace($BackupPath) -or
        -not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        throw 'The source Function App is absent. Supply the migration backup using -BackupPath to resume.'
    }
    $backup = Read-MigrationBackupForTarget -Path $BackupPath
    $backupConfiguration = $backup.configuration
    $location = [string] $backup.location
    $customHostNames = @($backup.customHostNames)
    $planResourceId = [string] $backup.planResourceId
    if (-not $PSBoundParameters.ContainsKey('VirtualNetworkAddressPrefix')) {
        $VirtualNetworkAddressPrefix = [string] $backup.virtualNetworkAddressPrefix
    }
    $sourceWasPresent = $false
}
else {
    $webApp = Get-AzWebApp -ResourceGroupName $ResourceGroupName -Name $FunctionAppName -ErrorAction Stop
    if ([string] $webApp.State -ne 'Running') {
        throw "Expected a running Function App, got state '$($webApp.State)'."
    }
    if ($webApp.Reserved -eq $true) {
        if ([string]::IsNullOrWhiteSpace($BackupPath)) {
            throw 'A Linux Flex Function App already exists. Supply its original migration backup using -BackupPath to resume safely.'
        }
        $backup = Read-MigrationBackupForTarget -Path $BackupPath
        $backupConfiguration = $backup.configuration
        $location = [string] $site.location
        $customHostNames = @($backup.customHostNames)
        $planResourceId = [string] $site.properties.serverFarmId
        if ($planResourceId -notmatch '/providers/Microsoft\.Web/serverfarms/[^/]+$') {
            throw 'The existing Flex Function App has no valid hosting plan resource ID.'
        }
        $planResponse = Invoke-MigrationArmRequest -Method GET `
            -Path "${planResourceId}?api-version=2024-11-01"
        $plan = $planResponse.Content | ConvertFrom-Json -ErrorAction Stop
        if ($plan.sku.name -ne 'FC1' -or
            $plan.kind -notmatch 'functionapp' -or
            $plan.properties.reserved -ne $true) {
            throw "The existing Linux app does not use a Flex Consumption plan (found SKU '$($plan.sku.name)')."
        }
        if (-not $PSBoundParameters.ContainsKey('VirtualNetworkAddressPrefix')) {
            $VirtualNetworkAddressPrefix = [string] $backup.virtualNetworkAddressPrefix
        }
        $sourceManagedIdentityId = [string] $backup['sourceManagedIdentityObjectId']
        $resumeExistingFlex = $true
        $sourceWasPresent = $false
    }
    else {
        $planResourceId = [string] $site.properties.serverFarmId
        if ($planResourceId -notmatch '/providers/Microsoft\.Web/serverfarms/[^/]+$') {
            throw 'The existing Function App has no valid hosting plan resource ID.'
        }
        $planResponse = Invoke-MigrationArmRequest -Method GET `
            -Path "${planResourceId}?api-version=2024-11-01"
        $plan = $planResponse.Content | ConvertFrom-Json -ErrorAction Stop
        if ($plan.sku.name -ne 'Y1' -or $plan.properties.reserved -eq $true -or
            $plan.kind -notmatch 'functionapp') {
            throw "Expected a Windows Y1 Function Consumption plan; found SKU '$($plan.sku.name)'."
        }
        if ([int] $plan.properties.numberOfSites -gt 1) {
            throw "Hosting plan '$($plan.name)' has more than one site. Refusing to delete a shared plan."
        }
        $slotsResponse = Invoke-MigrationArmRequest -Method GET `
            -Path "$resourceId/slots?api-version=2024-11-01"
        if (@(($slotsResponse.Content | ConvertFrom-Json -ErrorAction Stop).value).Count -gt 0) {
            throw 'Deployment slots exist. Remove or migrate them separately before this operation.'
        }
        $location = [string] $site.location
        $customHostNames = @(Get-MigrationCustomHostNames -ResourceId $resourceId)
        $backupConfiguration = Read-MigrationSettings `
            -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ResourceGroupName `
            -FunctionAppName $FunctionAppName `
            -TenantId $TenantId
        if ($null -ne $site.identity) {
            $sourceManagedIdentityId = [string] $site.identity.principalId
        }
        if ([string]::IsNullOrWhiteSpace($VirtualNetworkAddressPrefix)) {
            $VirtualNetworkAddressPrefix = '172.16.0.0/24'
        }
        $backupPath = if (-not [string]::IsNullOrWhiteSpace($BackupPath)) {
            [IO.Path]::GetFullPath($BackupPath)
        }
        else {
            Join-Path ([Environment]::GetFolderPath('MyDocuments')) `
                "AutopilotImport\migration-$FunctionAppName-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        }
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
        $backupJson = $backupDocument | ConvertTo-Json -Depth 12
        $sourceWasPresent = $true
    }
}

$storage = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName `
    -Name $backupConfiguration.storageAccountName -ErrorAction Stop
if ([string] $storage.StorageAccountName -ne $backupConfiguration.storageAccountName) {
    throw 'The existing Storage account does not match the deployment configuration.'
}
if ([string]::IsNullOrWhiteSpace($VirtualNetworkAddressPrefix)) {
    throw 'The migration backup does not specify a VNet address prefix. Supply -VirtualNetworkAddressPrefix.'
}
Assert-MigrationNetworkPrefix `
    -Cidr $VirtualNetworkAddressPrefix `
    -ExistingTargetVNetName "vnet-$FunctionAppName" `
    -ExistingTargetVNetResourceGroup $ResourceGroupName

if ([string]::IsNullOrWhiteSpace($sourceManagedIdentityId)) {
    $sourceManagedIdentityId = Get-MigrationSourceManagedIdentityId `
        -StorageResourceId ([string] $storage.Id)
}
$parsedSourceManagedIdentityId = [guid]::Empty
if (-not [string]::IsNullOrWhiteSpace($sourceManagedIdentityId) -and
    -not [guid]::TryParse($sourceManagedIdentityId, [ref] $parsedSourceManagedIdentityId)) {
    throw "Invalid source managed identity object ID '$sourceManagedIdentityId'."
}

if ($customHostNames.Count -gt 0 -and -not $AcceptCustomDomainCertificateReissue) {
    throw "Custom domains are bound ($($customHostNames -join ', ')). Re-run with -AcceptCustomDomainCertificateReissue after planning a manual Flex site-scoped certificate setup."
}
if ($sourceWasPresent -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
    throw "Migration backup '$backupPath' already exists. Choose a new -BackupPath so the original backup is never overwritten."
}

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

$action = if ($sourceWasPresent) {
    'Delete the Windows Function App and Y1 plan, remove its Storage roles, then recreate as Linux Flex Consumption'
}
elseif ($resumeExistingFlex) {
    'Remove obsolete Storage roles for the old identity and resume deployment without deleting the existing Flex app or plan'
}
else {
    'Remove obsolete Storage roles for the old identity, delete any remaining source plan, then resume Linux Flex deployment from backup'
}
if (-not $PSCmdlet.ShouldProcess("$ResourceGroupName/$FunctionAppName", $action)) {
    return
}

if ($sourceWasPresent) {
    $backupDirectory = Split-Path -Parent $backupPath
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    [IO.File]::WriteAllText($backupPath, $backupJson, [Text.UTF8Encoding]::new($false))
    Write-Host "Migration backup saved to '$BackupPath'."
    $deleteSite = Invoke-MigrationArmRequest -Method DELETE `
        -Path "${resourceId}?api-version=2024-11-01"
    if ($deleteSite.StatusCode -ge 400) {
        throw "Function App deletion failed with HTTP $($deleteSite.StatusCode)."
    }
    Wait-MigrationResourceDeleted -ResourceId $resourceId -ApiVersion '2024-11-01'
}

if ($null -ne $parsedSourceManagedIdentityId -and
    $parsedSourceManagedIdentityId -ne [guid]::Empty) {
    Remove-MigrationSourceStorageRoleAssignments `
        -StorageResourceId ([string] $storage.Id) `
        -PrincipalId $parsedSourceManagedIdentityId
}

if (-not $resumeExistingFlex) {
    try {
        $planCheck = Invoke-MigrationArmRequest -Method GET `
            -Path "${planResourceId}?api-version=2024-11-01"
        if ($planCheck.StatusCode -eq 200) {
            $deletePlan = Invoke-MigrationArmRequest -Method DELETE `
                -Path "${planResourceId}?api-version=2024-11-01"
            if ($deletePlan.StatusCode -ge 400) {
                throw "Y1 plan deletion failed with HTTP $($deletePlan.StatusCode)."
            }
            Wait-MigrationResourceDeleted -ResourceId $planResourceId -ApiVersion '2024-11-01'
        }
    }
    catch {
        if ($_.Exception.Message -notmatch '(?i)\b404\b|ResourceNotFound') { throw }
    }
}

$installerPath = Join-Path $PSScriptRoot '..\Installer\Install-AutopilotImport.ps1'
if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    throw "The regular installer was not found at '$installerPath'. The backup is available at '$BackupPath'."
}
$documentsPath = [Environment]::GetFolderPath('MyDocuments')
if ([string]::IsNullOrWhiteSpace($documentsPath)) { $documentsPath = $HOME }
$resolvedClientToolsPath = if (-not [string]::IsNullOrWhiteSpace($ClientToolsPath)) {
    $ClientToolsPath
}
else {
    Join-Path $documentsPath 'AutopilotImport'
}
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
if ($customHostNames.Count -gt 0) {
    $installerParameters.AdditionalWebRedirectUri = @(
        $customHostNames | ForEach-Object { "https://$_/api/ui/index.html" }
    )
}

Write-Host 'Recreating the Function App with the standard private Flex infrastructure...'
$installerResult = & $installerPath @installerParameters -Confirm:$false
if (-not $installerResult) {
    throw "The installer did not return a deployment result. Resume with -BackupPath '$BackupPath'."
}

$newSite = Get-AzWebApp -ResourceGroupName $ResourceGroupName `
    -Name $FunctionAppName -ErrorAction Stop
if ($newSite.Reserved -ne $true) {
    throw "Migration completed but the recreated Function App is not marked as Linux-reserved."
}
$verifiedStorage = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName `
    -Name $backupConfiguration.storageAccountName -ErrorAction Stop
if ($verifiedStorage.PublicNetworkAccess -ne 'Disabled' -or
    $verifiedStorage.AllowSharedKeyAccess -ne $false) {
    throw 'The Function App was recreated, but Storage did not reach the required private configuration.'
}

Write-Host "`nPrivate endpoint migration completed." -ForegroundColor Green
Write-Host "  Function URL : https://$FunctionAppName.azurewebsites.net/api/ui/index.html"
Write-Host "  Backup       : $BackupPath"
if ($customHostNames.Count -gt 0) {
    Write-Warning "Custom domains are not bound to the new Flex app. In Azure Portal, add $($customHostNames -join ', ') under Custom domains, then create and bind a site-scoped certificate. Microsoft documents no automatic certificate migration path for pre-existing apps."
}
