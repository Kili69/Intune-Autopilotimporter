# Developer Guide

This document describes the repository layout and the build process used to
create an Autopilot Import installation package.

## Repository Layout

The repository source layout is intentionally different from the installation
package layout. Development files are grouped below `src`, while the generated
ZIP keeps the established root-level layout expected by the installer and
updater.

```text
.
|-- .azure/                    Azure deployment planning metadata
|-- .github/                   GitHub Actions workflows
|-- .vscode/                   Shared VS Code workspace configuration
|-- InstallationPackage/      Generated local installation ZIP files
|-- src/                       Application source and development files
|   |-- AutopilotImport.Client/ Portable PowerShell client module
|   |-- FunctionApp/            Azure Functions deployment root
|   |-- Infrastructure/         Azure infrastructure as Bicep
|   |-- Installer/              Installer, updater, and config examples
|   |-- Scripts/                Build, administration, and client helpers
|   |-- Tests/                  Pester test suite
|   `-- Web/                    TypeScript/Vite frontend source
|-- AUTHOR                     Canonical project author
|-- README.md                  User and administrator documentation
|-- VERSION                    Canonical project version
`-- azure-pipelines.yml        Azure Pipelines build and deployment definition
```

Generated ZIP files, local settings, logs, CSV files, frontend dependencies,
and TypeScript build metadata are excluded by `.gitignore`.

### `src/FunctionApp`

This is the Azure Functions deployment root. `host.json`, `profile.ps1`,
`proxies.json`, and `requirements.psd1` must remain at this level because Azure
Functions loads them relative to the Function App root.

| Path | Purpose |
| --- | --- |
| `GetAuthorizedTags/` | Returns the Group Tags authorized for the signed-in user. |
| `ImportDevice/` | Validates and submits Autopilot device imports. |
| `ManageTagPolicy/` | Reads and updates Group Tag authorization policies. |
| `ProcessDeviceAttribute/` | Processes imported devices after registration. |
| `WebFrontend/` | Serves the compiled frontend and runtime configuration. |
| `src/FunctionApp/src/AutopilotImport/` | Shared PowerShell runtime module used by the Functions. |

### Other `src` Directories

| Path | Purpose |
| --- | --- |
| `src/AutopilotImport.Client/` | Portable PowerShell client module for import and policy operations. |
| `src/Infrastructure/` | Bicep infrastructure definition, including the Function App, Storage, authentication, monitoring, and role assignments. |
| `src/Installer/` | Installer, updater, and example configuration files. The scripts support both repository and extracted-package layouts. |
| `src/Scripts/` | Administrative helpers, client wrappers, package generation, test-data generation, and project versioning. |
| `src/Tests/` | Pester tests for modules, Functions, installer behavior, infrastructure contracts, workflows, and package contents. |
| `src/Web/` | TypeScript/Vite frontend source, tests, package lock, and build configuration. |

## Development Prerequisites

- PowerShell 7.2 or later (`pwsh`)
- Pester 5.0 or later
- Node.js 22 and npm to rebuild modified frontend sources. Release packages
  and repository source archives contain a prebuilt frontend, so installation
  and update do not require Node.js on the target computer.
- Git, unless `-BranchName` is supplied when building a package
- Azure Functions Core Tools when running the Function App locally
- Bicep CLI or the installer-supported standalone Bicep CLI when validating
  infrastructure locally

Install Pester for the current user when it is not already available:

```powershell
Install-Module Pester `
    -Scope CurrentUser `
    -MinimumVersion 5.0.0 `
    -Force `
    -SkipPublisherCheck
```

Do not commit real `local.settings.json` or `client.settings.json` files. Start
from the corresponding examples under `src/Installer` and keep deployed values
outside source control.

## Local Build

Run all commands from the repository root.

### 1. Build and Test the Frontend

```powershell
Push-Location .\src\Web
npm ci
npm run check
Pop-Location
```

`npm run check` runs the Vitest suite, TypeScript compilation, and Vite
production build. Vite writes the deployable frontend to:

```text
src/FunctionApp/WebFrontend/wwwroot
```

The package generator requires `index.html`, its referenced assets, and the
current project version embedded in the JavaScript bundle.

### 2. Run the PowerShell Tests

```powershell
Remove-Module AutopilotImport -Force -ErrorAction SilentlyContinue
Invoke-Pester .\src\Tests\AutopilotImport.Tests.ps1 -CI
```

Removing an already loaded runtime module prevents Pester discovery from
finding multiple modules named `AutopilotImport` after source paths change.

### 3. Create the Installation Package

```powershell
$package = .\src\Scripts\New-DeploymentPackage.ps1
$package.FullName
```

By default, the script reads the current Git branch and creates:

```text
InstallationPackage/Intune-autopilotImporter-<branch><version>.zip
```

The archive contains one directory with the same name as the ZIP. An existing
archive for the same branch and version is replaced.

Use an explicit branch or output directory when required:

```powershell
$package = .\src\Scripts\New-DeploymentPackage.ps1 `
    -BranchName 'feature/example' `
    -OutputDirectory 'C:\DeploymentPackages'
```

Characters that are not portable in file names are replaced with hyphens. If
`-BranchName` is omitted, branch detection uses GitHub Actions variables, Azure
Pipelines variables, and finally the current local Git branch.

### 4. Verify the Result

```powershell
Get-FileHash -LiteralPath $package.FullName -Algorithm SHA256

$inspectionPath = Join-Path $env:TEMP $package.BaseName
Remove-Item $inspectionPath -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -LiteralPath $package.FullName -DestinationPath $inspectionPath
Get-ChildItem $inspectionPath -Recurse
Remove-Item $inspectionPath -Recurse -Force
```

## Package Validation

`New-DeploymentPackage.ps1` stops before creating the ZIP when any required
condition is not met:

- `VERSION` does not match `major.minor.yyyyMMdd.counter`.
- A PowerShell file does not contain exactly one matching
  `# Project-Version:` marker.
- The client module manifest version differs from `VERSION`.
- The compiled frontend or one of its referenced assets is missing.
- The compiled JavaScript does not contain exactly the current project version.
- A source entry in the package allowlist is missing.

Update all project version locations with:

```powershell
.\src\Scripts\Update-ProjectVersion.ps1
```

After changing the version, rebuild the frontend before creating the package so
the embedded frontend version matches `VERSION`.

## Repository-to-Package Mapping

The package generator uses an explicit source-to-destination allowlist. The
most important mappings are:

| Repository source | Installation package destination |
| --- | --- |
| `src/FunctionApp/host.json` and Function configuration | Package root |
| `src/FunctionApp/GetAuthorizedTags/` | `GetAuthorizedTags/` |
| `src/FunctionApp/ImportDevice/` | `ImportDevice/` |
| `src/FunctionApp/ManageTagPolicy/` | `ManageTagPolicy/` |
| `src/FunctionApp/ProcessDeviceAttribute/` | `ProcessDeviceAttribute/` |
| `src/FunctionApp/WebFrontend/` | `WebFrontend/` |
| `src/FunctionApp/src/AutopilotImport/` | `src/AutopilotImport/` |
| `src/AutopilotImport.Client/` | `src/AutopilotImport.Client/` |
| `src/Installer/Install-AutopilotImport.ps1` | `Install-AutopilotImport.ps1` |
| `src/Installer/Update-AutopilotImport.ps1` | `Update-AutopilotImport.ps1` |
| `src/Installer/client.settings.json.example` | `client.settings.json.example` |
| `src/Installer/local.settings.json.example` | `local.settings.json.example` |
| `src/Infrastructure/` | `infra/` |
| Selected files from `src/Scripts/` | `scripts/` |
| `src/Web/` source and package files | `web/` |

The ZIP intentionally excludes tests, CI configuration, repository metadata,
package-development scripts, dependencies, generated logs, and real local or
client settings. Change the `$packageEntries` allowlist in
`src/Scripts/New-DeploymentPackage.ps1` when a new runtime file must be shipped.
Do not copy the complete repository into the package.

## CI Build Process

The GitHub Actions workflow in `.github/workflows/deployment-package.yml` runs
on every branch push and can also be started manually. Its Windows x64
self-hosted runner must provide PowerShell, Node.js, npm, and Git. Before each
commit, run `src\Scripts\Update-ProjectVersion.ps1` and update `History.md`.
The workflow validates that both `VERSION` and `History.md` changed in each
pushed first-parent commit. Commits generated by repository automation and
marked with `[skip ci]` are excluded. The workflow:

1. Checks out the repository.
2. Verifies that every pushed commit updates `VERSION` and `History.md`.
3. Installs Pester when required.
4. Runs the Pester suite.
5. Installs frontend dependencies and builds the frontend.
6. Creates the versioned installation ZIP.
7. Uploads the ZIP as a GitHub Actions artifact for 30 days.

Azure Pipelines uses Node.js 22, runs `npm run check`, executes Pester, builds
the same installation package, and publishes it as a pipeline artifact. The
deployment stage runs only for `main`.

## Common Build Failures

### The prebuilt web frontend is missing

Run `npm ci` and `npm run check` in `src/Web`. Confirm that
`src/FunctionApp/WebFrontend/wwwroot/index.html` and its referenced assets were
created.

### The frontend contains another project version

Run the version update first, then rebuild the frontend. Stale hashed assets in
`wwwroot/assets` must not contain an older project version.

### A PowerShell version marker is missing or inconsistent

Every `.ps1`, `.psm1`, and `.psd1` file in the source tree must contain exactly
one `# Project-Version:` marker. Run `Update-ProjectVersion.ps1` after correcting
the missing or duplicate marker.

### The source branch cannot be determined

Run the package command inside a Git checkout or supply `-BranchName`
explicitly.

### Pester reports multiple `AutopilotImport` modules

Remove the loaded module before invoking Pester, or start a fresh PowerShell
session:

```powershell
Remove-Module AutopilotImport -Force -ErrorAction SilentlyContinue
```
