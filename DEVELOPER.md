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
| `ManageDeviceTags/` | Lists eligible Autopilot devices and queues authorized Group Tag changes. |
| `ManageTagPolicy/` | Reads and updates Group Tag authorization policies. |
| `ProcessDeviceAttribute/` | Processes imported devices after registration. |
| `WebFrontend/` | Serves the compiled frontend and runtime configuration. |
| `src/FunctionApp/src/AutopilotImport/` | Shared PowerShell runtime module used by the Functions. |

### Device Retagging Interfaces

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

The Function managed identity requires the Microsoft Graph application
permissions `AdministrativeUnit.ReadWrite.All`,
`DeviceManagementServiceConfig.ReadWrite.All`,
`DeviceManagementRBAC.Read.All`, `Device.ReadWrite.All`,
`GroupMember.Read.All`, and `User.ReadBasic.All`. The installer assigns these
permissions; clients receive only the delegated `DeviceHash.Import` scope and
cannot call Microsoft Graph on behalf of the Function.

The portable client module wraps these interfaces:

```powershell
Get-AutoPilotDeviceTagAssignment

Get-AutoPilotDeviceTagAssignment |
    Where-Object serialNumber -eq 'PC-0001' |
    Set-AutoPilotDeviceGroupTag -GroupTag 'Autopilot-Kiosk' -Wait
```

`Set-AutoPilotDeviceGroupTag` accepts pipeline input or one or more device
GUIDs, supports `-WhatIf`, and can poll with `-Wait`,
`-PollIntervalSeconds`, and `-TimeoutSeconds`. Both commands read
`deviceTagAssignmentsUrl`, `functionUrl`, `apiApplicationIdUri`, and
`tenantId` from `client.settings.json` unless explicit parameters override
them. The client acquires an Entra token for the configured API audience and
does not bypass server-side authorization.

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
    -RequiredVersion 5.7.1 `
    -Force `
    -SkipPublisherCheck
```

Do not commit real `local.settings.json` or `client.settings.json` files. Start
from the corresponding examples under `src/Installer` and keep deployed values
outside source control.

## Deployment and Installation Internals

### 1. Entra Application for the Function API

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

#### Manual Alternative

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

### 2. Deploy Azure Resources

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

#### Azure DevOps Pipeline

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

#### Update an Existing Deployment

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

#### Deployment Package

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

#### Manual Bicep Deployment

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

### 3. Assign the Graph Permission

This action requires an administrator who can assign app roles. The managed identity receives `DeviceManagementServiceConfig.ReadWrite.All`, `DeviceManagementRBAC.Read.All`, `GroupMember.Read.All`, `User.ReadBasic.All`, `Device.ReadWrite.All`, and `AdministrativeUnit.ReadWrite.All`.

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser

.\src\Scripts\Grant-ManagedIdentityGraphPermission.ps1 `
    -ManagedIdentityObjectId $deployment.Outputs.managedIdentityObjectId.Value
```

### 4. Publish the Function Code

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

## Local Build

Run all commands from the repository root.

### 1. Build and Test the Frontend

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
`-BranchName` is omitted, branch detection uses CI environment variables and
finally the current local Git branch.

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
- A source entry in the package allowlist is missing.

Update all project version locations with:

```powershell
.\src\Scripts\Update-ProjectVersion.ps1
```

Changing only project metadata, documentation, PowerShell modules, installers,
or backend Function code does not require rebuilding the frontend. Rebuild it
after changing files under `src/Web`.

## Repository-to-Package Mapping

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

## CI Build Process

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

## Common Build Failures

### The prebuilt web frontend is missing

Run `npm ci` and `npm run check` in `src/Web`. Confirm that
`src/FunctionApp/WebFrontend/wwwroot/index.html` and its referenced assets were
created.

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

## Build the Frontend Locally

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

## Publish the OOBE Helper to PowerShell Gallery

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

## Branch Promotion Policy

All changes to `main` must be promoted through a pull request from the `dev`
branch in this repository. Direct pushes, force pushes, branch deletion, and
pull requests from other branches or forks are blocked.

The `Enforce dev promotion` workflow validates the pull-request source. The
`main` branch ruleset requires this check and requires a pull request before any
update can be merged. Develop and validate changes on `dev`, then open a pull
request from `dev` to `main`.

## Tests

```powershell
Invoke-Pester .\src\Tests\AutopilotImport.Tests.ps1
```

The tests cover Group Tag authorization, manager users and groups, the strict Owner/Contributor boundary, installer rule parsing, and invalid hardware hashes.

## Versioning

The project version is stored in `VERSION` and follows `1.2.<yyyyMMdd>.<counter>`, for example `1.2.20260922.1`. Every PowerShell script, module, and data file contains the same `# Project-Version:` marker.
The canonical author is stored in `AUTHOR`, and the same files contain the matching `# Author: andreas.lucas@outlook.com (aka Kili)` marker.

Every commit must include an updated `History.md` and a new project version.
Azure Pipelines rejects source commits that omit either change. Before creating
a commit, run:

```powershell
.\src\Scripts\Update-ProjectVersion.ps1
```

The counter increases for commits created on the same UTC date and starts at
`1` on a new UTC date. Repository automation commits marked with `[skip ci]`
are excluded from this rule.

## Operations and Security

- Application Insights logs the correlation ID, import ID, serial number, and object ID of the calling user.
- Hardware hashes and access tokens are not logged.
- Graph error details are not returned to the client.
- Allowed tags are stored in a private Storage blob and changed through the protected management endpoint. Shared-key access is not required; the installer and Function use their Entra identities.
- The explicit manager list remains in `MANAGER_AUTHORIZATION_POLICY` and can be changed only through Azure by an effective Owner or Contributor.
- Tag authorization is denied when the Entra group claim is missing. This also applies to group overage for users with a very large number of group memberships.
