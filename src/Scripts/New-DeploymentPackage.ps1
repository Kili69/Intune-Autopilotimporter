#Requires -Version 7.2
# Project-Version: 1.2.20260929.4
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
Reads the project version from VERSION and resolves the current branch from an
explicit parameter, CI environment, or Git. It creates a ZIP archive containing
the files required to install, update, and operate Autopilot Import. Package
content is selected from an explicit allowlist so local configuration, tests,
logs, repository metadata, and generated files are not included.

Before packaging, the script verifies that PowerShell version markers and the
client module manifest match VERSION. It also verifies that the prebuilt web
frontend and all assets referenced by its index exist. The web frontend keeps
its previously built version until its source changes.

The archive contains a top-level directory named
Intune-autopilotImporter-<branch><version>. An existing archive for the same
branch and version is replaced. Temporary staging files are removed after
packaging, including when package creation fails.

.PARAMETER ProjectRoot
Root directory of the Autopilot Import source tree. The default is the
repository root.

.PARAMETER OutputDirectory
Directory in which the deployment ZIP is created. The default is the
InstallationPackage directory below ProjectRoot.

.PARAMETER BranchName
Source branch included in the package name. When omitted, the script uses the
GitHub or Azure Pipelines branch environment and then the current local Git
branch. Characters invalid for a portable file name are replaced with hyphens.

.EXAMPLE
.\src\Scripts\New-DeploymentPackage.ps1

Creates the versioned deployment package in the repository's InstallationPackage
directory.

.EXAMPLE
.\src\Scripts\New-DeploymentPackage.ps1 `
    -ProjectRoot 'C:\Repos\Intune-Autopilotimporter' `
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
    [string] $ProjectRoot = (Split-Path `
        (Split-Path $PSScriptRoot -Parent) `
        -Parent),

    [string] $OutputDirectory = (Join-Path `
        (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) `
        'InstallationPackage'),

    [string] $BranchName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-BuiltWebFrontend {
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )

    $sourceWebRoot = Join-Path $Root `
        'src\FunctionApp\WebFrontend\wwwroot'
    $webRoot = if (Test-Path -LiteralPath $sourceWebRoot -PathType Container) {
        $sourceWebRoot
    }
    else {
        Join-Path $Root 'WebFrontend\wwwroot'
    }
    $indexPath = Join-Path $webRoot 'index.html'
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        throw "The prebuilt web frontend is missing: $indexPath. Run 'npm ci' and 'npm run build' in the web directory before creating a deployment package."
    }

    $index = Get-Content -LiteralPath $indexPath -Raw
    $assetMatches = [regex]::Matches(
        $index,
        '(?:src|href)=["''](?:/api/ui/)?(?<path>assets/[^"'']+)["'']'
    )
    if ($assetMatches.Count -eq 0) {
        throw "The prebuilt web frontend index does not reference any assets: $indexPath"
    }

    $hasJavaScriptAsset = $false
    foreach ($assetMatch in $assetMatches) {
        $relativePath = $assetMatch.Groups['path'].Value.Replace(
            '/',
            [IO.Path]::DirectorySeparatorChar
        )
        $assetPath = Join-Path $webRoot $relativePath
        if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
            throw "The prebuilt web frontend asset is missing: $assetPath. Run 'npm ci' and 'npm run build' in the web directory before creating a deployment package."
        }
        if ([IO.Path]::GetExtension($assetPath) -eq '.js') {
            $hasJavaScriptAsset = $true
        }
    }

    if (-not $hasJavaScriptAsset) {
        throw "The prebuilt web frontend index does not reference a JavaScript asset: $indexPath"
    }
}

function Assert-ProjectVersionConsistency {
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $ProjectVersion
    )

    if ($ProjectVersion -notmatch '^\d+\.\d+\.\d{8}\.\d+$') {
        throw "VERSION contains an invalid project version: $ProjectVersion"
    }

    $powerShellFiles = @(
        Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object {
            $_.Extension -in '.ps1', '.psm1', '.psd1' -and
            $_.FullName -notmatch '[\\/](?:node_modules|InstallationPackage|\.git)[\\/]'
        }
    )
    foreach ($file in $powerShellFiles) {
        $content = Get-Content -LiteralPath $file.FullName -Raw
        $markers = [regex]::Matches(
            $content,
            '(?m)^# Project-Version: (?<version>\d+\.\d+\.\d{8}\.\d+)\r?$'
        )
        if ($markers.Count -ne 1) {
            throw "PowerShell file '$($file.FullName)' must contain exactly one Project-Version marker."
        }
        $fileVersion = $markers[0].Groups['version'].Value
        if ($fileVersion -ne $ProjectVersion) {
            throw "PowerShell file '$($file.FullName)' uses project version $fileVersion instead of $ProjectVersion."
        }
    }

    $manifestPath = Join-Path $Root `
        'src\AutopilotImport.Client\AutopilotImport.Client.psd1'
    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    if ([string] $manifest.ModuleVersion -ne $ProjectVersion) {
        throw "Client module manifest uses version $($manifest.ModuleVersion) instead of $ProjectVersion."
    }
}

function Resolve-PackageBranchName {
    param(
        [string] $Name,
        [Parameter(Mandatory)]
        [string] $Root
    )

    $resolvedName = $Name
    if ([string]::IsNullOrWhiteSpace($resolvedName)) {
        $resolvedName = @(
            $env:GITHUB_HEAD_REF
            $env:GITHUB_REF_NAME
            $env:BUILD_SOURCEBRANCHNAME
        ) | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | Select-Object -First 1
    }
    if ([string]::IsNullOrWhiteSpace($resolvedName)) {
        $gitCommand = Get-Command git -ErrorAction SilentlyContinue
        if ($gitCommand) {
            $resolvedName = (& $gitCommand.Source `
                -C $Root `
                branch `
                --show-current 2>$null).Trim()
            if ($LASTEXITCODE -ne 0) {
                $resolvedName = $null
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($resolvedName)) {
        throw 'The source branch could not be determined. Use -BranchName.'
    }

    $safeName = $resolvedName.Trim() -replace '[^A-Za-z0-9._-]', '-'
    $safeName = $safeName.Trim('-', '.')
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        throw "Branch name '$resolvedName' does not contain any portable file-name characters."
    }
    return $safeName
}

# Use the central project version for both the archive and its root directory.
$projectVersion = (Get-Content `
    -LiteralPath (Join-Path $ProjectRoot 'VERSION') `
    -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($projectVersion)) {
    throw 'VERSION must contain a package version.'
}

$packageBranch = Resolve-PackageBranchName `
    -Name $BranchName `
    -Root $ProjectRoot
$packageName = "Intune-autopilotImporter-$packageBranch$projectVersion"
$stagingRoot = Join-Path ([IO.Path]::GetTempPath()) `
    "$packageName-$([guid]::NewGuid().ToString('N'))"
$packageRoot = Join-Path $stagingRoot $packageName
$packagePath = Join-Path $OutputDirectory "$packageName.zip"

Assert-ProjectVersionConsistency `
    -Root $ProjectRoot `
    -ProjectVersion $projectVersion
Assert-BuiltWebFrontend -Root $ProjectRoot

# Keep package content explicit so local configuration and development files stay excluded.
$packageEntries = @(
    @{ Source = 'AUTHOR'; Destination = 'AUTHOR' }
    @{ Source = 'History.md'; Destination = 'History.md' }
    @{ Source = 'README.md'; Destination = 'README.md' }
    @{ Source = 'VERSION'; Destination = 'VERSION' }
    @{ Source = 'src\FunctionApp\host.json'; Destination = 'host.json' }
    @{ Source = 'src\FunctionApp\proxies.json'; Destination = 'proxies.json' }
    @{ Source = 'src\FunctionApp\requirements.psd1'; Destination = 'requirements.psd1' }
    @{ Source = 'src\FunctionApp\profile.ps1'; Destination = 'profile.ps1' }
    @{ Source = 'src\Installer\client.settings.json.example'; Destination = 'client.settings.json.example' }
    @{ Source = 'src\Installer\local.settings.json.example'; Destination = 'local.settings.json.example' }
    @{ Source = 'src\Installer\Install-AutopilotImport.ps1'; Destination = 'Install-AutopilotImport.ps1' }
    @{ Source = 'src\Installer\Update-AutopilotImport.ps1'; Destination = 'Update-AutopilotImport.ps1' }
    @{ Source = 'src\FunctionApp\ImportDevice'; Destination = 'ImportDevice' }
    @{ Source = 'src\FunctionApp\GetAuthorizedTags'; Destination = 'GetAuthorizedTags' }
    @{ Source = 'src\FunctionApp\GetImportHistory'; Destination = 'GetImportHistory' }
    @{ Source = 'src\FunctionApp\ManageTagPolicy'; Destination = 'ManageTagPolicy' }
    @{ Source = 'src\FunctionApp\ProcessDeviceAttribute'; Destination = 'ProcessDeviceAttribute' }
    @{ Source = 'src\FunctionApp\RemoveExpiredImportHistory'; Destination = 'RemoveExpiredImportHistory' }
    @{ Source = 'src\FunctionApp\WebFrontend'; Destination = 'WebFrontend' }
    @{ Source = 'src\Infrastructure'; Destination = 'infra' }
    @{ Source = 'src\Scripts\Ensure-EntraApiApplication.ps1'; Destination = 'scripts\Ensure-EntraApiApplication.ps1' }
    @{ Source = 'src\Scripts\Ensure-EntraWebApplication.ps1'; Destination = 'scripts\Ensure-EntraWebApplication.ps1' }
    @{ Source = 'src\Scripts\Grant-ManagedIdentityGraphPermission.ps1'; Destination = 'scripts\Grant-ManagedIdentityGraphPermission.ps1' }
    @{ Source = 'src\Scripts\Import-AutopilotDevice.ps1'; Destination = 'scripts\Import-AutopilotDevice.ps1' }
    @{ Source = 'src\Scripts\Start-IntuneAutopilotImporter.ps1'; Destination = 'scripts\Start-IntuneAutopilotImporter.ps1' }
    @{ Source = 'src\Scripts\Set-TagAuthorizationPolicy.ps1'; Destination = 'scripts\Set-TagAuthorizationPolicy.ps1' }
    @{ Source = 'src\Scripts\Set-TagPolicyManagers.ps1'; Destination = 'scripts\Set-TagPolicyManagers.ps1' }
    @{ Source = 'src\FunctionApp\src\AutopilotImport'; Destination = 'src\AutopilotImport' }
    @{ Source = 'src\AutopilotImport.Client'; Destination = 'src\AutopilotImport.Client' }
    @{ Source = 'src\Web\index.html'; Destination = 'web\index.html' }
    @{ Source = 'src\Web\package.json'; Destination = 'web\package.json' }
    @{ Source = 'src\Web\package-lock.json'; Destination = 'web\package-lock.json' }
    @{ Source = 'src\Web\tsconfig.json'; Destination = 'web\tsconfig.json' }
    @{ Source = 'src\Web\vite.config.ts'; Destination = 'web\vite.config.ts' }
    @{ Source = 'src\Web\src'; Destination = 'web\src' }
)

try {
    # Assemble the distributable directory in a unique temporary location.
    New-Item -Path $packageRoot -ItemType Directory -Force | Out-Null
    foreach ($entry in $packageEntries) {
        $sourcePath = Join-Path $ProjectRoot $entry.Source
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            throw "Required deployment package entry was not found: $sourcePath"
        }
        $destinationPath = Join-Path $packageRoot $entry.Destination
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