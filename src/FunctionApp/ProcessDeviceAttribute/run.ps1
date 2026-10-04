# Project-Version: 1.2.20261004.1
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
.SYNOPSIS
Completes the Entra configuration of an imported Autopilot device.

.DESCRIPTION
Processes queued Autopilot imports after Intune has created the Entra device.
It writes the authorized Group Tag to an extension attribute and optionally
adds the device to a regular or restricted management administrative unit. An incomplete
import throws so the Storage Queue trigger retries it according to host.json.
Successful updates are idempotent.

.PARAMETER QueueItem
Message supplied by the Azure Storage Queue trigger. The value may be a JSON
string or a deserialized object and must contain importId and groupTag. It may
also contain administrativeUnitName.

.PARAMETER TriggerMetadata
Metadata supplied by the Azure Functions PowerShell worker for the queue
invocation. The current implementation does not read this value directly.

.PARAMETER TagPolicyBlob
Current Group Tag authorization policy from the private configuration blob.
The queued administrative unit name remains a fallback for older messages.

.INPUTS
None. Azure Functions binds QueueItem and TriggerMetadata at runtime.

.OUTPUTS
None. Processing progress is written to the information stream. Throwing an
exception marks the queue invocation as failed and activates the retry policy.

.NOTES
profile.ps1 must authenticate the Function's system-assigned managed identity
before this handler requests a Microsoft Graph token. DEVICE_TAG_EXTENSION_ATTRIBUTE
selects extensionAttribute1 through extensionAttribute15 and defaults to
extensionAttribute1 when unset.

Intune creates several related objects asynchronously. The handler resolves
the imported identity, registered Autopilot identity, and Entra device in that
order. Missing downstream IDs are treated as transient failures so the queue
trigger can retry the message.
#>

param($QueueItem, $TriggerMetadata, $TagPolicyBlob)

# Load the shared validation and Microsoft Graph payload helpers used by the
# HTTP and queue-triggered Functions.
$modulePath = Join-Path $PSScriptRoot '..\src\AutopilotImport\AutopilotImport.psm1'
Import-Module $modulePath -Force

# Azure Functions can provide a queue message as raw JSON or as an object,
# depending on worker and binding behavior. Normalize both forms first.
$message = if ($QueueItem -is [string]) {
    $QueueItem | ConvertFrom-Json
}
else {
    $QueueItem
}

# Reject malformed queue data permanently rather than issuing Graph requests
# with an ambiguous import identity or missing authorized Group Tag.
$importId = [guid]::Empty
if (-not [guid]::TryParse([string] $message.importId, [ref] $importId)) {
    throw 'Queued Autopilot import ID is invalid.'
}
$groupTag = [string] $message.groupTag
if ([string]::IsNullOrWhiteSpace($groupTag)) {
    throw "Queued Group Tag is missing for import '$importId'."
}

$auditToken = Get-ImportAuditAccessToken
$initialAuditProperties = [ordered]@{}
if ($message.PSObject.Properties['audit'] -and $message.audit) {
    foreach ($property in $message.audit.PSObject.Properties) {
        $initialAuditProperties[$property.Name] = $property.Value
    }
}
$existingAuditRecord = (Get-ImportAuditRecords `
        -ImportId $importId `
        -AccessToken $auditToken)[[string] $importId]
if (-not $existingAuditRecord -or [string]::IsNullOrWhiteSpace(
        [string] $existingAuditRecord.processingStartedAtUtc)) {
    $initialAuditProperties['processingStartedAtUtc'] = `
        [datetime]::UtcNow.ToString('o')
}
Set-ImportAuditRecord `
    -ImportId $importId `
    -Properties $initialAuditProperties `
    -AccessToken $auditToken

$tagAuthorizationPolicyJson = ConvertFrom-BlobBindingContent `
    -Value $TagPolicyBlob
if ([string]::IsNullOrWhiteSpace($tagAuthorizationPolicyJson)) {
    $tagAuthorizationPolicyJson = $env:TAG_AUTHORIZATION_POLICY
}
$tagAuthorizationPolicy = if (
    [string]::IsNullOrWhiteSpace($tagAuthorizationPolicyJson)) {
    @()
}
else {
    @($tagAuthorizationPolicyJson | ConvertFrom-Json)
}
$administrativeUnitName = `
    Resolve-EffectiveAdministrativeUnitName `
        -Policy $tagAuthorizationPolicy `
        -GroupTag $groupTag `
        -QueuedAdministrativeUnitName `
            ([string] $message.administrativeUnitName)

# Build the PATCH body with the deployment-selected extension attribute. The
# helper also enforces the supported extensionAttribute1..15 range.
$extensionAttribute = if ([string]::IsNullOrWhiteSpace($env:DEVICE_TAG_EXTENSION_ATTRIBUTE)) {
    'extensionAttribute1'
}
else {
    $env:DEVICE_TAG_EXTENSION_ATTRIBUTE
}
$payload = ConvertTo-EntraDeviceExtensionAttributes `
    -ExtensionAttribute $extensionAttribute `
    -GroupTag $groupTag

# Acquire a Microsoft Graph token through the managed Azure context initialized
# by profile.ps1 and normalize Az.Accounts token formats to SecureString.
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

# Resolve the asynchronous identity chain: queued import ID -> completed
# Autopilot registration ID -> Entra device ID. Missing IDs throw deliberately
# so the Storage Queue retry policy can try again after Intune progresses.
$importedDevice = Invoke-RestMethod `
    -Method Get `
    -Uri "https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities/$importId" `
    -Authentication Bearer `
    -Token $secureToken `
    -ErrorAction Stop
$registrationId = Get-AutoPilotDeviceRegistrationId `
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
Set-ImportAuditRecord `
    -ImportId $importId `
    -Properties @{
        entraDeviceResolvedAtUtc = [datetime]::UtcNow.ToString('o')
        entraDeviceId = $entraDeviceId.ToString()
    } `
    -AccessToken $auditToken

# Administrative-unit membership requires the Entra object ID, which differs
# from the deviceId (azureActiveDirectoryDeviceId) resolved above.
$deviceObjectId = [guid]::Empty
if (-not [string]::IsNullOrWhiteSpace(
        $administrativeUnitName)) {
    $entraDevice = Invoke-RestMethod `
        -Method Get `
        -Uri "https://graph.microsoft.com/v1.0/devices(deviceId='$entraDeviceId')?`$select=id" `
        -Authentication Bearer `
        -Token $secureToken `
        -ErrorAction Stop
    if (-not [guid]::TryParse([string] $entraDevice.id, [ref] $deviceObjectId)) {
        throw "Entra device object ID is unavailable for device '$entraDeviceId'."
    }

    # Membership is the completion marker for the optional AU workflow. An
    # existing membership means a prior delivery already completed both writes.
    $existingMembership = `
        Add-EntraDeviceToAdministrativeUnit `
            -AdministrativeUnitName `
                $administrativeUnitName `
            -DeviceObjectId $deviceObjectId `
            -AccessToken $secureToken `
            -TestOnly
    if ($existingMembership.IsMember) {
        $completedAtUtc = [datetime]::UtcNow.ToString('o')
        Set-ImportAuditRecord `
            -ImportId $importId `
            -Properties @{
                administrativeUnitAssignedAtUtc = $completedAtUtc
                processingCompletedAtUtc = $completedAtUtc
            } `
            -AccessToken $auditToken
        Write-Information "Entra device '$entraDeviceId' is already a member of administrative unit '$administrativeUnitName'."
        return
    }
}

# Write the authorized Group Tag before adding optional AU membership. This
# ordering ensures membership only marks a workflow whose attribute PATCH has
# already succeeded; repeating the PATCH after a transient failure is harmless.
Invoke-RestMethod `
    -Method Patch `
    -Uri "https://graph.microsoft.com/v1.0/devices(deviceId='$entraDeviceId')" `
    -Authentication Bearer `
    -Token $secureToken `
    -ContentType 'application/json' `
    -Body ($payload | ConvertTo-Json -Depth 4 -Compress) `
    -ErrorAction Stop | Out-Null

Set-ImportAuditRecord `
    -ImportId $importId `
    -Properties @{
        extensionAttributeUpdatedAtUtc = [datetime]::UtcNow.ToString('o')
    } `
    -AccessToken $auditToken

Write-Information "Autopilot Group Tag '$groupTag' written to $extensionAttribute on Entra device '$entraDeviceId'."

if (-not [string]::IsNullOrWhiteSpace(
        $administrativeUnitName)) {
    # The helper rechecks membership and performs the add only when necessary,
    # keeping retries and duplicate queue deliveries idempotent.
    $membershipResult = `
        Add-EntraDeviceToAdministrativeUnit `
            -AdministrativeUnitName `
                $administrativeUnitName `
            -DeviceObjectId $deviceObjectId `
            -AccessToken $secureToken
    $membershipAction = if ($membershipResult.MembershipAdded) {
        'added to'
    }
    else {
        'already a member of'
    }
    Write-Information "Entra device '$entraDeviceId' $membershipAction administrative unit '$administrativeUnitName'."

    Set-ImportAuditRecord `
        -ImportId $importId `
        -Properties @{
            administrativeUnitAssignedAtUtc = [datetime]::UtcNow.ToString('o')
        } `
        -AccessToken $auditToken
}

Set-ImportAuditRecord `
    -ImportId $importId `
    -Properties @{
        processingCompletedAtUtc = [datetime]::UtcNow.ToString('o')
    } `
    -AccessToken $auditToken