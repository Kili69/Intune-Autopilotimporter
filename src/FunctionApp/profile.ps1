# Project-Version: 1.1.20260918.4
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
DISCLAIMER:
This sample script is not supported under any Microsoft standard support program or service.
The sample script is provided AS IS without warranty of any kind. Microsoft further disclaims
all implied warranties including, without limitation, any implied warranties of merchantability
or of fitness for a particular purpose. The entire risk arising out of the use or performance of
the sample scripts and documentation remains with you. In no event shall Microsoft, its authors,
or anyone else involved in the creation, production, or delivery of the scripts be liable for any
damages whatsoever (including, without limitation, damages for loss of business profits, business
interruption, loss of business information, or other pecuniary loss) arising out of the use of or
inability to use the sample scripts or documentation, even if Microsoft has been advised of the
possibility of such damages.
#>

<#
.SYNOPSIS
Authenticates the Function host with its managed identity.

.DESCRIPTION
Azure Functions PowerShell worker profile executed when a worker starts. When
the IDENTITY_ENDPOINT environment variable is present, it signs in to Azure
with the Function App's system-assigned managed identity. The HTTP trigger then
uses the resulting Az context to request a Microsoft Graph access token.

.INPUTS
None.

.OUTPUTS
None. Connect-AzAccount output is suppressed.

.NOTES
This lifecycle script is loaded automatically by Azure Functions and is not
intended for direct interactive execution.
#>

if ($env:IDENTITY_ENDPOINT) {
    Connect-AzAccount -Identity | Out-Null
}