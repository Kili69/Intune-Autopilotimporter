#Requires -Version 7.2
# Project-Version: 1.0.20260911.1
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
Creates a versioned deployment package for Autopilot Import.

.DESCRIPTION
Reads the project version from VERSION and creates a ZIP archive containing
the files required to install, update, and operate Autopilot Import. Package
content is selected from an explicit allowlist so local configuration, tests,
logs, repository metadata, and generated files are not included.

The archive contains a top-level directory named
Intune-Autopilotimport-deployment-<version>. An existing archive for the same
version is replaced. Temporary staging files are removed after packaging,
including when package creation fails.

.PARAMETER ProjectRoot
Root directory of the Autopilot Import source tree. The default is the parent
directory of this script's directory.

.PARAMETER OutputDirectory
Directory in which the deployment ZIP is created. The default is the
artifacts directory below ProjectRoot.

.EXAMPLE
.\scripts\New-DeploymentPackage.ps1

Creates the versioned deployment package in the repository's artifacts
directory.

.EXAMPLE
.\scripts\New-DeploymentPackage.ps1 `
    -ProjectRoot 'C:\Repos\Intue-Autopilotimporter' `
    -OutputDirectory 'C:\DeploymentPackages'

Creates the deployment package from an explicit source tree in a custom
destination directory.

.OUTPUTS
System.IO.FileInfo. Returns the created deployment ZIP file.

.NOTES
The package intentionally excludes client.settings.json and
local.settings.json because they can contain deployment-specific or sensitive
values. Their example files are included instead.
#>

[CmdletBinding()]
param(
    [string] $ProjectRoot = (Split-Path $PSScriptRoot -Parent),

    [string] $OutputDirectory = (Join-Path `
        (Split-Path $PSScriptRoot -Parent) `
        'artifacts')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Use the central project version for both the archive and its root directory.
$projectVersion = (Get-Content `
    -LiteralPath (Join-Path $ProjectRoot 'VERSION') `
    -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($projectVersion)) {
    throw 'VERSION must contain a package version.'
}

$packageName = "Intune-Autopilotimport-deployment-$projectVersion"
$stagingRoot = Join-Path ([IO.Path]::GetTempPath()) `
    "$packageName-$([guid]::NewGuid().ToString('N'))"
$packageRoot = Join-Path $stagingRoot $packageName
$packagePath = Join-Path $OutputDirectory "$packageName.zip"

# Keep package content explicit so local configuration and development files stay excluded.
$packageEntries = @(
    'AUTHOR'
    'README.md'
    'VERSION'
    'host.json'
    'requirements.psd1'
    'profile.ps1'
    'client.settings.json.example'
    'local.settings.json.example'
    'Install-AutopilotImport.ps1'
    'Update-AutopilotImport.ps1'
    'ImportDevice'
    'ManageTagPolicy'
    'ProcessDeviceAttribute'
    'Ui'
    'WebFrontend'
    'infra'
    'scripts\Ensure-EntraApiApplication.ps1'
    'scripts\Grant-ManagedIdentityGraphPermission.ps1'
    'scripts\Import-AutopilotDevice.ps1'
    'scripts\Set-TagAuthorizationPolicy.ps1'
    'scripts\Set-TagPolicyManagers.ps1'
    'src'
)

try {
    # Assemble the distributable directory in a unique temporary location.
    New-Item -Path $packageRoot -ItemType Directory -Force | Out-Null
    foreach ($entry in $packageEntries) {
        $sourcePath = Join-Path $ProjectRoot $entry
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            throw "Required deployment package entry was not found: $sourcePath"
        }
        $destinationPath = Join-Path $packageRoot $entry
        New-Item `
            -Path (Split-Path $destinationPath -Parent) `
            -ItemType Directory `
            -Force | Out-Null
        Copy-Item `
            -LiteralPath $sourcePath `
            -Destination $destinationPath `
            -Recurse `
            -Force
    }

    # Compress the complete package root and replace an existing archive of this version.
    New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
    Compress-Archive `
        -Path $packageRoot `
        -DestinationPath $packagePath `
        -CompressionLevel Optimal `
        -Force

    Get-Item -LiteralPath $packagePath
}
finally {
    # Always remove staging data, including after copy or compression failures.
    Remove-Item `
        -LiteralPath $stagingRoot `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}