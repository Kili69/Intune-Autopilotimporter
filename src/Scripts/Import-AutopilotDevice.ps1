<#PSScriptInfo

.VERSION 1.2.20261004.1

.GUID 5c9800d6-0239-4a66-86a7-a906f956bf35

.AUTHOR andreas.lucas@microsoft.com

.COMPANYNAME

.COPYRIGHT

.TAGS WindowsAutopilot Intune Entra Azure REST HardwareHash

.LICENSEURI

.PROJECTURI https://github.com/Kili69/Intune-Autopilotimporter

.ICONURI

.EXTERNALMODULEDEPENDENCIES Az.Accounts

.REQUIREDSCRIPTS

.EXTERNALSCRIPTDEPENDENCIES

.RELEASENOTES
Standalone REST client with CSV and local hardware hash import, PowerShell 5.1
compatibility, automatic Az.Accounts installation, and status polling.

.PRIVATEDATA

#>

#Requires -Version 5.1
# Project-Version: 1.2.20261004.1
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
.SYNOPSIS
Imports Windows Autopilot devices through the secured REST API.

.DESCRIPTION
Reads the public runtime configuration from an Autopilot Import application, validates device data from a CSV file or collects the local device hardware hash, and submits each device directly to the secured REST API.
The script imports without a confirmation prompt and polls every 10 seconds until Intune reports the import and Entra device attribute processing as complete or the import reaches an error state. Use -Verbose for additional configuration, authentication, request, and polling details.

The script uses Az.Accounts only to acquire the signed-in user's API token. If the required commands are unavailable, it installs Az.Accounts from the PowerShell Gallery for the current user. It does not load or require AutopilotImport.Client.

.PARAMETER ApplicationUrl
HTTPS URL of the Autopilot Import application. The Function App root, /api/ui, and the complete /api/ui/index.html URL are accepted.

.PARAMETER CsvPath
Optional path to a CSV containing Device Serial Number and Hardware Hash. When omitted, the script reads both values from the local Windows device. Local hash collection requires an elevated PowerShell session.

.PARAMETER GroupTag
Autopilot Group Tag requested for every device. The signed-in user must be authorized to use this tag.

.PARAMETER ValidateOnly
Validates the application configuration and device data without signing in or sending an import request.

.EXAMPLE
.\Import-AutopilotDevice.ps1 `
    -ApplicationUrl 'https://autopilot.contoso.com' `
    -GroupTag 'PAW'

Collects the local device hash, imports it without a confirmation prompt, and displays an updated status every 10 seconds until processing finishes.

.EXAMPLE
.\Import-AutopilotDevice.ps1 `
    -ApplicationUrl 'https://autopilot.contoso.com/api/ui/index.html' `
    -CsvPath '.\devices.csv' `
    -GroupTag 'PAW' `
    -ValidateOnly

Validates the application and CSV without authentication or an import.

.EXAMPLE
.\Import-AutopilotDevice.ps1 `
    -ApplicationUrl 'https://autopilot.contoso.com' `
    -CsvPath '.\devices.csv' `
    -GroupTag 'PAW' `
    -WhatIf

Shows the proposed import without authentication or an import request.

.OUTPUTS
ValidateOnly returns a validation summary. A completed import returns the final REST status response for each device.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ApplicationUrl,

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $CsvPath,

    [Parameter(Mandatory)]
    [ValidateLength(1, 128)]
    [string] $GroupTag,

    [switch] $ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$pollIntervalSeconds = 10
# Windows PowerShell 5.1 may otherwise negotiate an obsolete Gallery protocol.
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor `
    [Net.SecurityProtocolType]::Tls12

function Resolve-AutoPilotApplicationUrl {
    <#
    .SYNOPSIS
    Normalizes an Autopilot Import application URL.

    .DESCRIPTION
    Validates that the supplied URL uses HTTPS and converts a Function App
    root or /api/ui URL to the canonical /api/ui/index.html URL.

    .PARAMETER Url
    Function App root, /api/ui, or /api/ui/index.html URL to normalize.

    .OUTPUTS
    System.Uri. The canonical application page URL without query or fragment.
    #>
    param([Parameter(Mandatory)][string] $Url)

    $parsedUrl = $null
    if (-not [uri]::TryCreate($Url.Trim(), [UriKind]::Absolute, [ref] $parsedUrl) -or
        $parsedUrl.Scheme -ne 'https') {
        throw 'ApplicationUrl must be an absolute HTTPS URL.'
    }

    # Normalize every supported entry URL to the page beside the public config.
    $builder = [UriBuilder]::new($parsedUrl)
    if ($builder.Path -eq '/' -or [string]::IsNullOrWhiteSpace($builder.Path)) {
        $builder.Path = '/api/ui/index.html'
    }
    elseif ($builder.Path.TrimEnd('/') -eq '/api/ui') {
        $builder.Path = '/api/ui/index.html'
    }
    elseif (-not $builder.Path.EndsWith(
            '/api/ui/index.html',
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'ApplicationUrl must identify the Function App root, /api/ui, or /api/ui/index.html.'
    }
    $builder.Query = ''
    $builder.Fragment = ''
    return $builder.Uri
}

function Get-AutoPilotRuntimeConfiguration {
    <#
    .SYNOPSIS
    Reads and validates the public application configuration.

    .DESCRIPTION
    Requests the frontend configuration endpoint and validates its Entra
    authority, DeviceHash.Import scope, tenant ID, and same-origin import URL.

    .PARAMETER ApplicationUri
    Canonical /api/ui/index.html URL of the Autopilot Import application.

    .OUTPUTS
    System.Management.Automation.PSCustomObject. Validated application URL,
    configuration URL, import URL, API audience, and tenant ID.
    #>
    param([Parameter(Mandatory)][uri] $ApplicationUri)

    # The frontend publishes tenant, audience, and endpoint data without secrets.
    $configurationUrl = [uri]::new($ApplicationUri, './config')
    Write-Verbose "Reading runtime configuration from '$configurationUrl'."
    try {
        $configuration = Invoke-RestMethod `
            -Method Get `
            -Uri $configurationUrl `
            -ErrorAction Stop
    }
    catch {
        throw "Could not read the Autopilot Import application configuration from '$configurationUrl'. $($_.Exception.Message)"
    }

    # Expected value: api://<36-character application GUID>/DeviceHash.Import
    # ^ and $ require the expression to match the complete scope value.
    # (?<audience>...) captures the token audience without the delegated scope.
    # (?<clientId>...) captures the application GUID inside that audience.
    # [0-9a-fA-F-]{36} allows exactly 36 GUID characters; TryParse below then
    # verifies their required GUID structure. \. escapes the dot so it matches
    # a literal period instead of the regex wildcard.
    $scope = [string] $configuration.scope
    if ($scope -notmatch '^(?<audience>api://(?<clientId>[0-9a-fA-F-]{36}))/DeviceHash\.Import$') {
        throw 'The application configuration does not contain a valid DeviceHash.Import scope.'
    }
    $audience = [string] $Matches.audience
    $clientId = [string] $Matches.clientId
    $parsedClientId = [guid]::Empty
    if (-not [guid]::TryParse($clientId, [ref] $parsedClientId)) {
        throw 'The DeviceHash.Import scope does not contain a valid application GUID.'
    }

    $authority = $null
    if (-not [uri]::TryCreate(
            [string] $configuration.authority,
            [UriKind]::Absolute,
            [ref] $authority) -or
        $authority.Scheme -ne 'https' -or
        $authority.Host -ne 'login.microsoftonline.com') {
        throw 'The application configuration does not contain a valid Microsoft Entra authority.'
    }
    $tenantId = $authority.AbsolutePath.Trim('/')
    $parsedTenantId = [guid]::Empty
    if (-not [guid]::TryParse($tenantId, [ref] $parsedTenantId)) {
        throw 'The Microsoft Entra authority does not contain a tenant GUID.'
    }

    # Keep authenticated device data on the same origin selected by the user.
    $importUri = $null
    if (-not [uri]::TryCreate(
            [string] $configuration.importUrl,
            [UriKind]::Absolute,
            [ref] $importUri) -or
        $importUri.Scheme -ne 'https' -or
        $importUri.GetLeftPart([UriPartial]::Authority) -ne
            $ApplicationUri.GetLeftPart([UriPartial]::Authority)) {
        throw 'The application configuration contains an invalid import URL.'
    }

    Write-Verbose "Validated runtime configuration for tenant '$($parsedTenantId.ToString())' and import endpoint '$($importUri.AbsoluteUri)'."
    return [pscustomobject]@{
        ApplicationUrl = $ApplicationUri.AbsoluteUri
        ConfigurationUrl = $configurationUrl.AbsoluteUri
        ImportUrl = $importUri.AbsoluteUri
        ApiAudience = $audience
        TenantId = $parsedTenantId.ToString()
    }
}

function ConvertTo-AutoPilotDeviceRecord {
    <#
    .SYNOPSIS
    Validates and creates an Autopilot device record.

    .DESCRIPTION
    Verifies that a serial number is present and that the hardware hash is a
    non-empty Base64 value, then creates the normalized internal record.

    .PARAMETER SerialNumber
    Device serial number to validate and trim.

    .PARAMETER HardwareHash
    Base64-encoded Windows Autopilot hardware hash.

    .PARAMETER Source
    Human-readable data source included in validation error messages.

    .OUTPUTS
    System.Management.Automation.PSCustomObject. Validated serial number,
    hardware hash, and source description.
    #>
    param(
        [Parameter(Mandatory)][string] $SerialNumber,
        [Parameter(Mandatory)][string] $HardwareHash,
        [Parameter(Mandatory)][string] $Source
    )

    if ([string]::IsNullOrWhiteSpace($SerialNumber)) {
        throw "$Source does not contain a device serial number."
    }
    if ([string]::IsNullOrWhiteSpace($HardwareHash)) {
        throw "$Source does not contain a hardware hash."
    }
    # Decoding verifies the hash format without changing the submitted value.
    try {
        $hashBytes = [Convert]::FromBase64String($HardwareHash)
    }
    catch {
        throw "$Source contains an invalid Base64 hardware hash."
    }
    if ($hashBytes.Length -eq 0) {
        throw "$Source contains an empty hardware hash."
    }

    return [pscustomobject]@{
        SerialNumber = $SerialNumber.Trim()
        HardwareHash = $HardwareHash
        Source = $Source
    }
}

function Get-AutoPilotCsvDevice {
    <#
    .SYNOPSIS
    Reads Autopilot device records from a CSV file.

    .DESCRIPTION
    Verifies that the CSV is not empty and contains Device Serial Number and
    Hardware Hash columns, then validates every row as an Autopilot device.

    .PARAMETER Path
    Path to the Windows Autopilot CSV file.

    .OUTPUTS
    System.Management.Automation.PSCustomObject[]. Validated device records in
    the same order as the CSV rows.
    #>
    param([Parameter(Mandatory)][string] $Path)

    $csvFile = Get-Item -LiteralPath $Path
    if ($csvFile.Length -eq 0) {
        throw "The Autopilot CSV file '$($csvFile.FullName)' is empty."
    }
    $rows = @(Import-Csv -LiteralPath $csvFile.FullName)
    if ($rows.Count -eq 0) {
        throw 'The Autopilot CSV does not contain any devices.'
    }
    $headers = @($rows[0].PSObject.Properties.Name)
    $missingColumns = @(
        'Device Serial Number', 'Hardware Hash' |
            Where-Object { $_ -notin $headers }
    )
    if ($missingColumns.Count -gt 0) {
        throw "The Autopilot CSV is missing required columns: $($missingColumns -join ', ')."
    }

    return @(
        for ($rowIndex = 0; $rowIndex -lt $rows.Count; $rowIndex++) {
            ConvertTo-AutoPilotDeviceRecord `
                -SerialNumber ([string] $rows[$rowIndex].'Device Serial Number') `
                -HardwareHash ([string] $rows[$rowIndex].'Hardware Hash') `
                -Source "CSV row $($rowIndex + 2)"
        }
    )
}

function Get-LocalAutoPilotDevice {
    <#
    .SYNOPSIS
    Reads the local Windows Autopilot device identity.

    .DESCRIPTION
    Requires an elevated Windows session, reads the BIOS serial number and the
    hardware hash from the MDM Bridge WMI provider, and validates both values.

    .OUTPUTS
    System.Management.Automation.PSCustomObject. The validated local device
    record.
    #>
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Local Autopilot hardware hash collection is supported only on Windows.'
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an elevated PowerShell session to collect the local hardware hash.'
    }

    # Autopilot hardware hashes are exposed through the Windows MDM Bridge WMI provider.
    $serialNumber = [string] (Get-CimInstance `
        -ClassName Win32_BIOS `
        -ErrorAction Stop).SerialNumber
    $deviceDetail = Get-CimInstance `
        -Namespace 'root/cimv2/mdm/dmmap' `
        -ClassName 'MDM_DevDetail_Ext01' `
        -Filter "InstanceID='Ext' AND ParentID='./DevDetail'" `
        -ErrorAction Stop

    return ConvertTo-AutoPilotDeviceRecord `
        -SerialNumber $serialNumber `
        -HardwareHash ([string] $deviceDetail.DeviceHardwareData) `
        -Source 'The local Windows device'
}

function Install-AutoPilotAzAccounts {
    <#
    .SYNOPSIS
    Ensures that the required Az.Accounts commands are available.

    .DESCRIPTION
    Checks for the Az.Accounts authentication commands. When they are missing,
    bootstraps the NuGet provider if necessary and installs Az.Accounts from
    the PowerShell Gallery for the current user.

    .OUTPUTS
    None.
    #>
    # Command checks also recognize an already loaded or auto-discoverable module.
    $requiredCommands = @(
        'Get-AzContext'
        'Connect-AzAccount'
        'Get-AzAccessToken'
    )
    $missingCommands = @(
        $requiredCommands |
            Where-Object {
                -not (Get-Command $_ -ErrorAction SilentlyContinue)
            }
    )
    if ($missingCommands.Count -eq 0) {
        return
    }

    if (-not (Get-Command Install-Module -ErrorAction SilentlyContinue)) {
        throw 'Az.Accounts is required, but PowerShellGet is not available. Install PowerShellGet and Az.Accounts for the current user, then try again.'
    }

    Write-Host 'Az.Accounts is not installed. Installing it from the PowerShell Gallery for the current user...'
    try {
        # Older Windows PowerShell installations may not have bootstrapped NuGet yet.
        if ((Get-Command Get-PackageProvider -ErrorAction SilentlyContinue) -and
            (Get-Command Install-PackageProvider -ErrorAction SilentlyContinue) -and
            -not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
            Install-PackageProvider `
                -Name NuGet `
                -MinimumVersion '2.8.5.201' `
                -Scope CurrentUser `
                -Force | Out-Null
        }

        Install-Module `
            -Name Az.Accounts `
            -MinimumVersion '2.2.0' `
            -Scope CurrentUser `
            -Repository PSGallery `
            -AllowClobber `
            -Force `
            -ErrorAction Stop
        Import-Module Az.Accounts -MinimumVersion '2.2.0' -Force -ErrorAction Stop
    }
    catch {
        throw "Az.Accounts could not be installed for the current user. $($_.Exception.Message)"
    }

    $missingCommands = @(
        $requiredCommands |
            Where-Object {
                -not (Get-Command $_ -ErrorAction SilentlyContinue)
            }
    )
    if ($missingCommands.Count -gt 0) {
        throw "Az.Accounts was installed, but required commands are unavailable: $($missingCommands -join ', '). Close PowerShell, start it again, and retry."
    }
}

function ConvertFrom-AutoPilotSecureString {
    <#
    .SYNOPSIS
    Converts a SecureString access token to plain text.

    .DESCRIPTION
    Uses protected BSTR marshalling for Windows PowerShell 5.1 compatibility
    and clears the unmanaged buffer after the token has been copied.

    .PARAMETER SecureString
    SecureString value returned by Az.Accounts.

    .OUTPUTS
    System.String. The plain-text access token used in the Authorization
    header.
    #>
    param([Parameter(Mandatory)][Security.SecureString] $SecureString)

    # Windows PowerShell 5.1 lacks the newer plain-text SecureString switch.
    $buffer = [IntPtr]::Zero
    try {
        $buffer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
            $SecureString)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($buffer)
    }
    finally {
        if ($buffer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($buffer)
        }
    }
}

function Get-AutoPilotAccessToken {
    <#
    .SYNOPSIS
    Acquires an access token for the Autopilot Import API.

    .DESCRIPTION
    Ensures Az.Accounts is available, signs in to the requested tenant when the
    current context does not match, and requests a token for the API audience.

    .PARAMETER TenantId
    Microsoft Entra tenant GUID used for interactive authentication.

    .PARAMETER ApiAudience
    Application ID URI for which the access token is requested.

    .OUTPUTS
    System.String. A plain-text bearer token.
    #>
    param(
        [Parameter(Mandatory)][string] $TenantId,
        [Parameter(Mandatory)][string] $ApiAudience
    )

    Install-AutoPilotAzAccounts

    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context -or [string] $context.Tenant.Id -ne $TenantId) {
        Write-Verbose "Signing in to Microsoft Entra tenant '$TenantId'."
        Connect-AzAccount -Tenant $TenantId | Out-Null
    }
    else {
        Write-Verbose "Using the existing Azure context for tenant '$TenantId'."
    }
    Write-Verbose "Requesting an access token for '$ApiAudience'."
    $tokenResult = Get-AzAccessToken -ResourceUrl $ApiAudience
    # Az.Accounts versions return either a SecureString or a plain token string.
    if ($tokenResult.Token -is [Security.SecureString]) {
        return ConvertFrom-AutoPilotSecureString `
            -SecureString $tokenResult.Token
    }
    return [string] $tokenResult.Token
}

function Get-AutoPilotRestErrorMessage {
    <#
    .SYNOPSIS
    Creates a concise message from a REST API error.

    .DESCRIPTION
    Reads a JSON error response across Windows PowerShell 5.1 and PowerShell 7,
    maps known service errors to actionable guidance, and writes the
    correlation ID to the Verbose stream for diagnostics.

    .PARAMETER ErrorRecord
    PowerShell error record raised by Invoke-RestMethod.

    .PARAMETER GroupTag
    Group Tag requested by the failed import.

    .OUTPUTS
    System.String. A user-facing REST error description.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord,

        [Parameter(Mandatory)]
        [string] $GroupTag
    )

    $response = $null
    $responseText = if ($ErrorRecord.ErrorDetails -and
        $ErrorRecord.ErrorDetails.Message) {
        [string] $ErrorRecord.ErrorDetails.Message
    }
    else {
        ''
    }
    $httpResponse = if ($ErrorRecord.Exception.PSObject.Properties['Response']) {
        $ErrorRecord.Exception.Response
    }
    else {
        $null
    }
    if ([string]::IsNullOrWhiteSpace($responseText) -and $httpResponse) {
        try {
            $contentProperty = $httpResponse.PSObject.Properties['Content']
            if ($contentProperty -and $contentProperty.Value -and
                $contentProperty.Value.PSObject.Methods['ReadAsStringAsync']) {
                $responseText = `
                    $contentProperty.Value.ReadAsStringAsync().Result
            }
            elseif ($httpResponse.PSObject.Methods['GetResponseStream']) {
                $responseStream = $httpResponse.GetResponseStream()
                if ($responseStream) {
                    $reader = [IO.StreamReader]::new($responseStream)
                    try {
                        $responseText = $reader.ReadToEnd()
                    }
                    finally {
                        $reader.Dispose()
                    }
                }
            }
        }
        catch {
            $responseText = ''
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($responseText)) {
        try {
            $response = $responseText | ConvertFrom-Json
        }
        catch {
            $response = $null
        }
    }

    $errorCode = if ($response -and $response.PSObject.Properties['error']) {
        [string] $response.error
    }
    else {
        ''
    }
    $serverMessage = if ($response -and $response.PSObject.Properties['message']) {
        [string] $response.message
    }
    else {
        ''
    }
    $statusCode = if ($httpResponse -and
        $httpResponse.PSObject.Properties['StatusCode']) {
        [int] $httpResponse.StatusCode
    }
    elseif ($ErrorRecord.Exception.Message -match '(?<!\d)403(?!\d)') {
        403
    }
    else {
        0
    }

    $message = switch ($errorCode) {
        'groupTagNotAllowed' {
            "Group Tag '$GroupTag' is not allowed for the signed-in user. Verify the tag and the user's Entra group assignments."
        }
        'authenticationRequired' {
            'Authentication is required. Sign in again and retry the import.'
        }
        'invalidPrincipal' {
            'The signed-in identity could not be validated by the service. Sign in again and retry the import.'
        }
        'invalidRequest' {
            if ([string]::IsNullOrWhiteSpace($serverMessage)) {
                'The import request is invalid.'
            }
            else {
                "The import request is invalid: $serverMessage"
            }
        }
        'graphImportFailed' {
            'Microsoft Graph rejected or could not complete the Autopilot import. Contact the service administrator.'
        }
        'serviceNotConfigured' {
            'The Autopilot import service is not configured correctly. Contact the service administrator.'
        }
        default {
            if ($statusCode -eq 403) {
                "Group Tag '$GroupTag' is not allowed for the signed-in user. Verify the tag and the user's Entra group assignments."
            }
            elseif (-not [string]::IsNullOrWhiteSpace($serverMessage)) {
                $serverMessage
            }
            else {
                $ErrorRecord.Exception.Message
            }
        }
    }

    $correlationId = if ($response -and
        $response.PSObject.Properties['correlationId']) {
        [string] $response.correlationId
    }
    else {
        ''
    }
    if ([string]::IsNullOrWhiteSpace($correlationId) -and $httpResponse -and
        $httpResponse.PSObject.Properties['Headers']) {
        try {
            $headerValues = $null
            if ($httpResponse.Headers.PSObject.Methods['TryGetValues'] -and
                $httpResponse.Headers.TryGetValues(
                    'X-Correlation-Id', [ref] $headerValues)) {
                $correlationId = [string] (@($headerValues) | Select-Object -First 1)
            }
            else {
                $correlationId = [string] `
                    $httpResponse.Headers['X-Correlation-Id']
            }
        }
        catch {
            $correlationId = ''
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($correlationId)) {
        Write-Verbose "Correlation ID: $correlationId."
    }
    return $message
}

function Write-AutoPilotImportStatus {
    <#
    .SYNOPSIS
    Displays the current status of an Autopilot import.

    .DESCRIPTION
    Writes a timestamped status line containing the Intune import, workflow,
    and Entra extension-attribute processing states.

    .PARAMETER Status
    REST status response returned for an accepted import.

    .OUTPUTS
    None. Status information is written to the host.
    #>
    param([Parameter(Mandatory)][object] $Status)

    $extensionStatus = if ($Status.PSObject.Properties['extensionAttributeStatus']) {
        [string] $Status.extensionAttributeStatus
    }
    else {
        'pending'
    }
    Write-Host ('[{0}] {1}: import={2}, workflow={3}, device attribute={4}' -f `
        (Get-Date -Format 'HH:mm:ss'),
        [string] $Status.serialNumber,
        [string] $Status.status,
        [string] $Status.workflowStatus,
        $extensionStatus)
}

$applicationUri = Resolve-AutoPilotApplicationUrl -Url $ApplicationUrl
Write-Verbose "Resolved application URL to '$($applicationUri.AbsoluteUri)'."
$runtimeConfiguration = Get-AutoPilotRuntimeConfiguration `
    -ApplicationUri $applicationUri
# The outer array prevents one CSV row from becoming a scalar under PS 5.1.
$devices = @(
    if ($PSBoundParameters.ContainsKey('CsvPath')) {
        Get-AutoPilotCsvDevice -Path $CsvPath
    }
    else {
        Get-LocalAutoPilotDevice
    }
)
Write-Verbose "Validated $($devices.Count) device record(s) from $(if ($CsvPath) { "CSV '$((Resolve-Path -LiteralPath $CsvPath).Path)'" } else { 'the local Windows device' })."

if ($ValidateOnly) {
    Write-Verbose 'Validation completed; authentication and import were skipped.'
    return [pscustomobject]@{
        ApplicationUrl = $runtimeConfiguration.ApplicationUrl
        ImportUrl = $runtimeConfiguration.ImportUrl
        TenantId = $runtimeConfiguration.TenantId
        DeviceSource = if ($CsvPath) {
            (Resolve-Path -LiteralPath $CsvPath).Path
        }
        else {
            'Local device'
        }
        DeviceCount = $devices.Count
        SerialNumbers = @($devices.SerialNumber)
        GroupTag = $GroupTag
        IsValid = $true
    }
}

$target = "$($devices.Count) device(s) using '$($runtimeConfiguration.ApplicationUrl)'"
# Low impact preserves -WhatIf without prompting under PowerShell defaults.
if (-not $PSCmdlet.ShouldProcess($target, "Import with Group Tag '$GroupTag'")) {
    return
}

Write-Verbose "Starting import of $($devices.Count) device(s) with Group Tag '$GroupTag'."
$token = Get-AutoPilotAccessToken `
    -TenantId $runtimeConfiguration.TenantId `
    -ApiAudience $runtimeConfiguration.ApiAudience
$authorizationHeaders = @{
    Authorization = "Bearer $token"
}
$tokenAcquiredAt = [datetimeoffset]::Now
$pendingImports = [Collections.Generic.List[object]]::new()

foreach ($device in $devices) {
    $body = @{
        serialNumber = $device.SerialNumber
        hardwareIdentifier = $device.HardwareHash
        groupTag = $GroupTag
    } | ConvertTo-Json -Compress
    try {
        Write-Verbose "Submitting import request for serial '$($device.SerialNumber)'."
        $response = Invoke-RestMethod `
            -Method Post `
            -Uri $runtimeConfiguration.ImportUrl `
            -Headers $authorizationHeaders `
            -ContentType 'application/json' `
            -Body $body `
            -ErrorAction Stop
    }
    catch {
        $errorMessage = Get-AutoPilotRestErrorMessage `
            -ErrorRecord $_ `
            -GroupTag $GroupTag
        Write-Host `
            "Import failed for serial '$($device.SerialNumber)'. $errorMessage" `
            -ForegroundColor Red
        exit 1
    }
    $pendingImports.Add([pscustomobject]@{
        ImportId = [guid] $response.importId
        SerialNumber = $device.SerialNumber
        LastStatus = $response
    })
    Write-Host "Import accepted for '$($device.SerialNumber)' with ID '$($response.importId)'."
}

$finalStatuses = [Collections.Generic.List[object]]::new()
while ($pendingImports.Count -gt 0) {
    # Poll all accepted imports until backend and extension-attribute work is terminal.
    Write-Verbose "Waiting $pollIntervalSeconds seconds before polling $($pendingImports.Count) pending import(s)."
    Start-Sleep -Seconds $pollIntervalSeconds
    # Refresh before typical access-token expiry during unusually long imports.
    if (([datetimeoffset]::Now - $tokenAcquiredAt).TotalMinutes -ge 45) {
        Write-Verbose 'Refreshing the API access token before polling continues.'
        $token = Get-AutoPilotAccessToken `
            -TenantId $runtimeConfiguration.TenantId `
            -ApiAudience $runtimeConfiguration.ApiAudience
        $authorizationHeaders.Authorization = "Bearer $token"
        $tokenAcquiredAt = [datetimeoffset]::Now
    }

    foreach ($pendingImport in @($pendingImports)) {
        $statusUrl = "$($runtimeConfiguration.ImportUrl)?importId=$($pendingImport.ImportId)"
        try {
            Write-Verbose "Requesting status for import '$($pendingImport.ImportId)' and serial '$($pendingImport.SerialNumber)'."
            $status = Invoke-RestMethod `
                -Method Get `
                -Uri $statusUrl `
                -Headers $authorizationHeaders `
                -ErrorAction Stop
        }
        catch {
            Write-Warning "Status request for '$($pendingImport.SerialNumber)' failed and will be retried in $pollIntervalSeconds seconds. $(Get-AutoPilotRestErrorMessage -ErrorRecord $_ -GroupTag $GroupTag)"
            continue
        }

        $pendingImport.LastStatus = $status
        Write-AutoPilotImportStatus -Status $status
        if (([string] $status.workflowStatus) -in @('complete', 'error')) {
            $finalStatuses.Add($status)
            [void] $pendingImports.Remove($pendingImport)
        }
    }
}

$failedStatuses = @(
    $finalStatuses |
        Where-Object { [string] $_.workflowStatus -eq 'error' }
)
$finalStatuses | Write-Output
if ($failedStatuses.Count -gt 0) {
    $failedSerials = @($failedStatuses.serialNumber) -join ', '
    throw "Autopilot import failed for: $failedSerials. Review deviceErrorCode and deviceErrorName in the service response."
}
