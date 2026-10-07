# Developer Guide

This document contains important information for developers.

It summarizes the development prerequisites, repository and package structure,
the HTTP, queue, module, and configuration interfaces, Entra and Azure
deployment internals, local build and validation workflows, continuous
integration, publishing, versioning, branch promotion, testing,
troubleshooting, and operational security requirements for the Autopilot
Importer project.

## 1. Contents

- [2. Development Prerequisites](#2-development-prerequisites)
- [3. Versioning](#3-versioning)
- [4. Repository Layout](#4-repository-layout)
  - [4.1. Azure Function App](#41-azure-function-app)
  - [4.2. PowerShell Scripts](#42-powershell-scripts)
  - [4.3. Other `src` Directories](#43-other-src-directories)
- [5. Create the Installation Package](#5-create-the-installation-package)
  - [5.1. Generate the Package](#51-generate-the-package)
  - [5.2. Verify the Package](#52-verify-the-package)
- [6. Interfaces](#6-interfaces)
  - [6.1. HTTP Endpoint Overview](#61-http-endpoint-overview)
  - [6.2. Device Import Interface](#62-device-import-interface)
  - [6.3. Authorized Group Tags Interface](#63-authorized-group-tags-interface)
  - [6.4. Device Retagging Interface](#64-device-retagging-interface)
  - [6.5. Import History Interface](#65-import-history-interface)
  - [6.6. Group Tag Policy Management Interface](#66-group-tag-policy-management-interface)
  - [6.7. Web Frontend Interface](#67-web-frontend-interface)
  - [6.8. Asynchronous Processing Interfaces](#68-asynchronous-processing-interfaces)
  - [6.9. PowerShell Client Module Interface](#69-powershell-client-module-interface)
  - [6.10. Shared Function Runtime Module Interface](#610-shared-function-runtime-module-interface)
  - [6.11. Microsoft Graph Interface](#611-microsoft-graph-interface)
  - [6.12. Configuration Interface](#612-configuration-interface)
- [7. Unit Tests](#7-unit-tests)
- [8. Publishing a New Version](#8-publishing-a-new-version)
- [9. Deployment and Installation Internals](#9-deployment-and-installation-internals)
  - [9.1. Entra Application for the Function API](#91-entra-application-for-the-function-api)
  - [9.2. Deploy Azure Resources](#92-deploy-azure-resources)
  - [9.3. Assign the Graph Permission](#93-assign-the-graph-permission)
  - [9.4. Publish the Function Code](#94-publish-the-function-code)
- [10. Local Build](#10-local-build)
  - [10.1. Build and Test the Frontend](#101-build-and-test-the-frontend)
  - [10.2. Run the PowerShell Tests](#102-run-the-powershell-tests)
- [11. Package Validation](#11-package-validation)
- [12. Repository-to-Package Mapping](#12-repository-to-package-mapping)
- [13. CI Build Process](#13-ci-build-process)
- [14. Common Build Failures](#14-common-build-failures)
- [15. Build the Frontend Locally](#15-build-the-frontend-locally)
- [16. Publish the OOBE Helper to PowerShell Gallery](#16-publish-the-oobe-helper-to-powershell-gallery)
- [17. Branch Promotion Policy](#17-branch-promotion-policy)
- [18. Operations and Security](#18-operations-and-security)

## 2. Development Prerequisites

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
    -RequiredVersion 5.7.1 `
    -Force `
    -SkipPublisherCheck
```

Do not commit real `local.settings.json` or `client.settings.json` files. Start
from the corresponding examples under `src/Installer` and keep deployed values
outside source control.

## 3. Versioning

The project uses one canonical version from the root [`VERSION`](VERSION) file.
The same value must be synchronized to the PowerShell module manifests,
PowerShell script metadata, the frontend version metadata, and generated
package names. Do not edit individual version markers manually.

Update all version locations with:

```powershell
.\src\Scripts\Update-ProjectVersion.ps1
```

The version format is `major.minor.yyyymmdd.revision`. The date identifies the
UTC release day and the final component increments when another change is
published on the same day. `History.md` must contain exactly one section for
the current version date. Consolidate same-day changes in that section instead
of creating multiple sections for the same date.

Before a change is committed, verify that the version and history are
consistent:

```powershell
.\src\Scripts\Test-ChangeHistory.ps1 `
    -BaseCommit HEAD^ `
    -HeadCommit HEAD
```

Version changes also affect generated frontend and deployment-package artifacts.
Rebuild those artifacts when their embedded version changes, and do not commit
the locally generated ZIP from `InstallationPackage`.

## 4. Repository Layout

The repository source layout is intentionally different from the installation
package layout. Development files are grouped below `src`, while the generated
ZIP keeps the established root-level layout expected by the installer and
updater.

```text
.
|-- .azure/                     Local Azure deployment planning metadata
|-- .github/                    GitHub workflows and repository automation
|-- .vscode/                    Shared VS Code workspace configuration
|-- docs/                       Documentation assets
|-- InstallationPackage/       Generated local installation ZIP files
|-- src/                        Application source and development files
|   |-- AutopilotImport.Client/ Portable PowerShell client module
|   |-- FunctionApp/            Azure Functions deployment root
|   |-- Infrastructure/         Azure infrastructure as Bicep
|   |-- Installer/              Installer, updater, and config examples
|   |-- Scripts/                Build, administration, and client helpers
|   |-- Tests/                  Pester test suite
|   `-- Web/                    TypeScript/Vite frontend source
|-- .gitattributes              Git text and line-ending rules
|-- .gitignore                  Exclusions for generated and local files
|-- AUTHOR                      Canonical project author
|-- CHANGELOG.md                Public release summary
|-- DEVELOPER.md                Developer documentation
|-- History.md                  Versioned project change history
|-- LICENSE                     Apache License 2.0
|-- README.md                   User and administrator documentation
|-- VERSION                     Canonical project version
`-- azure-pipelines.yml         Azure Pipelines build and deployment definition
```

The `.azure` directory contains local deployment-planning state, and
`InstallationPackage` contains locally generated release archives. Both are
excluded from source control. Local settings, logs, CSV files, frontend
dependencies, test results, and TypeScript build metadata are also excluded by
`.gitignore`.

### 4.1. Azure Function App

The Azure Function App is located in `src/FunctionApp`. This directory is the
Azure Functions deployment root. `host.json`, `profile.ps1`,
`proxies.json`, and `requirements.psd1` must remain at this level because Azure
Functions loads them relative to the Function App root.

| Path | Purpose |
| --- | --- |
| `GetAuthorizedTags/` | Returns the Group Tags authorized for the signed-in user. |
| `GetImportHistory/` | Returns caller-scoped or manager-authorized import audit history. |
| `ImportDevice/` | Validates and submits Autopilot device imports. |
| `ManageDeviceTags/` | Lists eligible Autopilot devices and queues authorized Group Tag changes. |
| `ManageTagPolicy/` | Reads and updates Group Tag authorization policies. |
| `ProcessDeviceAttribute/` | Processes imported devices after registration. |
| `RemoveExpiredImportHistory/` | Removes import audit records after the configured retention period. |
| `WebFrontend/` | Serves the compiled frontend and runtime configuration. |
| `src/AutopilotImport/` | Shared PowerShell runtime module used by the Functions. |

### 4.2. PowerShell Scripts

`src/Scripts` contains the PowerShell scripts used for installation support,
administration, client operations, and repository maintenance. The scripts are
standalone and are invoked directly rather than imported as a module. Each file
carries the project version and author markers and provides comment-based help,
so `Get-Help .\src\Scripts\<script>.ps1 -Full` returns the complete parameter
reference.

| Script | Purpose |
| --- | --- |
| `Ensure-EntraApiApplication.ps1` | Creates or updates the Entra application used by the Autopilot import API. |
| `Ensure-EntraWebApplication.ps1` | Creates or updates the Entra single-page application for the web frontend. |
| `Grant-ManagedIdentityGraphPermission.ps1` | Grants the required Microsoft Graph application permissions to the Function managed identity. |
| `Import-AutopilotDevice.ps1` | Imports Windows Autopilot devices through the secured REST API. |
| `Start-IntuneAutopilotImporter.ps1` | Creates a Windows Autopilot device hash and opens the web importer. This is the standalone PowerShell Gallery script. |
| `Set-TagAuthorizationPolicy.ps1` | Compatibility wrapper for the `AutopilotImport.Client` tag policy commands. |
| `Set-TagPolicyManagers.ps1` | Compatibility wrapper for `Update-AutoPilotTagPolicyManager`. |
| `New-DeploymentPackage.ps1` | Creates the versioned deployment package and validates its contents. |
| `New-SyntheticAutopilotTestCsv.ps1` | Creates synthetic Autopilot CSV files for client and API testing. |
| `Update-ProjectVersion.ps1` | Increments and synchronizes the project version across all version markers. |
| `Test-ChangeHistory.ps1` | Verifies the change history and version in every commit of a range. |

The first seven scripts are copied into the `scripts` directory of the
installation package and are therefore part of the shipped product. Add a new
script to the `$packageEntries` allowlist in `New-DeploymentPackage.ps1` only
when the installer or an administrator needs it on the target computer.

`New-DeploymentPackage.ps1`, `New-SyntheticAutopilotTestCsv.ps1`,
`Update-ProjectVersion.ps1`, and `Test-ChangeHistory.ps1` remain development
tools. They are intentionally excluded from the package and run only from a
repository checkout. `Update-ProjectVersion.ps1` and `Test-ChangeHistory.ps1`
are also used by Azure Pipelines to reject commits without a new version or an
updated `History.md`.

### 4.3. Other `src` Directories

| Path | Purpose |
| --- | --- |
| `src/AutopilotImport.Client/` | Portable PowerShell client module for import and policy operations. |
| `src/Infrastructure/` | Bicep infrastructure definition, including the Function App, Storage, authentication, monitoring, and role assignments. |
| `src/Installer/` | Installer, updater, and example configuration files. The scripts support both repository and extracted-package layouts. |
| `src/Scripts/` | Administrative helpers, client wrappers, package generation, test-data generation, and project versioning. See [PowerShell Scripts](#42-powershell-scripts). |
| `src/Tests/` | Pester tests for modules, Functions, installer behavior, infrastructure contracts, workflows, and package contents. |
| `src/Web/` | TypeScript/Vite frontend source, tests, package lock, and build configuration. |

## 5. Create the Installation Package

Run the package workflow from the repository root after completing the
applicable [local build](#10-local-build) steps. Rebuild the frontend only when
files under `src/Web` changed, run the PowerShell tests, and synchronize
`VERSION`, the PowerShell version markers, and `History.md` before creating a
release package.

### 5.1. Generate the Package

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
`-BranchName` is omitted, branch detection uses CI environment variables and
finally the current local Git branch. The generator performs the checks
described under [Package Validation](#11-package-validation) before writing the
archive.

### 5.2. Verify the Package

Calculate the package checksum, extract the archive to a temporary directory,
and inspect its contents:

```powershell
Get-FileHash -LiteralPath $package.FullName -Algorithm SHA256

$inspectionPath = Join-Path $env:TEMP $package.BaseName
Remove-Item $inspectionPath -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -LiteralPath $package.FullName -DestinationPath $inspectionPath
Get-ChildItem $inspectionPath -Recurse
Remove-Item $inspectionPath -Recurse -Force
```

## 6. Interfaces

This chapter describes the interfaces a developer works against: the HTTP
endpoints of the Function App, the asynchronous storage interfaces, the
portable PowerShell client module, the shared Function runtime module, and the
configuration contracts.

Every HTTP endpoint is declared with `authLevel: anonymous` in `function.json`
because App Service Easy Auth authenticates the caller before the Function
code runs. The Function never trusts client input for authorization. It reads
the `X-MS-CLIENT-PRINCIPAL` header, resolves the caller's Entra group claims,
and evaluates the Group Tag authorization policy on the server. A requested
Group Tag is always replaced by the server-authorized tag. Every response
contains a `correlationId` that also appears in Application Insights, and
Graph error details are never returned to the client.

### 6.1. HTTP Endpoint Overview

| Route | Methods | Function | Purpose |
| --- | --- | --- | --- |
| `api/devices/import` | `GET`, `POST` | `ImportDevice` | Submits a hardware hash and reads the status of a single import. |
| `api/devices/tags` | `GET` | `GetAuthorizedTags` | Returns the Group Tags authorized for the caller. |
| `api/devices/tags/assignments` | `GET`, `POST` | `ManageDeviceTags` | Lists eligible devices and queues authorized Group Tag changes. |
| `api/management/imports` | `GET`, `POST` | `GetImportHistory` | Returns filtered import audit history. |
| `api/management/tag-policy` | `GET`, `PUT` | `ManageTagPolicy` | Reads and replaces the Group Tag authorization policy. |
| `api/ui/{*path}` | `GET` | `WebFrontend` | Serves the compiled frontend and its runtime configuration. |

### 6.2. Device Import Interface

The `ImportDevice` Function accepts a single device per request and returns
immediately after Microsoft Graph has accepted the import. The
extension-attribute, group, and administrative-unit work continues
asynchronously.

| Method | Request | Result |
| --- | --- | --- |
| `POST /api/devices/import` | JSON `{ "serialNumber": "<serial>", "hardwareIdentifier": "<Base64-hash>", "groupTag": "<requested-tag>" }` | `202` with `importId`, `serialNumber`, `groupTag`, `status`, and `correlationId`. |
| `GET /api/devices/import?importId=<GUID>` | Authenticated request | `200` with `importId`, `serialNumber`, `groupTag`, `status`, `workflowStatus`, `deviceErrorCode`, `deviceErrorName`, `extensionAttributeName`, `extensionAttributeStatus`, `extensionAttributeValue`, `entraDeviceId`, and `correlationId`. |

`ConvertTo-AutoPilotImportPayload` validates the required fields, the size
limits, and the Base64 encoding before the Graph request is created. The
`groupTag` in the request body is treated as a request only; the payload sent
to Graph always uses the tag resolved by `Resolve-AuthorizedGroupTag`. An
invalid `importId` returns `400`, and a failed Graph import returns `502` with
the generic error code `graphImportFailed`.

### 6.3. Authorized Group Tags Interface

`GET /api/devices/tags` returns `200` with `{ tags, correlationId }`. The list
contains only the tags that the caller's current Entra group membership
authorizes. Clients use it to populate a selection list; it is not an
authorization decision, because every import and retag request is validated
again on the server.

### 6.4. Device Retagging Interface

The `ManageDeviceTags` Function exposes the retagging contract at
`/api/devices/tags/assignments`. Easy Auth authenticates the caller, and the
Function resolves the caller's current Entra group membership before returning
devices or accepting a new Group Tag. Only Autopilot devices with an
`enrollmentState` of `notContacted` are eligible.

| Method | Request | Result |
| --- | --- | --- |
| `GET /api/devices/tags/assignments` | Authenticated request | `200` with `{ devices, count, correlationId }`; each device contains `id`, `serialNumber`, `groupTag`, `groups`, and `administrativeUnits`. |
| `POST /api/devices/tags/assignments` | JSON `{ "deviceId": "<GUID>", "groupTag": "<authorized-tag>" }` | `202` with `operationId`, `serialNumber`, `groupTag`, `status: "queued"`, and `correlationId`. |
| `GET /api/devices/tags/assignments?operationId=<GUID>` | Authenticated request by the operation owner | `200` with `operationId`, `serialNumber`, `groupTag`, `status`, `workflowStatus`, and `correlationId`. |

The POST operation validates the device state, verifies that the requested tag
is authorized for the caller, records an audit entry, and queues the
device-attribute update. The optional `administrativeUnitName` is resolved
from the authorized tag policy and is applied by the queue-triggered
processing path. The status endpoint is owner-scoped and returns `404` for an
unknown operation or `403` when another user requests it.

### 6.5. Import History Interface

`GetImportHistory` serves `/api/management/imports` and returns `200` with
`{ imports, count, correlationId }`. By default a caller sees only their own
records; `showAll` requests the tenant-wide view and is granted only to an
authorized policy manager.

| Parameter | Transport | Purpose |
| --- | --- | --- |
| `top` | Query | Maximum number of records. The default is `100`. |
| `showAll` | Query or body | Requests records of all users instead of the caller's own records. |
| `importId` | Query (comma-separated) or body `importIds` | Restricts the result to specific imports. |
| `serialNumbers` | Body | Restricts the result to specific serial numbers. |
| `users` | Body | Restricts the result to specific requesting users. |
| `deviceHashSha256` | Body | Restricts the result to specific hashed device hashes. |

Use `POST` when filter lists are too long for a query string. Hardware hashes
are stored only as SHA-256 values, so the history exposes no reusable device
hash.

### 6.6. Group Tag Policy Management Interface

`ManageTagPolicy` serves `/api/management/tag-policy`. It requires a principal
that is authorized by `MANAGER_AUTHORIZATION_POLICY` or, when that policy
enables it, holds the Intune Role Administrator role.

| Method | Request | Result |
| --- | --- | --- |
| `GET /api/management/tag-policy` | Authenticated manager | `200` with `policy`, `functionVersion`, and `correlationId`. |
| `PUT /api/management/tag-policy` | JSON with a `policy` or `rules` array | `200` with the normalized `policy`, `functionVersion`, and `correlationId`. |

`PUT` replaces the complete policy instead of merging individual rules. A rule
is either the string form `<group-object-id>=<tag1>,<tag2>` or an object with
`groupId`, `tags`, and an optional `administrativeUnitName`.
`ConvertTo-TagAuthorizationPolicy` normalizes and validates every rule, and
each referenced administrative unit is resolved through Microsoft Graph before
the policy is persisted. The policy is stored in the private blob
`configuration/tag-authorization-policy.json`.

### 6.7. Web Frontend Interface

`WebFrontend` serves `/api/ui/{*path}` from the compiled bundle under
`src/FunctionApp/WebFrontend/wwwroot`. It returns text assets and binary
assets such as PNG files with their correct MIME type, and it supplies the
runtime configuration that the single-page application needs to sign in and
call the API.

### 6.8. Asynchronous Processing Interfaces

The Functions communicate through Azure Storage. All bindings use the
`AzureWebJobsStorage` connection with the Function's managed identity; shared
key access is not required.

| Interface | Type | Used by |
| --- | --- | --- |
| `device-attribute-updates` | Storage queue | Written by `ImportDevice` and `ManageDeviceTags`, consumed by `ProcessDeviceAttribute`. |
| `configuration/tag-authorization-policy.json` | Blob | Read by `GetAuthorizedTags`, `ImportDevice`, `ManageDeviceTags`, and `ProcessDeviceAttribute`; read and written by `ManageTagPolicy`. |
| Import audit table | Table storage | Written and read through the audit functions of the shared runtime module. |

`ProcessDeviceAttribute` accepts two message shapes on the same queue and
distinguishes them by the identifying property:

```json
{ "importId": "<GUID>", "groupTag": "<tag>", "administrativeUnitName": "<name>", "audit": { } }
```

```json
{ "operationId": "<GUID>", "registeredDeviceId": "<GUID>", "groupTag": "<tag>", "administrativeUnitName": "<name>", "audit": { } }
```

The queue-triggered Function waits for the Entra device object, writes the
extension attribute, assigns the group membership, synchronizes the
administrative unit, and updates the audit record. A new message shape must
remain backward compatible, because queued messages can still arrive after a
deployment.

`RemoveExpiredImportHistory` is a timer-triggered Function with the schedule
`0 17 * * * *`. It runs hourly, uses the schedule monitor, and does not run on
startup. It removes audit records beyond the configured retention period.

### 6.9. PowerShell Client Module Interface

`src/AutopilotImport.Client` is the supported automation interface. It exports
the following commands:

| Area | Commands |
| --- | --- |
| Configuration | `New-AutoPilotImporterClientConfiguration`, `Get-AutoPilotImporterClientConfiguration` |
| Import | `Import-AutoPilotDevice`, `Get-AutoPilotImportStatus`, `Get-AutoPilotImportHistory` |
| Retagging | `Get-AutoPilotDeviceTagAssignment`, `Set-AutoPilotDeviceGroupTag` |
| Tag policy | `Get-AutoPilotTagPolicy`, `Add-AutoPilotTagPolicy`, `Remove-AutoPilotTagPolicy`, `Set-AutoPilotTagPolicy` |
| Policy managers | `Get-AutoPilotTagPolicyManager`, `Update-AutoPilotTagPolicyManager`, `Add-AutoPilotTagPolicyManager`, `Remove-AutoPilotTagPolicyManager` |

```powershell
Get-AutoPilotDeviceTagAssignment

Get-AutoPilotDeviceTagAssignment |
    Where-Object serialNumber -eq 'PC-0001' |
    Set-AutoPilotDeviceGroupTag -GroupTag 'Autopilot-Kiosk' -Wait
```

`Set-AutoPilotDeviceGroupTag` accepts pipeline input or one or more device
GUIDs, supports `-WhatIf`, and can poll with `-Wait`,
`-PollIntervalSeconds`, and `-TimeoutSeconds`. The commands read
`deviceTagAssignmentsUrl`, `functionUrl`, `apiApplicationIdUri`, and
`tenantId` from `client.settings.json` unless explicit parameters override
them. The client acquires an Entra token for the configured API audience and
does not bypass server-side authorization.

### 6.10. Shared Function Runtime Module Interface

`src/FunctionApp/src/AutopilotImport/AutopilotImport.psm1` is the internal
module shared by all Functions. It is not a public API, but every Function
depends on its exported contract, so a signature change affects the complete
Function App.

| Area | Exported functions |
| --- | --- |
| Bindings and payloads | `ConvertFrom-BlobBindingContent`, `ConvertTo-AutoPilotImportPayload` |
| Audit and history | `Get-ImportAuditTableUri`, `Get-ImportAuditAccessToken`, `Set-ImportAuditRecord`, `Get-ImportAuditRecords`, `Get-ImportAuditHistory`, `Get-ImportAuditRetentionCutoffUtc`, `Remove-ExpiredImportAuditRecords`, `Get-DeviceHashSha256` |
| Authorization | `ConvertFrom-ClientPrincipalHeader`, `Test-ClientPrincipalRole`, `Get-CurrentPolicyPrincipal`, `Resolve-AuthorizedGroupTag`, `Get-AuthorizedGroupTags`, `Test-TagPolicyManagerPrincipal`, `Test-IntuneRoleAdministrator`, `Test-TagManagerPolicyAdministratorRole`, `Test-IntuneRoleAdministratorAssignment` |
| Tag policy | `ConvertTo-TagAuthorizationPolicy`, `Compare-TagAuthorizationPolicyGroups` |
| Entra devices | `ConvertTo-EntraDeviceExtensionAttributes`, `Get-AutoPilotDeviceRegistrationId` |
| Administrative units | `Resolve-AdministrativeUnitName`, `Resolve-EffectiveAdministrativeUnitName`, `Resolve-EntraAdministrativeUnit`, `Add-EntraDeviceToAdministrativeUnit`, `Sync-EntraDeviceAdministrativeUnits` |

Add a new function to `Export-ModuleMember` only when a Function or a test
actually consumes it, and cover authorization-relevant changes in
`src/Tests/AutopilotImport.Tests.ps1`.

### 6.11. Microsoft Graph Interface

The Function managed identity requires the Microsoft Graph application
permissions `AdministrativeUnit.ReadWrite.All`,
`DeviceManagementServiceConfig.ReadWrite.All`,
`DeviceManagementRBAC.Read.All`, `Device.ReadWrite.All`,
`GroupMember.Read.All`, and `User.ReadBasic.All`. The installer assigns these
permissions. Clients receive only the delegated `DeviceHash.Import` scope and
therefore cannot call Microsoft Graph on behalf of the Function.

### 6.12. Configuration Interface

`client.settings.json` is the configuration contract between the installer and
every client. It contains no credentials, and explicitly supplied command
parameters take precedence over its values.

| Key | Purpose |
| --- | --- |
| `functionUrl` | Import endpoint used by the client module. |
| `managementUrl` | Group Tag policy management endpoint. |
| `apiApplicationIdUri` | Audience requested when acquiring the Entra token. |
| `tenantId` | Entra tenant used for authentication. |
| `subscriptionId`, `resourceGroupName`, `functionAppName` | Azure resource identification for administrative commands. |
| `webUrl`, `webClientId` | Web frontend address and its SPA application ID. |

Start from `src/Installer/client.settings.json.example` and
`src/Installer/local.settings.json.example`, and keep deployed values outside
source control. Server-side settings such as `MANAGER_AUTHORIZATION_POLICY`
and the configured extension attribute are Function App application settings
and can be changed only through Azure by an effective Owner or Contributor.

## 7. Unit Tests

The repository uses Pester for the PowerShell module, Function, installer,
authorization, infrastructure-contract, workflow, and package tests. The
primary test file is:

```text
src/Tests/AutopilotImport.Tests.ps1
```

Run the complete PowerShell test suite from the repository root:

```powershell
Remove-Module AutopilotImport -Force -ErrorAction SilentlyContinue
Invoke-Pester .\src\Tests\AutopilotImport.Tests.ps1 -CI
```

Removing an already loaded runtime module prevents Pester discovery from
finding multiple modules named `AutopilotImport` after source paths change.
The suite covers Group Tag authorization, manager users and groups, the strict
Owner/Contributor boundary, installer rule parsing, invalid hardware hashes,
retagging workflows, and package contracts.

Frontend changes require the additional Vitest and TypeScript checks provided
by `npm run check` in `src/Web`. Run those checks only when files under
`src/Web` changed; backend, installer, module, and documentation changes reuse
the committed frontend bundle.

## 8. Publishing a New Version

Develop and validate the release on the `dev` branch. A published version
requires a synchronized project version, change history, passing tests, and a
validated installation package.

1. Update the project version and all version markers:

   ```powershell
   .\src\Scripts\Update-ProjectVersion.ps1
   ```

   The version in `VERSION` follows
   `major.minor.yyyyMMdd.counter`. Add the user-visible changes to the single
   matching date section in `History.md`.

2. Run the applicable checks. Use `npm run check` in `src/Web` when frontend
   files changed, and run the PowerShell suite from the [Unit Tests](#7-unit-tests)
   chapter for every release.

3. Create and inspect the installation package:

   ```powershell
   $package = .\src\Scripts\New-DeploymentPackage.ps1
   Get-FileHash -LiteralPath $package.FullName -Algorithm SHA256
   ```

   Follow [Create the Installation Package](#5-create-the-installation-package)
   to inspect the archive contents.

4. Commit the version, history, source, and generated frontend changes
   together. The local ZIP remains a generated artifact and is not committed.
   Push `dev` and open a pull request from `dev` to `main`. Direct pushes to
   `main` are blocked by the repository promotion policy.

5. Wait for Azure Pipelines to validate the version and history, run the
   tests, build the package, and publish the package as a pipeline artifact.
   The deployment stage runs only after the change reaches `main`.

6. After the commit is created, validate its history metadata:

   ```powershell
   .\src\Scripts\Test-ChangeHistory.ps1 `
       -BaseCommit HEAD^ `
       -HeadCommit HEAD
   ```

The standalone OOBE helper can optionally be published to the PowerShell
Gallery after the release has been tested against a non-production Function
App. Validate and publish it as described in
[Publish the OOBE Helper to PowerShell Gallery](#16-publish-the-oobe-helper-to-powershell-gallery).

## 9. Deployment and Installation Internals

### 9.1. Entra Application for the Function API

By default, the installer searches the selected tenant for an app registration named `Autopilot Import API`. If it does not exist, the installer creates and configures it automatically. During application setup, Microsoft Graph requests `Application.ReadWrite.All` and `User.Read`. The separate managed-identity permission step requests `Application.Read.All` and `AppRoleAssignment.ReadWrite.All`.

The installer compares the existing application with the desired configuration before writing. A user with read access can therefore reuse an already compliant application. Application ownership or an application administrator directory
role is required only when the application actually needs to be created or updated.

These delegated permissions apply only during installation. Function users do not receive them. The managed identity receives `DeviceManagementServiceConfig.ReadWrite.All`, `Device.ReadWrite.All`, `AdministrativeUnit.ReadWrite.All`, and the read-only `DeviceManagementRBAC.Read.All`, `GroupMember.Read.All`, and `User.ReadBasic.All` permissions.

The installer configures:

- A single-tenant app registration
- Application ID URI `api://<Application-Client-ID>`
- Delegated scope `DeviceHash.Import`
- Pre-authorization for Microsoft Azure PowerShell
- Security-group claims for endpoint-level authorization
- An enterprise application that allows authenticated tenant users to reach endpoint-level authorization
- A separate single-tenant SPA registration named `Autopilot Import Web`
- Authorization Code Flow with PKCE for the SPA, without a client secret
- SPA preauthorization for the `DeviceHash.Import` scope and the exact deployed frontend redirect URI

Use `-EntraClientId '<Client-ID>'` to select a specific existing application. Without this parameter, the installer searches by `-EntraApplicationName`, which defaults to `Autopilot Import API`.

#### 9.1.1. Manual Alternative

Create a single-tenant app registration in the Entra admin center, for example `Autopilot Import API`.

Under **Expose an API**:

- Application ID URI: `api://<Application-Client-ID>`
- Delegated scope: `DeviceHash.Import`
- Consent: administrators only
- Authorized client application: `1950a258-227b-4e31-a9cf-717495945fc2` (Microsoft Azure PowerShell)
- Select the `DeviceHash.Import` scope for that client

Then configure the enterprise application:

1. Set **Assignment required?** to **No**.
2. Keep tenant access restricted through Easy Auth and the Function's endpoint-level policies.

The delegated scope allows Azure PowerShell to request a token for the API. It does not grant the user Microsoft Graph or Intune permissions.

### 9.2. Deploy Azure Resources

The installer prompts for all values that were not supplied as parameters, validates the Bicep template, deploys the resources, assigns the Graph permission, publishes the Function code, and verifies that Easy Auth rejects anonymous requests with HTTP 401:

```powershell
pwsh .\Install-AutopilotImport.ps1 -InstallMissingModules
```

To sign out a cached Microsoft Graph account and sign in again as the installing administrator without changing the Azure PowerShell account, add `-ForceGraphSignIn`. The installer uses device-code authentication so the operator can open the sign-in page in the appropriate browser profile:

```powershell
pwsh .\Install-AutopilotImport.ps1 `
    -InstallMissingModules `
    -ForceGraphSignIn
```

Assigning Microsoft Graph application permissions requires a signed-in user with Application Administrator, Cloud Application Administrator, or Privileged Role Administrator in the target tenant. After a failed installation, retry
only the idempotent permission assignment with the managed identity object ID reported by the deployment:

```powershell
.\scripts\Grant-ManagedIdentityGraphPermission.ps1 `
    -ManagedIdentityObjectId '<Function-managed-identity-object-ID>' `
    -TenantId '<Tenant-ID>' `
    -ForceGraphSignIn
```

After the Azure resources are deployed, the installer creates a portable client tools package. It asks for the destination and suggests
`Documents\AutopilotImport`. The package contains:

- `Modules\AutopilotImport.Client\<version>\AutopilotImport.Client.psd1`
- `Modules\AutopilotImport.Client\<version>\AutopilotImport.Client.psm1`
- `Modules\AutopilotImport.Client\<version>\AutopilotImport.psm1`
- `Modules\AutopilotImport.Client\<version>\client.settings.json`
- `scripts\Import-AutopilotDevice.ps1`

The settings file contains the import and management URLs, API Application ID URI, Tenant ID, Subscription ID, resource group, and Function App name. It contains no credentials. The module loads these values automatically, while explicitly supplied parameters take precedence. The standalone import script instead reads its public configuration directly from the supplied application URL.

During installation and update, the installer creates `Intune-Autopilotimport-psmodule-<version>.zip` in the current user's Documents directory. An existing archive with the same version is replaced. The ZIP contains the current versioned PowerShell modules and `client.settings.json`, with the folder layout required by PowerShell module autoloading. Transfer the archive to another computer and extract it into the current user's PowerShell module directory:

```powershell
$moduleRoot = Join-Path `
    ([Environment]::GetFolderPath('MyDocuments')) `
    'PowerShell\Modules'
New-Item -Path $moduleRoot -ItemType Directory -Force | Out-Null
Expand-Archive `
    -LiteralPath (Join-Path `
        ([Environment]::GetFolderPath('MyDocuments')) `
        'Intune-Autopilotimport-psmodule-<version>.zip') `
    -DestinationPath $moduleRoot `
    -Force
```

After extraction, commands such as `Import-AutoPilotDevice` are available through PowerShell module autoloading. The user does not need to run `Import-Module` first. PowerShell 7.2 or later and the required Az modules must still be installed on the destination computer.

Each installation writes an activity transcript to the current user's temporary directory. The file name uses the pattern `Intune-Autopilotimport-install-<timestamp>-<unique-id>.log`. The console displays the full path when setup starts. If installation stops with an error, the transcript is closed before the log is extended with the complete PowerShell error record, exception properties, and script stack trace.

Import the newest installed module version from a custom tools directory:

```powershell
$module = Get-ChildItem `
    'C:\Tools\AutopilotImport\Modules\AutopilotImport.Client\*\AutopilotImport.Client.psd1' |
    Sort-Object { [version] $_.Directory.Name } -Descending |
    Select-Object -First 1
Import-Module $module.FullName
```

The module exports `New-AutoPilotImporterClientConfiguration`,
`Get-AutoPilotImporterClientConfiguration`, `Import-AutoPilotDevice`,
`Get-AutoPilotImportStatus`,
`Get-AutoPilotImportHistory`,
`Get-AutoPilotTagPolicy`,
`Add-AutoPilotTagPolicy`, `Remove-AutoPilotTagPolicy`,
`Set-AutoPilotTagPolicy`, `Get-AutoPilotTagPolicyManager`,
`Update-AutoPilotTagPolicyManager`,
`Add-AutoPilotTagPolicyManager`, and `Remove-AutoPilotTagPolicyManager`.

For normal import and policy API use, initialize the module from the deployed
Function URL. This does not require Azure subscription access:

```powershell
Get-AutoPilotImporterClientConfiguration `
    -FunctionUrl 'https://<function-app>.azurewebsites.net'
```

The configuration remains in
`$HOME\.autopilotimporter\client.settings.json` across module updates.

Manager-policy commands automatically search accessible subscriptions in the
configured tenant when Azure deployment values are missing. They match the
configured Function hostname, including a custom DNS name, against the Function
App hostname bindings and persist a unique match in the client profile.

When discovery cannot find a unique Function App, administrators can add the
Azure control-plane values explicitly. `FunctionAppName` is the Azure resource
name, not a custom DNS name:

```powershell
Get-AutoPilotImporterClientConfiguration `
    -FunctionUrl 'https://autopilot.example.com' `
    -SubscriptionId '<Subscription-ID>' `
    -ResourceGroupName 'rg-autopilot-import' `
    -FunctionAppName '<Function-App-Name>'
```

Running the URL bootstrap again preserves discovered or explicitly configured
Azure deployment details unless explicit replacement values are supplied.

To create a separate administrative configuration file instead, use
`New-AutoPilotImporterClientConfiguration`. By default, it creates
`client.settings.json` in the current directory. Use
`-OutputPath 'C:\Configuration'` to select another directory and `-Force` to
replace an existing file. Supply that file with `-ConfigPath` when running a
manager-policy command.

```text
Documents\PowerShell\Modules\AutopilotImport.Client\<version>\client.settings.json
```

The installer prompts for:

- Azure Subscription ID
- Entra Tenant ID
- Azure Resource Group
- Azure region
- Globally unique Function App name, with a generated name proposed by default
- Destination directory for the operational PowerShell scripts
- Entra device extension attribute for the authorized Group Tag; the default is `extensionAttribute1`
- Optional display name of an Entra administrative unit (MAU or RMAU)
- Entra group object IDs
- Allowed Device Tags for each group

Function App names must contain 2-60 letters, digits, or hyphens and must start and end with a letter or digit. The installer rejects an invalid `-FunctionAppName`; in interactive mode it asks again until the name is valid.

The Client ID is taken automatically from the existing or newly created app registration.

Group-to-tag rules are requested repeatedly in interactive mode. One group can receive multiple tags, and the same tag can be assigned to multiple groups.

For a non-interactive installation, pass all values as parameters:

```powershell
pwsh .\Install-AutopilotImport.ps1 `
    -SubscriptionId '<Subscription-ID>' `
    -TenantId '<Tenant-ID>' `
    -ResourceGroupName 'rg-autopilot-import' `
    -ResourceGroupTags @{ Environment = 'Production'; Owner = 'Endpoint Team' } `
    -Location 'westeurope' `
    -FunctionAppName '<globally-unique-name>' `
    -DeviceTagExtensionAttribute 'extensionAttribute1' `
    -TagAuthorizationRule `
        '11111111-1111-1111-1111-111111111111=Autopilot-Standard,Autopilot-Kiosk', `
        '22222222-2222-2222-2222-222222222222=Autopilot-Privileged' `
    -AdministrativeUnitName 'MAU-Autopilot-Devices' `
    -TagManagerPrincipalId `
        '33333333-3333-3333-3333-333333333333' `
    -ClientToolsPath 'C:\Tools\AutopilotImport' `
    -InstallMissingModules `
    -Confirm:$false
```

`-ResourceGroupTags` accepts an optional PowerShell hashtable. Tags are included in the request that creates a new resource group, allowing tag-enforcement policies to succeed. For an existing resource group, the installer merges the requested tags while leaving tags with other names unchanged.

Use `-WhatIf` for a safe preview that displays the configuration and planned action without creating Azure or Entra resources:

```powershell
pwsh .\Install-AutopilotImport.ps1 `
    -SubscriptionId '<Subscription-ID>' `
    -TenantId '<Tenant-ID>' `
    -ResourceGroupName 'rg-autopilot-import' `
    -Location 'westeurope' `
    -FunctionAppName '<globally-unique-name>' `
    -TagAuthorizationRule `
        '11111111-1111-1111-1111-111111111111=Autopilot-Standard' `
    -WhatIf
```

#### 9.2.1. Azure DevOps Pipeline

The repository contains `azure-pipelines.yml`. Pull requests run the Pester tests. A successful run on `main` additionally deploys the Bicep template and Function ZIP through an Azure Resource Manager service connection. The generated `client.settings.json` is published as the pipeline artifact `autopilot-import-client-settings`.

Create an Azure DevOps service connection that uses workload identity federation. Grant its service principal `Contributor` on the target resource group. If the pipeline must create the resource group, grant `Contributor` at subscription scope instead. The pipeline service principal does not require Microsoft Graph permissions.

Create a variable group named `autopilot-import-deployment` with these values:

| Variable | Example | Purpose |
| --- | --- | --- |
| `azureServiceConnection` | `sc-autopilot-import` | Name of the Azure Resource Manager service connection |
| `subscriptionId` | `00000000-0000-0000-0000-000000000000` | Target Azure subscription |
| `tenantId` | `11111111-1111-1111-1111-111111111111` | Entra tenant |
| `resourceGroupName` | `rg-autopilot-import` | Target resource group |
| `location` | `westeurope` | Azure region |
| `functionAppName` | `func-autopilot-contoso` | Globally unique Function App name |
| `entraClientId` | `22222222-2222-2222-2222-222222222222` | Client ID of the preconfigured API app registration |
| `webClientId` | `55555555-5555-5555-5555-555555555555` | Client ID of the preconfigured SPA app registration |
| `installerPrincipalId` | `33333333-3333-3333-3333-333333333333` | Object ID of the user or group that remains a permanent Group Tag manager |
| `tagAuthorizationRulesJson` | `["44444444-4444-4444-4444-444444444444=Standard,Kiosk"]` | JSON array containing the complete group-to-tag policy |
| `tagManagerPrincipalIdsJson` | `[]` | JSON array of additional manager user or group object IDs |

Authorize the pipeline to use this variable group. None of these values is a credential; authentication is provided by workload identity federation.

The Entra API application and the managed identity's Microsoft Graph permissions remain intentionally outside the pipeline because they require privileged tenant permissions that should not be assigned to a deployment service connection.

Before the first pipeline deployment, create or configure the Entra API and SPA applications once from an administrator workstation. Supply their returned client IDs through `entraClientId` and `webClientId`:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
$entraApplication = .\src\Scripts\Ensure-EntraApiApplication.ps1 `
    -TenantId '<Tenant-ID>' `
    -DisplayName 'Autopilot Import API' `
    -Confirm:$false
$webApplication = .\src\Scripts\Ensure-EntraWebApplication.ps1 `
    -TenantId '<Tenant-ID>' `
    -ApiApplicationObjectId $entraApplication.ApplicationObjectId `
    -ApiClientId $entraApplication.ClientId `
    -ApiScopeId $entraApplication.ScopeId `
    -RedirectUri 'https://<function-app-name>.azurewebsites.net/api/ui/index.html' `
    -Confirm:$false
$entraApplication, $webApplication
```

After the first pipeline deployment has created the Function managed identity, a Privileged Role Administrator or Global Administrator runs the idempotent permission script once:

```powershell
Connect-AzAccount -Tenant '<Tenant-ID>' -Subscription '<Subscription-ID>'
$function = Get-AzWebApp `
    -ResourceGroupName 'rg-autopilot-import' `
    -Name '<function-app-name>'

.\src\Scripts\Grant-ManagedIdentityGraphPermission.ps1 `
    -ManagedIdentityObjectId $function.Identity.PrincipalId
```

Subsequent pipeline deployments update infrastructure, policies, and Function code without repeating either privileged Entra operation. Configure approvals and checks on the Azure DevOps environment `autopilot-import` when production deployments require manual authorization.

#### 9.2.2. Update an Existing Deployment

Download or clone the desired release, then run the update script from its project directory. Preview the resolved deployment and planned installer action first:

```powershell
.\Update-AutopilotImport.ps1 -WhatIf
```

Apply the update:

```powershell
.\Update-AutopilotImport.ps1
```

To run the update without the execution confirmation, use `-Force`:

```powershell
.\Update-AutopilotImport.ps1 -Force
```

`-WhatIf` still takes precedence when combined with `-Force` and does not perform the update.

The deployment can also be selected using its Function URL. The script derives
the Function App name and searches the subscriptions accessible to the signed-in
Azure account to resolve the subscription, tenant, and resource group:

```powershell
.\Update-AutopilotImport.ps1 `
    -FunctionUrl 'https://func-autopilot-contoso.azurewebsites.net/api/ui/index.html'
```

The URL may include any Function API path, but must use the Function App's
`azurewebsites.net` hostname. When the same Function App name is visible in
multiple tenants or subscriptions, add `-SubscriptionId` to select the intended
deployment. Explicit `-TenantId`, `-ResourceGroupName`, or `-FunctionAppName`
values must match the resource found from the URL. Azure Reader access is
enough for discovery; the update itself still requires the permissions listed
below.

By default, the script selects the newest installed `client.settings.json` from the portable client package, `PSModulePath`, or the standard per-user and system-wide PowerShell module directories. Select another installed deployment explicitly when required:

```powershell
.\Update-AutopilotImport.ps1 `
    -ConfigPath 'C:\Tools\AutopilotImport\Modules\AutopilotImport.Client\<version>\client.settings.json'
```

After a successful update, the script also installs the current module and
configuration under
`C:\Program Files\WindowsPowerShell\Modules\AutopilotImport.Client\<version>`
and removes older versions when they are not in use. When the update is not
running with local administrator rights, it installs the current module in the
current user's PowerShell 7 and Windows PowerShell module directories instead.
The update continues and warns that the system-wide module remains unchanged
and must be updated later from an elevated PowerShell 7 session.

When the client module and configuration are not installed on the update computer, the script prompts for the subscription ID, tenant ID, resource group, Function App name, and client tools destination. The current Az context and standard deployment names are offered as defaults. These values can also be supplied for an unattended discovery phase:

```powershell
.\Update-AutopilotImport.ps1 `
    -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -TenantId '11111111-1111-1111-1111-111111111111' `
    -ResourceGroupName 'rg-autopilot-import' `
    -FunctionAppName 'func-autopilot-contoso' `
    -ClientToolsPath 'C:\Tools\AutopilotImport' `
    -InstallMissingModules
```

In this mode, and when using `-FunctionUrl`, the API audience is read from the deployed Function App and the management endpoint is derived from its hostname. Use `-ApiAudience` or `-ManagementUrl` only when the deployed values require an explicit override.

The script preserves the existing Function App name, region, API application, Group Tag authorization rules, configured Group Tag managers, client tools path, Device Tag extension attribute, and optional MAU. It then reuses the idempotent
installer to update Azure resources, required permissions, Function code, and the versioned client package.

Each invocation creates a new log file. An update writes its activity to `Intune-Autopilotimport-update-<timestamp>-<unique-id>.log`, and the installer invoked by the update writes its own `Intune-Autopilotimport-install-<timestamp>-<unique-id>.log` in the current user's temporary directory. If either script stops with an error, its transcript is closed before detailed error and stack information is appended to avoid file-lock conflicts.

The updating administrator needs the same Azure and Entra permissions as an installer. Before prompting for confirmation, the update and installation scripts query effective ARM permissions at the target resource group or subscription scope. Deployment requires `Owner`, or `Contributor` together with `Role Based Access Control Administrator` or `User Access Administrator`, because the Bicep template also maintains Storage role assignments. Missing actions produce a concise console error; the complete permission lookup or deployment error remains in the temporary setup log.

Reading and preserving the Function configuration requires `Microsoft.Web/sites/config/list/action`, which is included in Azure `Contributor` and `Owner`. The caller must also be authorized to read the Group Tag policy through the Function management API. Use `-InstallMissingModules` when local prerequisites may be missing. The installer skip switches are also available for separated administrative workflows.

#### 9.2.3. Deployment Package

GitHub Actions and Azure Pipelines build a deployment package for every commit
pushed to any branch. Both workflows run the test suite and publish
`Intune-autopilotImporter-<branch><version>` as a pipeline artifact. GitHub
Actions uses a self-hosted Linux x64 runner and retains its artifact for 30
days. Branch characters that are not portable in file names, such as `/`, are
replaced with `-`. The Azure deployment stage remains restricted to `main`.

The workflows rebuild and test the web frontend only when files under `src/Web`
changed. Other changes reuse the committed frontend bundle. The GitHub workflow
requires a runner registered with the standard `self-hosted`, `Linux`, and
`X64` labels; it does not request a GitHub-hosted runner.

The package contains `README.md`, `CHANGELOG.md`, `History.md`, `LICENSE`, the
installer and updater, Function runtime files, Bicep infrastructure,
operational scripts, source modules, configuration examples, and project
version information. Local or generated configuration such as
`client.settings.json` and `local.settings.json`, tests, logs, repository
metadata, and development helpers such as `New-DeploymentPackage.ps1`,
`New-SyntheticAutopilotTestCsv.ps1`, and `Update-ProjectVersion.ps1` are
excluded.

The installer and updater publish the complete prebuilt web frontend included
in a deployment package without running `npm ci`. Node.js and npm are required
only when publishing from a source tree whose prebuilt frontend bundle is
missing or incomplete.

To build the package locally using the current Git branch, run:

```powershell
.\src\Scripts\New-DeploymentPackage.ps1
```

The local package is written to `InstallationPackage\Intune-autopilotImporter-<branch><version>.zip` by default. Use `-BranchName <branch>` to override local branch detection.

#### 9.2.4. Manual Bicep Deployment

The individual commands remain available for troubleshooting or manual installation:

```powershell
Connect-AzAccount

$resourceGroupName = 'rg-autopilot-import'
$location = 'westeurope'
$functionAppName = '<globally-unique-name>'
$entraClientId = '<Application-Client-ID>'
$webClientId = '<Web-Application-Client-ID>'
$tagPolicy = @(
    @{
        groupId = '11111111-1111-1111-1111-111111111111'
        tags = @('Autopilot-Standard')
    }
) | ConvertTo-Json -Depth 4 -Compress
$managerPolicy = @{
    installerPrincipalId = '<installing-user-object-id>'
    additionalPrincipalIds = @()
    allowIntuneRoleAdministrators = $true
} | ConvertTo-Json -Depth 4 -Compress

New-AzResourceGroup `
    -Name $resourceGroupName `
    -Location $location

$deployment = New-AzResourceGroupDeployment `
    -ResourceGroupName $resourceGroupName `
    -TemplateFile .\src\Infrastructure\main.bicep `
    -functionAppName $functionAppName `
    -entraClientId $entraClientId `
    -webClientId $webClientId `
    -tagAuthorizationPolicy $tagPolicy `
    -managerAuthorizationPolicy $managerPolicy
```

The template enables HTTPS, Easy Auth, Application Insights, and a
system-assigned managed identity. A Log Analytics workspace named
`<function-app-name>-la` is created in the same resource group and linked
explicitly to Application Insights, preventing Azure from creating a separate
`ai_*_managed` resource group. The workspace retains telemetry for 30 days.
When an existing deployment is updated, new telemetry is written to this
workspace; historical telemetry remains in the previously linked managed
workspace until that workspace is removed.

Unauthenticated API requests are rejected with HTTP 401 before the Function
code runs. Only `/` and `/api/ui/*` are excluded: the root returns an HTTP
redirect to the frontend, while the static sign-in page and its public runtime
configuration can load without authentication. No import or policy data is
exposed through these paths.

### 9.3. Assign the Graph Permission

This action requires an administrator who can assign app roles. The managed identity receives `DeviceManagementServiceConfig.ReadWrite.All`, `DeviceManagementRBAC.Read.All`, `GroupMember.Read.All`, `User.ReadBasic.All`, `Device.ReadWrite.All`, and `AdministrativeUnit.ReadWrite.All`.

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser

.\src\Scripts\Grant-ManagedIdentityGraphPermission.ps1 `
    -ManagedIdentityObjectId $deployment.Outputs.managedIdentityObjectId.Value
```

### 9.4. Publish the Function Code

The ZIP archive must contain `host.json` at its root:

Rebuild the web frontend first only when files under `src/Web` changed. For
documentation, PowerShell module, installer, or backend Function changes, use
the existing bundle under `src/FunctionApp/WebFrontend/wwwroot`.

```powershell
Push-Location .\src\Web
npm ci
npm run build
Pop-Location

$package = Join-Path $PWD 'autopilot-import.zip'
Push-Location .\src\FunctionApp
Compress-Archive `
    -Path .\host.json, .\proxies.json, .\requirements.psd1, .\profile.ps1, .\ImportDevice, .\GetAuthorizedTags, .\ManageTagPolicy, .\ProcessDeviceAttribute, .\WebFrontend, .\src `
    -DestinationPath $package `
    -Force
Pop-Location

Publish-AzWebApp `
    -ResourceGroupName $resourceGroupName `
    -Name $functionAppName `
    -ArchivePath $package `
    -Force
```

Managed Dependencies can take several minutes to make `Az.Accounts` available after the first start.

## 10. Local Build

Run all commands from the repository root.

### 10.1. Build and Test the Frontend

Run this step only when files under `src/Web` change. Documentation,
PowerShell module, installer, and backend Function changes reuse the committed
frontend bundle.

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

The package generator requires `index.html` and all assets referenced by it.
The version shown by the web frontend is updated only when the frontend is
rebuilt.

### 10.2. Run the PowerShell Tests

```powershell
Remove-Module AutopilotImport -Force -ErrorAction SilentlyContinue
Invoke-Pester .\src\Tests\AutopilotImport.Tests.ps1 -CI
```

Removing an already loaded runtime module prevents Pester discovery from
finding multiple modules named `AutopilotImport` after source paths change.

## 11. Package Validation

`New-DeploymentPackage.ps1` stops before creating the ZIP when any required
condition is not met:

- `VERSION` does not match `major.minor.yyyyMMdd.counter`.
- A PowerShell file does not contain exactly one matching
  `# Project-Version:` marker.
- The client module manifest version differs from `VERSION`.
- The compiled frontend or one of its referenced assets is missing.
- A source entry in the package allowlist is missing.

Update all project version locations with:

```powershell
.\src\Scripts\Update-ProjectVersion.ps1
```

Changing only project metadata, documentation, PowerShell modules, installers,
or backend Function code does not require rebuilding the frontend. Rebuild it
after changing files under `src/Web`.

## 12. Repository-to-Package Mapping

The package generator uses an explicit source-to-destination allowlist. The
most important mappings are:

| Repository source | Installation package destination |
| --- | --- |
| `LICENSE`, `CHANGELOG.md`, `History.md`, and `README.md` | Package root |
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

## 13. CI Build Process

Azure Pipelines is the repository's only automated build system. No GitHub
Actions workflows are defined, so repository activity does not request GitHub
hosted or self-hosted runners. Before each commit, run
`src\Scripts\Update-ProjectVersion.ps1` and update `History.md`.

Azure Pipelines:

1. Checks out the complete Git history.
2. Verifies that the source commit updates `VERSION` and `History.md`.
3. Uses Node.js 22 and runs `npm run check` only when `src/Web` changed.
4. Runs the Pester suite.
5. Creates the versioned installation ZIP.
6. Publishes the ZIP as a pipeline artifact.

The deployment stage runs only for `main`.

## 14. Common Build Failures

### 14.1. The prebuilt web frontend is missing

Run `npm ci` and `npm run check` in `src/Web`. Confirm that
`src/FunctionApp/WebFrontend/wwwroot/index.html` and its referenced assets were
created.

### 14.2. A PowerShell version marker is missing or inconsistent

Every `.ps1`, `.psm1`, and `.psd1` file in the source tree must contain exactly
one `# Project-Version:` marker. Run `Update-ProjectVersion.ps1` after correcting
the missing or duplicate marker.

### 14.3. The source branch cannot be determined

Run the package command inside a Git checkout or supply `-BranchName`
explicitly.

### 14.4. Pester reports multiple `AutopilotImport` modules

Remove the loaded module before invoking Pester, or start a fresh PowerShell
session:

```powershell
Remove-Module AutopilotImport -Force -ErrorAction SilentlyContinue
```

## 15. Build the Frontend Locally

The frontend source is located under `src/Web`, while the Azure Function that
serves it is located under `src/FunctionApp/WebFrontend`. Build and test it only
after changing files under `src/Web`:

```powershell
Set-Location .\src\Web
npm ci
npm run check
```

`npm run check` executes the frontend unit tests and creates the production
bundle under `src\FunctionApp\WebFrontend\wwwroot`. The generated
`src\Web\node_modules`, `src\Web\tsconfig.tsbuildinfo`, and
`src\FunctionApp\WebFrontend\wwwroot` paths are intentionally ignored by Git
and are recreated during a frontend build. The version displayed by the web
frontend remains unchanged for documentation, PowerShell module, installer,
and backend Function-only releases.

## 16. Publish the OOBE Helper to PowerShell Gallery

The standalone gallery script is
`src\Scripts\Start-IntuneAutopilotImporter.ps1`. Its `PSScriptInfo` version is
updated together with the project version by
`src\Scripts\Update-ProjectVersion.ps1`. Validate its metadata before publishing:

```powershell
Test-ScriptFileInfo `
    -Path .\src\Scripts\Start-IntuneAutopilotImporter.ps1
```

Test the complete workflow against a non-production Function App before
publishing. Then publish it with a PowerShell Gallery API key entered directly
in the interactive PowerShell session; do not store the key in source control:

```powershell
Publish-Script `
    -Path .\src\Scripts\Start-IntuneAutopilotImporter.ps1 `
    -Repository PSGallery `
    -NuGetApiKey (Read-Host 'PowerShell Gallery API key')
```

## 17. Branch Promotion Policy

All changes to `main` must be promoted through a pull request from the `dev`
branch in this repository. Direct pushes, force pushes, branch deletion, and
pull requests from other branches or forks are blocked.

The `Enforce dev promotion` workflow validates the pull-request source. The
`main` branch ruleset requires this check and requires a pull request before any
update can be merged. Develop and validate changes on `dev`, then open a pull
request from `dev` to `main`.

## 18. Operations and Security

- Application Insights logs the correlation ID, import ID, serial number, and object ID of the calling user.
- Hardware hashes and access tokens are not logged.
- Graph error details are not returned to the client.
- Allowed tags are stored in a private Storage blob and changed through the protected management endpoint. Shared-key access is not required; the installer and Function use their Entra identities.
- The explicit manager list remains in `MANAGER_AUTHORIZATION_POLICY` and can be changed only through Azure by an effective Owner or Contributor.
- Tag authorization is denied when the Entra group claim is missing. This also applies to group overage for users with a very large number of group memberships.
