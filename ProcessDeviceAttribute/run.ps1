# Project-Version: 1.0.20260826.1
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
.SYNOPSIS
Completes the Entra configuration of an imported Autopilot device.

.DESCRIPTION
Processes queued Autopilot imports after Intune has created the Entra device.
It writes the authorized Group Tag to an extension attribute and optionally
adds the device to a restricted management administrative unit. An incomplete
import throws so the Storage Queue trigger retries it according to host.json.
Successful updates are idempotent.
#>

param($QueueItem, $TriggerMetadata)

$modulePath = Join-Path $PSScriptRoot '..\src\AutopilotImport\AutopilotImport.psm1'
Import-Module $modulePath -Force

$message = if ($QueueItem -is [string]) {
    $QueueItem | ConvertFrom-Json
}
else {
    $QueueItem
}
$importId = [guid]::Empty
if (-not [guid]::TryParse([string] $message.importId, [ref] $importId)) {
    throw 'Queued Autopilot import ID is invalid.'
}
$groupTag = [string] $message.groupTag
if ([string]::IsNullOrWhiteSpace($groupTag)) {
    throw "Queued Group Tag is missing for import '$importId'."
}
$extensionAttribute = if ([string]::IsNullOrWhiteSpace($env:DEVICE_TAG_EXTENSION_ATTRIBUTE)) {
    'extensionAttribute1'
}
else {
    $env:DEVICE_TAG_EXTENSION_ATTRIBUTE
}
$payload = ConvertTo-EntraDeviceExtensionAttributes `
    -ExtensionAttribute $extensionAttribute `
    -GroupTag $groupTag

$tokenResult = Get-AzAccessToken `
    -ResourceUrl 'https://graph.microsoft.com/' `
    -ErrorAction Stop
$accessToken = if ($tokenResult.Token -is [Security.SecureString]) {
    ConvertFrom-SecureString -SecureString $tokenResult.Token -AsPlainText
}
else {
    [string] $tokenResult.Token
}
$secureToken = ConvertTo-SecureString $accessToken -AsPlainText -Force
$importedDevice = Invoke-RestMethod `
    -Method Get `
    -Uri "https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities/$importId" `
    -Authentication Bearer `
    -Token $secureToken `
    -ErrorAction Stop
$registrationId = Get-AutopilotDeviceRegistrationId `
    -ImportedDevice $importedDevice
$registeredDevice = Invoke-RestMethod `
    -Method Get `
    -Uri "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$registrationId" `
    -Authentication Bearer `
    -Token $secureToken `
    -ErrorAction Stop
$entraDeviceId = [guid]::Empty
if (-not [guid]::TryParse(
        [string] $registeredDevice.azureActiveDirectoryDeviceId,
        [ref] $entraDeviceId)) {
    throw "Entra device is not available yet for Autopilot import '$importId'."
}

$restrictedManagementAdministrativeUnitName = [string] `
    $message.restrictedManagementAdministrativeUnitName
$deviceObjectId = [guid]::Empty
if (-not [string]::IsNullOrWhiteSpace(
        $restrictedManagementAdministrativeUnitName)) {
    $entraDevice = Invoke-RestMethod `
        -Method Get `
        -Uri "https://graph.microsoft.com/v1.0/devices(deviceId='$entraDeviceId')?`$select=id" `
        -Authentication Bearer `
        -Token $secureToken `
        -ErrorAction Stop
    if (-not [guid]::TryParse([string] $entraDevice.id, [ref] $deviceObjectId)) {
        throw "Entra device object ID is unavailable for device '$entraDeviceId'."
    }

    $existingMembership = `
        Add-EntraDeviceToRestrictedManagementAdministrativeUnit `
            -AdministrativeUnitName `
                $restrictedManagementAdministrativeUnitName `
            -DeviceObjectId $deviceObjectId `
            -AccessToken $secureToken `
            -TestOnly
    if ($existingMembership.IsMember) {
        Write-Information "Entra device '$entraDeviceId' is already a member of restricted management administrative unit '$restrictedManagementAdministrativeUnitName'."
        return
    }
}

Invoke-RestMethod `
    -Method Patch `
    -Uri "https://graph.microsoft.com/v1.0/devices(deviceId='$entraDeviceId')" `
    -Authentication Bearer `
    -Token $secureToken `
    -ContentType 'application/json' `
    -Body ($payload | ConvertTo-Json -Depth 4 -Compress) `
    -ErrorAction Stop | Out-Null

Write-Information "Autopilot Group Tag '$groupTag' written to $extensionAttribute on Entra device '$entraDeviceId'."

if (-not [string]::IsNullOrWhiteSpace(
        $restrictedManagementAdministrativeUnitName)) {
    $membershipResult = `
        Add-EntraDeviceToRestrictedManagementAdministrativeUnit `
            -AdministrativeUnitName `
                $restrictedManagementAdministrativeUnitName `
            -DeviceObjectId $deviceObjectId `
            -AccessToken $secureToken
    $membershipAction = if ($membershipResult.MembershipAdded) {
        'added to'
    }
    else {
        'already a member of'
    }
    Write-Information "Entra device '$entraDeviceId' $membershipAction restricted management administrative unit '$restrictedManagementAdministrativeUnitName'."
}