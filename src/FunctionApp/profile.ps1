# Project-Version: 1.3.20261006.4
# Author: andreas.lucas@outlook.com (aka Kili)

# Copyright 2026 Andreas Lucas
# Licensed under the Apache License, Version 2.0.
# See the LICENSE file in the project root for license information.

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