# Project-Version: 1.4.20261020.13
# Author: andreas.lucas@outlook.com (aka Kili)

<#
.SYNOPSIS
Completes the Entra configuration of an imported Autopilot device.

.DESCRIPTION
Processes queued Autopilot imports after Intune has created the Entra device.
It writes the policy's extension attribute values, synchronizes policy-managed
device groups, and optionally adds the device to an administrative unit.
Only pre-enrollment actions are supported. Legacy rules retain the
deployment-selected extension attribute.
An incomplete
import throws so the Storage Queue trigger retries it according to host.json.
Successful updates are idempotent.

.PARAMETER QueueItem
Message supplied by the Azure Storage Queue trigger. The value may be a JSON
string or a deserialized object and must contain either importId for a new
import or operationId and registeredDeviceId for a Group Tag change. It must
also contain groupTag and may contain administrativeUnitName.

.PARAMETER TriggerMetadata
Metadata supplied by the Azure Functions PowerShell worker for the queue
invocation. DequeueCount is recorded as the processing attempt when a step
fails.

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

# Invoke-RestMethod HTTP failures are statement-terminating. Without Stop the
# worker would continue after a failed Graph write and record success.
$ErrorActionPreference = 'Stop'

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
# with an ambiguous work-item identity or missing authorized Group Tag.
$importId = [guid]::Empty
$registeredDeviceId = [guid]::Empty
$operationId = [guid]::Empty
$isTagChange = [guid]::TryParse(
    [string] $message.registeredDeviceId,
    [ref] $registeredDeviceId)
if ($isTagChange) {
    if (-not [guid]::TryParse(
            [string] $message.operationId,
            [ref] $operationId)) {
        throw 'Queued Group Tag change operation ID is invalid.'
    }
    $auditId = $operationId
}
else {
    if (-not [guid]::TryParse([string] $message.importId, [ref] $importId)) {
        throw 'Queued Autopilot import ID is invalid.'
    }
    $auditId = $importId
}
$groupTag = [string] $message.groupTag
if ([string]::IsNullOrWhiteSpace($groupTag)) {
    throw "Queued Group Tag is missing for work item '$auditId'."
}

$auditToken = Get-ImportAuditAccessToken
$initialAuditProperties = [ordered]@{}
if ($message.PSObject.Properties['audit'] -and $message.audit) {
    foreach ($property in $message.audit.PSObject.Properties) {
        $initialAuditProperties[$property.Name] = $property.Value
    }
}
$existingAuditRecord = (Get-ImportAuditRecords `
        -ImportId $auditId `
        -AccessToken $auditToken)[[string] $auditId]
if (-not $existingAuditRecord -or [string]::IsNullOrWhiteSpace(
        [string] $existingAuditRecord.processingStartedAtUtc)) {
    $initialAuditProperties['processingStartedAtUtc'] = `
        [datetime]::UtcNow.ToString('o')
}
Set-ImportAuditRecord `
    -ImportId $auditId `
    -Properties $initialAuditProperties `
    -AccessToken $auditToken

# Record each failed processing attempt with its step and the Graph error,
# then rethrow so the Storage Queue retry policy runs. The final dequeue
# attempt marks the operation failed so history no longer reports pending.
$processingStep = 'policy'
$processingAttempt = 1
$dequeueCount = 0
if ($TriggerMetadata -and [int]::TryParse([string] $TriggerMetadata.DequeueCount, [ref] $dequeueCount)) {
    $processingAttempt = [math]::Max(1, $dequeueCount)
}
$processingMaxAttempts = 24
trap {
    # Traps cover the whole script; earlier validation failures have no audit context.
    if (-not $auditToken -or -not $processingStep) { break }
    $failure = Get-ProcessingFailureAudit `
        -ErrorRecord $_ `
        -Step $processingStep `
        -Attempt $processingAttempt `
        -MaxAttempts $processingMaxAttempts
    if ($failure.Properties.Count -gt 0) {
        try {
            Set-ImportAuditRecord -ImportId $auditId -Properties $failure.Properties -AccessToken $auditToken
        }
        catch {
            Write-Warning "Could not record the processing failure for work item '$auditId': $($_.Exception.Message)"
        }
    }
    throw "Processing step '$processingStep' failed for work item '$auditId' (attempt $processingAttempt of $processingMaxAttempts): $($failure.Message)"
}

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
$policyActions = Get-DevicePolicyActions -Policy $tagAuthorizationPolicy -GroupTag $groupTag
if ($policyActions.PSObject.Properties['name']) {
    Set-ImportAuditRecord -ImportId $auditId -AccessToken $auditToken -Properties @{ policyName = [string] $policyActions.name }
}
if ($policyActions.PSObject.Properties['extensionAttributes']) {
    $payload = @{ extensionAttributes = $policyActions.extensionAttributes }
}
$targetGroups = if ($policyActions.PSObject.Properties['deviceGroupIds']) {
    @($policyActions.deviceGroupIds)
} else { @() }

# Acquire a Microsoft Graph token through the managed Azure context initialized
# by profile.ps1 and normalize Az.Accounts token formats to SecureString.
$processingStep = 'graphToken'
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

# Resolve either the asynchronous import identity chain or the existing
# registered Autopilot identity selected for a Group Tag change.
if ($isTagChange) {
    $processingStep = 'autopilotGroupTag'
    $registeredDevice = Invoke-RestMethod `
        -Method Get `
        -Uri "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$registeredDeviceId" `
        -Authentication Bearer `
        -Token $secureToken `
        -ErrorAction Stop
    if ([string] $registeredDevice.enrollmentState -ine 'notContacted') {
        throw "Autopilot device '$registeredDeviceId' is no longer eligible for a Group Tag change."
    }
    Invoke-RestMethod `
        -Method Post `
        -Uri "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$registeredDeviceId/updateDeviceProperties" `
        -Authentication Bearer `
        -Token $secureToken `
        -ContentType 'application/json' `
        -Body (@{ groupTag = $groupTag } | ConvertTo-Json -Compress) `
        -ErrorAction Stop | Out-Null
    Set-ImportAuditRecord `
        -ImportId $auditId `
        -Properties @{
            autopilotGroupTagUpdatedAtUtc = [datetime]::UtcNow.ToString('o')
        } `
        -AccessToken $auditToken
}
else {
    $processingStep = 'autopilotRegistration'
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
}
if (-not $isTagChange -and $importedDevice.state.PSObject.Properties['deviceImportStatus'] -and
    [string] $importedDevice.state.deviceImportStatus -ieq 'complete') {
    $registrationProperties = @{
        graphImportCompletedAtUtc = [datetime]::UtcNow.ToString('o')
    }
    if ($registeredDevice.PSObject.Properties['groupTag'] -and
        [string] $registeredDevice.groupTag -ceq $groupTag) {
        $registrationProperties.autopilotGroupTagUpdatedAtUtc = [datetime]::UtcNow.ToString('o')
    }
    Set-ImportAuditRecord -ImportId $auditId -Properties $registrationProperties -AccessToken $auditToken
}
$entraDeviceId = [guid]::Empty
$processingStep = 'entraDevice'
if (-not [guid]::TryParse(
        [string] $registeredDevice.azureActiveDirectoryDeviceId,
        [ref] $entraDeviceId)) {
    throw "Entra device is not available yet for work item '$auditId'."
}
Set-ImportAuditRecord `
    -ImportId $auditId `
    -Properties @{
        entraDeviceResolvedAtUtc = [datetime]::UtcNow.ToString('o')
        entraDeviceId = $entraDeviceId.ToString()
    } `
    -AccessToken $auditToken

# Administrative-unit membership requires the Entra object ID, which differs
# from the deviceId (azureActiveDirectoryDeviceId) resolved above.
$deviceObjectId = [guid]::Empty
if ($isTagChange -or
    -not [string]::IsNullOrWhiteSpace($administrativeUnitName)) {
    $entraDevice = Invoke-RestMethod `
        -Method Get `
        -Uri "https://graph.microsoft.com/v1.0/devices(deviceId='$entraDeviceId')?`$select=id" `
        -Authentication Bearer `
        -Token $secureToken `
        -ErrorAction Stop
    if (-not [guid]::TryParse([string] $entraDevice.id, [ref] $deviceObjectId)) {
        throw "Entra device object ID is unavailable for device '$entraDeviceId'."
    }

}

# Write the authorized Group Tag before adding optional AU membership. This
# ordering ensures membership only marks a workflow whose attribute PATCH has
# already succeeded; repeating the PATCH after a transient failure is harmless.
$attributeNames = if ($payload.extensionAttributes -is [Collections.IDictionary]) {
    @($payload.extensionAttributes.Keys)
} else { @($payload.extensionAttributes.PSObject.Properties | ForEach-Object Name) }
$processingStep = 'extensionAttributes'
if ($attributeNames.Count -gt 0) {
    Invoke-RestMethod `
        -Method Patch `
        -Uri "https://graph.microsoft.com/v1.0/devices(deviceId='$entraDeviceId')" `
        -Authentication Bearer `
        -Token $secureToken `
        -ContentType 'application/json' `
        -Body ($payload | ConvertTo-Json -Depth 4 -Compress) `
        -ErrorAction Stop | Out-Null
    Set-ImportAuditRecord -ImportId $auditId -Properties @{
        extensionAttributeUpdatedAtUtc = [datetime]::UtcNow.ToString('o')
        appliedExtensionAttributesJson = ConvertTo-Json -InputObject $payload.extensionAttributes -Depth 4 -Compress
    } -AccessToken $auditToken
    Write-Information "Updated $($attributeNames -join ', ') on Entra device '$entraDeviceId'."
}
else {
    Set-ImportAuditRecord -ImportId $auditId -Properties @{
        appliedExtensionAttributesJson = '{}'
    } -AccessToken $auditToken
    Write-Information "Policy explicitly skips extension attributes on Entra device '$entraDeviceId'."
}

$managedGroups = @($tagAuthorizationPolicy | ForEach-Object {
    if ($_.PSObject.Properties['deviceGroupIds']) { $_.deviceGroupIds }
})
$processingStep = 'deviceGroups'
$state = Get-DevicePolicyState -DeviceId $entraDeviceId -AccessToken $auditToken
$previousGroupIds = @($state.groupIdsJson | ConvertFrom-Json)
if ($policyActions.PSObject.Properties['groupTag'] -or $managedGroups.Count -gt 0 -or $previousGroupIds.Count -gt 0) {
    if ($deviceObjectId -eq [guid]::Empty) {
        $entraDevice = Invoke-RestMethod -Method Get `
            -Uri "https://graph.microsoft.com/v1.0/devices(deviceId='$entraDeviceId')?`$select=id" `
            -Authentication Bearer -Token $secureToken -ErrorAction Stop
        $deviceObjectId = [guid] $entraDevice.id
    }
    # Persist the union before Graph writes so retries retain ownership after partial changes.
    Set-DevicePolicyState -DeviceId $entraDeviceId -GroupIds @($previousGroupIds + $targetGroups | Sort-Object -Unique) `
        -AccessToken $auditToken
    $groupResult = Sync-DevicePolicyGroups -Policy $tagAuthorizationPolicy -TargetGroupIds $targetGroups -PreviousGroupIds $previousGroupIds `
        -DeviceObjectId $deviceObjectId -AccessToken $secureToken -PassThru
    Set-DevicePolicyState -DeviceId $entraDeviceId -GroupIds $targetGroups -AccessToken $auditToken
    Set-ImportAuditRecord -ImportId $auditId -AccessToken $auditToken -Properties @{
        deviceGroupsUpdatedAtUtc = [datetime]::UtcNow.ToString('o')
        targetDeviceGroupIdsJson = ConvertTo-Json -InputObject @($targetGroups) -Compress
        addedDeviceGroupIdsJson = ConvertTo-Json -InputObject @($groupResult.AddedGroupIds | Where-Object { $_ }) -Compress
        removedDeviceGroupIdsJson = ConvertTo-Json -InputObject @($groupResult.RemovedGroupIds | Where-Object { $_ }) -Compress
    }
}
$processingStep = 'administrativeUnits'
if ($deviceObjectId -ne [guid]::Empty) {
    $membershipResult = Sync-EntraDeviceAdministrativeUnits `
        -Policy $tagAuthorizationPolicy `
        -AdministrativeUnitName ([string] $administrativeUnitName) `
        -DeviceObjectId $deviceObjectId `
        -AccessToken $secureToken
    Set-ImportAuditRecord `
        -ImportId $auditId `
        -Properties @{
            administrativeUnitAssignedAtUtc = [datetime]::UtcNow.ToString('o')
            administrativeUnitName = [string] $administrativeUnitName
            removedAdministrativeUnitsJson = ConvertTo-Json -InputObject @($membershipResult.RemovedAdministrativeUnits) -Compress
        } `
        -AccessToken $auditToken
    Write-Information "Synchronized policy-managed administrative units for Entra device '$entraDeviceId'."
}

$processingStep = 'completion'
$completionProperties = @{
    processingCompletedAtUtc = [datetime]::UtcNow.ToString('o')
}
# A later successful retry supersedes an earlier failure marker.
if ($existingAuditRecord -and $existingAuditRecord.PSObject.Properties['processingFailedAtUtc'] -and
    -not [string]::IsNullOrWhiteSpace([string] $existingAuditRecord.processingFailedAtUtc)) {
    $completionProperties.processingFailedAtUtc = ''
}
Set-ImportAuditRecord `
    -ImportId $auditId `
    -Properties $completionProperties `
    -AccessToken $auditToken