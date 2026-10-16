# Project-Version: 1.4.20261016.4
# Author: andreas.lucas@outlook.com (aka Kili)

<#
.SYNOPSIS
Removes import audit records after the 30-day retention period.

.DESCRIPTION
Runs hourly and deletes Azure Table Storage entities whose request time is
older than 30 days. The Function uses the system-assigned managed identity and
the same private audit table as the import workflow. It also completes pending
Scope Tag assignments after Intune enrollment. Pending assignments are retained.
#>

param($Timer)

$modulePath = Join-Path $PSScriptRoot '..\src\AutopilotImport\AutopilotImport.psm1'
Import-Module $modulePath -Force

$retentionCutoffUtc = Get-ImportAuditRetentionCutoffUtc
$auditToken = Get-ImportAuditAccessToken
try {
    $tokenResult = Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com/' -ErrorAction Stop
    $graphToken = if ($tokenResult.Token -is [Security.SecureString]) { $tokenResult.Token } else {
        ConvertTo-SecureString ([string] $tokenResult.Token) -AsPlainText -Force
    }
    Complete-PendingDeviceScopeTags -AccessToken $graphToken -AuditToken $auditToken
}
finally {
    $removedCount = Remove-ExpiredImportAuditRecords `
        -BeforeUtc $retentionCutoffUtc `
        -AccessToken $auditToken
    Write-Information (
        "Removed $removedCount import audit record(s) older than " +
        "$($retentionCutoffUtc.ToString('o')).")
}
