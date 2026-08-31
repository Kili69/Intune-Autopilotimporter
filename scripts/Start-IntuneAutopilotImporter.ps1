<#PSScriptInfo

.VERSION 1.0.20260831.1
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
# Project-Version: 1.0.20260831.1
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

function Resolve-AutopilotImporterWebUrl {
    [CmdletBinding()]
    param(
        [string] $Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        $Url = Read-Host 'Autopilot Import web URL'
    }

    $parsedUrl = $null
    if (-not [uri]::TryCreate($Url.Trim(), [UriKind]::Absolute, [ref] $parsedUrl) -or
        $parsedUrl.Scheme -ne 'https') {
        throw 'WebUrl must be an absolute HTTPS URL.'
    }

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
    $builder.Query = ''
    $builder.Fragment = ''
    return $builder.Uri
}

function Get-AutopilotImporterConfigUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [uri] $WebUri
    )

    return [uri]::new($WebUri, './config')
}

function Get-MicrosoftEdgePath {
    [CmdletBinding()]
    param()

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

    $edgePath = $candidates | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    } | Select-Object -First 1
    if (-not $edgePath) {
        throw "Microsoft Edge was not found. Checked: $($candidates -join ', ')"
    }
    return $edgePath
}

function Get-LocalAutopilotDeviceInformation {
    [CmdletBinding()]
    param()

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Autopilot hardware hash collection is supported only on Windows.'
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an elevated PowerShell session.'
    }

    $serialNumber = [string] (Get-CimInstance `
        -ClassName Win32_BIOS `
        -ErrorAction Stop).SerialNumber
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
    try {
        $hashBytes = [Convert]::FromBase64String($hardwareHash)
    }
    catch {
        throw 'Windows returned invalid Autopilot DeviceHardwareData.'
    }
    if ($hashBytes.Length -eq 0) {
        throw 'Windows returned an empty Autopilot hardware hash.'
    }

    [pscustomobject][ordered]@{
        'Device Serial Number' = $serialNumber.Trim()
        'Windows Product ID'   = ''
        'Hardware Hash'        = $hardwareHash
        'Group Tag'            = ''
        'Assigned User'        = ''
    }
}

$resolvedWebUrl = Resolve-AutopilotImporterWebUrl -Url $WebUrl
$resolvedOutputPath = [IO.Path]::GetFullPath($OutputPath)

if (-not $SkipWebValidation) {
    $configUrl = Get-AutopilotImporterConfigUrl -WebUri $resolvedWebUrl
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
    foreach ($propertyName in @('clientId', 'authority', 'scope', 'importUrl')) {
        if (-not $runtimeConfig.PSObject.Properties[$propertyName] -or
            [string]::IsNullOrWhiteSpace([string] $runtimeConfig.$propertyName)) {
            throw "The frontend configuration at '$configUrl' does not contain '$propertyName'."
        }
    }
}

if (-not $PSCmdlet.ShouldProcess(
        $resolvedOutputPath,
        'Collect the Autopilot hardware hash and create the CSV')) {
    Write-Host "Would open '$resolvedWebUrl' after creating '$resolvedOutputPath'."
    return
}

$outputDirectory = Split-Path $resolvedOutputPath -Parent
New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
$device = Get-LocalAutopilotDeviceInformation
$device | Export-Csv `
    -LiteralPath $resolvedOutputPath `
    -NoTypeInformation `
    -Encoding UTF8 `
    -Force
$csvFile = Get-Item -LiteralPath $resolvedOutputPath

try {
    Set-Clipboard -Value $csvFile.FullName -ErrorAction Stop
    Write-Host "Autopilot CSV created: $($csvFile.FullName)"
    Write-Host 'The CSV path was copied to the clipboard. Paste it into the file picker.'
}
catch {
    Write-Host "Autopilot CSV created: $($csvFile.FullName)"
}

$edgePath = Get-MicrosoftEdgePath
$edgeArguments = @()
if (-not $NoInPrivate) {
    $edgeArguments += '--inprivate'
}
$edgeArguments += $resolvedWebUrl.AbsoluteUri
Start-Process -FilePath $edgePath -ArgumentList $edgeArguments

$csvFile
