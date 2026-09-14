<#PSScriptInfo

.VERSION 1.1.20260914.1
.GUID 8f3a78b6-8c87-4a89-b8cf-fb20f90ef96d
.AUTHOR andreas.lucas@microsoft.com (aka Kili)
.COMPANYNAME Community
.COPYRIGHT (c) 2026 andreas.lucas@microsoft.com. All rights reserved.
.TAGS Windows Autopilot Intune OOBE DeviceHash MicrosoftEdge
.PROJECTURI https://github.com/anluca_microsoft/Intune-Autopilotimporter
.RELEASENOTES
Creates an Autopilot hardware hash CSV and opens the secured web importer.

#>

#Requires -Version 5.1
# Project-Version: 1.1.20260914.1
# Author: andreas.lucas@microsoft.com (aka Kili)

<#
.SYNOPSIS
Creates a Windows Autopilot device hash and opens the web importer.

.DESCRIPTION
Reads the device serial number and hardware hash locally through CIM, writes a
standard Autopilot CSV to the current user's temporary directory, validates the
configured Azure Function web frontend, copies the CSV path to the clipboard
when possible, and opens the frontend in a Microsoft Edge InPrivate window.

The script does not upload the hardware hash. Select the generated CSV in the
web frontend to review and submit it after signing in with Microsoft Entra ID.

.PARAMETER WebUrl
HTTPS URL of the deployed Autopilot Import web frontend. When omitted, the
script prompts for it. The expected URL ends in /api/ui/index.html.

.PARAMETER OutputPath
Path for the generated CSV. The default is AutopilotHWID.csv in the current
user's temporary directory.

.PARAMETER NoInPrivate
Opens Microsoft Edge without InPrivate mode.

.PARAMETER SkipWebValidation
Skips the request to the frontend's public runtime configuration endpoint.
Use only when that endpoint cannot be reached during an offline test.

.EXAMPLE
Start-IntuneAutopilotImporter.ps1

Prompts for the frontend URL, creates the CSV, and opens Microsoft Edge.

.EXAMPLE
Start-IntuneAutopilotImporter.ps1 `
    -WebUrl 'https://func-example.azurewebsites.net/api/ui/index.html'

Creates the CSV and opens the specified importer page.

.EXAMPLE
Start-IntuneAutopilotImporter.ps1 `
    -WebUrl 'https://func-example.azurewebsites.net/api/ui/index.html' `
    -WhatIf

Validates the parameters and shows the planned actions without reading the
hardware hash, writing a file, or starting Microsoft Edge.

.OUTPUTS
System.IO.FileInfo representing the generated Autopilot CSV.

.NOTES
Run from an elevated Windows PowerShell or PowerShell session. During Windows
OOBE, press Shift+F10 and start powershell.exe first.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateNotNullOrEmpty()]
    [string] $WebUrl,

    [ValidateNotNullOrEmpty()]
    [string] $OutputPath = (Join-Path ([IO.Path]::GetTempPath()) 'AutopilotHWID.csv'),

    [switch] $NoInPrivate,

    [switch] $SkipWebValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AutoPilotImporterWebUrl {
    <#
    .SYNOPSIS
    Validates and normalizes the Autopilot Import frontend URL.

    .DESCRIPTION
    Accepts the Function App root URL, the /api/ui route, or the complete
    /api/ui/index.html URL. The function normalizes all supported forms to the
    complete frontend document URL and removes query strings and fragments.

    Only absolute HTTPS URLs are accepted because the frontend handles a
    Microsoft Entra authorization code flow and must not expose authentication
    data over an unencrypted connection.

    .PARAMETER Url
    Candidate frontend URL. If it is empty, the operator is prompted for a URL.

    .OUTPUTS
    System.Uri containing the normalized frontend URL.

    .EXAMPLE
    Resolve-AutoPilotImporterWebUrl `
        -Url 'https://func-example.azurewebsites.net'

    Returns https://func-example.azurewebsites.net/api/ui/index.html.
    #>
    [CmdletBinding()]
    param(
        [string] $Url
    )

    # Prompt only when the caller did not provide a usable value. Keeping the
    # prompt inside this function makes URL handling reusable in tests.
    if ([string]::IsNullOrWhiteSpace($Url)) {
        $Url = Read-Host 'Autopilot Import web URL'
    }

    # TryCreate prevents malformed input from producing less helpful exceptions.
    # HTTPS is mandatory for both the browser frontend and Entra authentication.
    $parsedUrl = $null
    if (-not [uri]::TryCreate($Url.Trim(), [UriKind]::Absolute, [ref] $parsedUrl) -or
        $parsedUrl.Scheme -ne 'https') {
        throw 'WebUrl must be an absolute HTTPS URL.'
    }

    # UriBuilder safely changes only the path while preserving the scheme,
    # hostname, optional port, and any custom DNS alias supplied by the caller.
    $builder = [UriBuilder]::new($parsedUrl)
    if ($builder.Path -eq '/' -or [string]::IsNullOrWhiteSpace($builder.Path)) {
        $builder.Path = '/api/ui/index.html'
    }
    elseif ($builder.Path.TrimEnd('/') -eq '/api/ui') {
        $builder.Path = '/api/ui/index.html'
    }
    elseif (-not $builder.Path.EndsWith('/api/ui/index.html',
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'WebUrl must identify the Function App root, /api/ui, or /api/ui/index.html.'
    }

    # Query parameters and fragments are not part of the configured SPA redirect
    # URI and could make frontend validation target an unexpected resource.
    $builder.Query = ''
    $builder.Fragment = ''
    return $builder.Uri
}

function Get-AutoPilotImporterConfigUrl {
    <#
    .SYNOPSIS
    Derives the public runtime configuration endpoint from the frontend URL.

    .DESCRIPTION
    Resolves the relative path ./config against /api/ui/index.html. This yields
    /api/ui/config on the same scheme, host, and port, including when the
    Function App is accessed through a custom DNS name.

    .PARAMETER WebUri
    Normalized URI returned by Resolve-AutoPilotImporterWebUrl.

    .OUTPUTS
    System.Uri for the frontend runtime configuration endpoint.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [uri] $WebUri
    )

    return [uri]::new($WebUri, './config')
}

function Get-MicrosoftEdgePath {
    <#
    .SYNOPSIS
    Locates the Microsoft Edge executable on the local Windows installation.

    .DESCRIPTION
    Checks the standard per-machine 32-bit and 64-bit installation directories,
    followed by the current user's local application directory. Returning an
    explicit executable path avoids relying on PATH or on the CMD-specific
    start command syntax, neither of which is reliable during Windows OOBE.

    .OUTPUTS
    System.String containing the first existing msedge.exe path.

    .NOTES
    Throws a terminating error listing every candidate when Edge cannot be
    found. The caller therefore never attempts to start an unknown executable.
    #>
    [CmdletBinding()]
    param()

    # Command substitutions let missing environment variables contribute no
    # value. The subsequent filter removes null or empty candidate entries.
    $candidates = @(
        $(if (${env:ProgramFiles(x86)}) {
            Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'
        })
        $(if ($env:ProgramFiles) {
            Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'
        })
        $(if ($env:LOCALAPPDATA) {
            Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe'
        })
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) }

    # Prefer the conventional system installation over a per-user installation.
    $edgePath = $candidates | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    } | Select-Object -First 1
    if (-not $edgePath) {
        throw "Microsoft Edge was not found. Checked: $($candidates -join ', ')"
    }
    return $edgePath
}

function Get-LocalAutopilotDeviceInformation {
    <#
    .SYNOPSIS
    Reads the local device identity required by Windows Autopilot.

    .DESCRIPTION
    Reads the BIOS serial number from Win32_BIOS and the Autopilot hardware hash
    from the MDM Bridge WMI provider. The MDM_DevDetail_Ext01 class exposes the
    DeviceHardwareData value generated by Windows for the current device.

    Administrative elevation is required to query the MDM Bridge namespace.
    The function validates that both values are present and confirms that the
    hardware hash is non-empty Base64 before constructing the CSV row.

    No network request is made and no device identity is uploaded by this
    function.

    .OUTPUTS
    PSCustomObject whose ordered properties match the standard Windows
    Autopilot CSV column names.
    #>
    [CmdletBinding()]
    param()

    # Fail early on non-Windows platforms where the required CIM providers do
    # not exist, even if PowerShell itself is available.
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Autopilot hardware hash collection is supported only on Windows.'
    }

    # Querying root/cimv2/mdm/dmmap normally requires an elevated token. An
    # explicit check produces a clearer error than a later CIM access failure.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an elevated PowerShell session.'
    }

    # Win32_BIOS provides the manufacturer-programmed serial number used to
    # identify the device in Intune and Windows Autopilot.
    $serialNumber = [string] (Get-CimInstance `
        -ClassName Win32_BIOS `
        -ErrorAction Stop).SerialNumber

    # The MDM Bridge provider exposes DeviceHardwareData only for the Ext device
    # detail instance. This is the same source used by standard Autopilot hash
    # collection tooling.
    $deviceDetail = Get-CimInstance `
        -Namespace 'root/cimv2/mdm/dmmap' `
        -ClassName 'MDM_DevDetail_Ext01' `
        -Filter "InstanceID='Ext' AND ParentID='./DevDetail'" `
        -ErrorAction Stop
    $hardwareHash = [string] $deviceDetail.DeviceHardwareData

    if ([string]::IsNullOrWhiteSpace($serialNumber)) {
        throw 'Windows did not return a device serial number.'
    }
    if ([string]::IsNullOrWhiteSpace($hardwareHash)) {
        throw 'Windows did not return Autopilot DeviceHardwareData.'
    }

    # Validate the payload without decoding or rewriting it. Exporting the
    # original Base64 text preserves the value expected by the Intune API.
    try {
        $hashBytes = [Convert]::FromBase64String($hardwareHash)
    }
    catch {
        throw 'Windows returned invalid Autopilot DeviceHardwareData.'
    }
    if ($hashBytes.Length -eq 0) {
        throw 'Windows returned an empty Autopilot hardware hash.'
    }

    # Ordered properties guarantee the conventional Autopilot CSV column order.
    # Group Tag and Assigned User remain blank so the operator can select or
    # review deployment metadata in the authenticated web frontend.
    [pscustomobject][ordered]@{
        'Device Serial Number' = $serialNumber.Trim()
        'Windows Product ID'   = ''
        'Hardware Hash'        = $hardwareHash
        'Group Tag'            = ''
        'Assigned User'        = ''
    }
}

# Normalize user input before performing any web, device, or filesystem work.
$resolvedWebUrl = Resolve-AutoPilotImporterWebUrl -Url $WebUrl
$resolvedOutputPath = [IO.Path]::GetFullPath($OutputPath)

if (-not $SkipWebValidation) {
    # The configuration endpoint is intentionally public: it contains tenant and
    # application identifiers, but no secret or access token. Reading it verifies
    # that the supplied URL points to a configured Autopilot Import deployment.
    $configUrl = Get-AutoPilotImporterConfigUrl -WebUri $resolvedWebUrl
    Write-Verbose "Validating frontend configuration at '$configUrl'."
    try {
        $runtimeConfig = Invoke-RestMethod `
            -Method Get `
            -Uri $configUrl `
            -TimeoutSec 30 `
            -ErrorAction Stop
    }
    catch {
        throw "The Autopilot Import frontend configuration could not be read from '$configUrl': $($_.Exception.Message)"
    }

    # These values are the minimum required for frontend authentication and API
    # calls. Validate their presence without attempting an interactive sign-in.
    foreach ($propertyName in @('clientId', 'authority', 'scope', 'importUrl')) {
        if (-not $runtimeConfig.PSObject.Properties[$propertyName] -or
            [string]::IsNullOrWhiteSpace([string] $runtimeConfig.$propertyName)) {
            throw "The frontend configuration at '$configUrl' does not contain '$propertyName'."
        }
    }
}

# ShouldProcess provides standard -WhatIf behavior. In WhatIf mode the script
# may validate the public frontend, but it never queries the local hardware hash,
# writes a CSV, accesses the clipboard, or starts Microsoft Edge.
if (-not $PSCmdlet.ShouldProcess(
        $resolvedOutputPath,
        'Collect the Autopilot hardware hash and create the CSV')) {
    Write-Host "Would open '$resolvedWebUrl' after creating '$resolvedOutputPath'."
    return
}

# Create the destination directory when necessary, collect one device record,
# and export it with headers compatible with Windows Autopilot CSV imports.
$outputDirectory = Split-Path $resolvedOutputPath -Parent
New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
$device = Get-LocalAutopilotDeviceInformation
$device | Export-Csv `
    -LiteralPath $resolvedOutputPath `
    -NoTypeInformation `
    -Encoding UTF8 `
    -Force
$csvFile = Get-Item -LiteralPath $resolvedOutputPath

# Clipboard integration is best-effort because Set-Clipboard might be absent or
# unavailable in restricted OOBE sessions. CSV creation remains successful when
# clipboard access fails, and the path is still printed for manual selection.
try {
    Set-Clipboard -Value $csvFile.FullName -ErrorAction Stop
    Write-Host "Autopilot CSV created: $($csvFile.FullName)"
    Write-Host 'The CSV path was copied to the clipboard. Paste it into the file picker.'
}
catch {
    Write-Host "Autopilot CSV created: $($csvFile.FullName)"
}

# Resolve Edge only after CSV creation so a browser discovery failure never
# prevents collection of the device identity. InPrivate is the default to reduce
# persistence of operator accounts and browser state on a newly provisioned PC.
$edgePath = Get-MicrosoftEdgePath
$edgeArguments = @()
if (-not $NoInPrivate) {
    $edgeArguments += '--inprivate'
}
$edgeArguments += $resolvedWebUrl.AbsoluteUri
Start-Process -FilePath $edgePath -ArgumentList $edgeArguments

# Return FileInfo for callers that want to log, copy, or otherwise process the
# generated file. Host messages above are informational and are not pipeline data.
$csvFile
