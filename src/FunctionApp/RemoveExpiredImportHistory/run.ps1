# Project-Version: 1.3.20261006.4
# Author: andreas.lucas@outlook.com (aka Kili)

<#
.SYNOPSIS
Removes import audit records after the 30-day retention period.

.DESCRIPTION
Runs hourly and deletes Azure Table Storage entities whose request time is
older than 30 days. The Function uses the system-assigned managed identity and
the same private audit table as the import workflow.
#>

param($Timer)

$modulePath = Join-Path $PSScriptRoot '..\src\AutopilotImport\AutopilotImport.psm1'
Import-Module $modulePath -Force

$retentionCutoffUtc = Get-ImportAuditRetentionCutoffUtc
$removedCount = Remove-ExpiredImportAuditRecords `
    -BeforeUtc $retentionCutoffUtc `
    -AccessToken (Get-ImportAuditAccessToken)

Write-Information (
    "Removed $removedCount import audit record(s) older than " +
    "$($retentionCutoffUtc.ToString('o')).")
