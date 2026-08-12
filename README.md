# Intune Autopilot Import Function

This Azure Function imports Windows Autopilot hardware hashes from a CSV file. The user authenticates to the Function API with their Entra account. Microsoft Graph is called exclusively through the system-assigned managed identity of the Function.

The client requests a Device Tag. The Function accepts it only when the server-side policy permits that tag for at least one Entra security group in the caller's token.

## Process

1. The client script reads the serial number and hardware hash from an Autopilot CSV supplied as a parameter.
2. `Az.Accounts` requests a user token for the Function API.
3. Azure App Service Authentication, also known as Easy Auth, validates the token.
4. The Function requires a matching group-to-tag rule for the authenticated caller.
5. The managed identity submits only the authorized tag to Microsoft Graph v1.0.
6. Intune processes the import asynchronously.

## Prerequisites

- An Azure subscription and an active Intune tenant
- PowerShell 7.2 or later on the importing computer
- An Autopilot CSV containing `Device Serial Number` and `Hardware Hash`
- For deployment: `Az.Accounts`, `Az.Resources`, `Az.Storage`, `Az.Websites`, and the Bicep CLI; `-InstallMissingModules` installs missing components
- For the one-time permission assignment: `Microsoft.Graph.Authentication`
- The appropriate Entra ID licensing for dynamic device groups

## Required Roles and Permissions

Azure RBAC roles, Entra directory roles, Microsoft Graph permissions, and the
application role of this Function serve different purposes. They do not grant
one another implicitly.

| Identity | Scope | Required role or permission | Purpose |
| --- | --- | --- | --- |
| Installing administrator | Azure subscription | `Contributor` | Creates the resource group and deploys the Storage Account, Application Insights, Consumption Plan, Function App, system-assigned managed identity, and Easy Auth configuration. |
| Installing administrator | Existing Azure resource group | `Contributor` on that resource group | Sufficient when the resource group already exists. Subscription-level `Contributor` is then not required. |
| Installing administrator | Entra ID | `Application Administrator` or `Cloud Application Administrator` | Creates or updates the app registration and enterprise application. |
| Installing administrator | Microsoft Graph, delegated | `Application.ReadWrite.All`, `User.Read` | Configures the API application and records the installing user as a permanent Group Tag manager. |
| Permission administrator | Entra ID | `Privileged Role Administrator` or `Global Administrator` | Assigns the Microsoft Graph application permission to the Function App managed identity. This privileged step can be performed by a different administrator. |
| Permission administrator | Microsoft Graph, delegated | `Application.Read.All`, `AppRoleAssignment.ReadWrite.All` | Resolves the Microsoft Graph service principal and creates the app-role assignment for the managed identity. Admin consent is required. |
| Function App managed identity | Microsoft Graph, application | `DeviceManagementServiceConfig.ReadWrite.All` | Imports Windows Autopilot device identities. |
| Function App managed identity | Microsoft Graph, application | `DeviceManagementRBAC.Read.All` | Checks current membership of the Intune RBAC role `Intune Role Administrator` for Group Tag management requests. |
| Importing user or group | Function API | Matching group-to-tag rule | Allows importing devices with only the tags assigned to the caller's Entra security group. |
| Group Tag manager | Function API | Installer, configured manager user/group, or `Intune Role Administrator` | Reads and replaces the group-to-tag policy without Azure resource permissions. |
| Manager-list administrator | Azure Function App | `Owner` or `Contributor` at Function or ancestor scope | Adds or removes explicitly configured manager users and groups. The management script rejects other roles. |

The standard installer does not create Azure role assignments. Its Azure
identity therefore needs `Contributor`, but not `Owner` or `User Access
Administrator`. If organizational policy uses a custom Azure role, it must
allow resource-group deployment and Function ZIP publishing for the resource
types defined in `infra/main.bicep`.

Importing users require no Azure subscription role, Entra directory role,
Microsoft Graph permission, or direct Intune administrative role. Authorization
is provided by the configured group-to-tag rule. The Function's managed
identity holds the Intune-related Graph permissions independently of the user.

Do not grant other principals Azure roles that can modify the Function App's
application settings or deployed code. Such permissions can change the manager
policy outside the provided script and therefore bypass its strict
`Owner`/`Contributor` check.

## 1. Entra Application for the Function API

By default, the installer searches the selected tenant for an app registration named `Autopilot Import API`. If it does not exist, the installer creates and configures it automatically. During application setup, Microsoft Graph requests `Application.ReadWrite.All` and `User.Read`. The separate managed-identity permission step requests `Application.Read.All` and `AppRoleAssignment.ReadWrite.All`.

These delegated permissions apply only during installation. Function users do not receive them. The managed identity receives `DeviceManagementServiceConfig.ReadWrite.All` and the read-only `DeviceManagementRBAC.Read.All` permission.

The installer configures:

- A single-tenant app registration
- Application ID URI `api://<Application-Client-ID>`
- Delegated scope `DeviceHash.Import`
- Preauthorization for Microsoft Azure PowerShell
- Security-group claims for endpoint-level authorization
- An enterprise application that allows authenticated tenant users to reach endpoint-level authorization

Use `-EntraClientId '<Client-ID>'` to select a specific existing application. Without this parameter, the installer searches by `-EntraApplicationName`, which defaults to `Autopilot Import API`.

### Manual Alternative

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

## 2. Deploy Azure Resources

The installer prompts for all values that were not supplied as parameters, validates the Bicep template, deploys the resources, assigns the Graph permission, publishes the Function code, and verifies that Easy Auth rejects anonymous requests with HTTP 401:

```powershell
pwsh .\Install-AutopilotImport.ps1 -InstallMissingModules
```

After a successful deployment, the installer writes `client.settings.json` containing the import URL, management URL, API Application ID URI, and Tenant ID. The file contains no credentials, but it is environment-specific and therefore excluded from Git. The client scripts load these values automatically.

The installer prompts for:

- Azure Subscription ID
- Entra Tenant ID
- Azure Resource Group
- Azure region
- Globally unique Function App name
- Entra group object IDs
- Allowed Device Tags for each group

The Client ID is taken automatically from the existing or newly created app registration.

Group-to-tag rules are requested repeatedly in interactive mode. One group can receive multiple tags, and the same tag can be assigned to multiple groups.

For a non-interactive installation, pass all values as parameters:

```powershell
pwsh .\Install-AutopilotImport.ps1 `
    -SubscriptionId '<Subscription-ID>' `
    -TenantId '<Tenant-ID>' `
    -ResourceGroupName 'rg-autopilot-import' `
    -Location 'westeurope' `
    -FunctionAppName '<globally-unique-name>' `
    -TagAuthorizationRule `
        '11111111-1111-1111-1111-111111111111=Autopilot-Standard,Autopilot-Kiosk', `
        '22222222-2222-2222-2222-222222222222=Autopilot-Privileged' `
    -TagManagerPrincipalId `
        '33333333-3333-3333-3333-333333333333' `
    -InstallMissingModules `
    -Confirm:$false
```

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

### Change Group-to-Tag Assignments Later

Use `Set-TagAuthorizationPolicy.ps1` to change an already installed Function.
The installing user, configured manager users or groups, and current members
of the Intune RBAC role `Intune Role Administrator` may use this command. They
do not need Azure resource permissions.

Read the current policy:

```powershell
.\scripts\Set-TagAuthorizationPolicy.ps1 -List
```

The supplied rules are the complete desired configuration: add new rules,
change the tags of existing rules, and omit a previous rule to remove that
group.

Preview the changes first:

```powershell
.\scripts\Set-TagAuthorizationPolicy.ps1 `
    -TagAuthorizationRule `
        '11111111-1111-1111-1111-111111111111=Autopilot-Standard,Autopilot-Kiosk', `
        '33333333-3333-3333-3333-333333333333=Autopilot-Privileged' `
    -WhatIf
```

Run the same command without `-WhatIf` to apply it.

### Change Group Tag Managers Later

Only a principal with an effective Azure `Owner` or `Contributor` assignment
on the Function App, its resource group, or its subscription may add or remove
explicit manager users and groups:

```powershell
.\scripts\Set-TagPolicyManagers.ps1 `
    -SubscriptionId '<Subscription-ID>' `
    -TenantId '<Tenant-ID>' `
    -ResourceGroupName 'rg-autopilot-import' `
    -FunctionAppName '<function-app-name>' `
    -AddPrincipalId '44444444-4444-4444-4444-444444444444' `
    -RemovePrincipalId '33333333-3333-3333-3333-333333333333' `
    -WhatIf
```

The installing user cannot be removed. Authorization for current Intune Role
Administrators also remains enabled.

### Manual Bicep Deployment

The individual commands remain available for troubleshooting or manual installation:

```powershell
Connect-AzAccount

$resourceGroupName = 'rg-autopilot-import'
$location = 'westeurope'
$functionAppName = '<globally-unique-name>'
$entraClientId = '<Application-Client-ID>'
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
    -TemplateFile .\infra\main.bicep `
    -functionAppName $functionAppName `
    -entraClientId $entraClientId `
    -tagAuthorizationPolicy $tagPolicy `
    -managerAuthorizationPolicy $managerPolicy
```

The template enables HTTPS, Easy Auth, Application Insights, and a system-assigned managed identity. Unauthenticated requests are rejected with HTTP 401 before the Function code runs.

## 3. Assign the Graph Permission

This action requires an administrator who can assign app roles. The managed identity receives `DeviceManagementServiceConfig.ReadWrite.All` and `DeviceManagementRBAC.Read.All`.

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser

.\scripts\Grant-ManagedIdentityGraphPermission.ps1 `
    -ManagedIdentityObjectId $deployment.Outputs.managedIdentityObjectId.Value
```

## 4. Publish the Function Code

The ZIP archive must contain `host.json` at its root:

```powershell
$package = Join-Path $PWD 'autopilot-import.zip'
Compress-Archive `
    -Path .\host.json, .\requirements.psd1, .\profile.ps1, .\ImportDevice, .\ManageTagPolicy, .\src `
    -DestinationPath $package `
    -Force

Publish-AzWebApp `
    -ResourceGroupName $resourceGroupName `
    -Name $functionAppName `
    -ArchivePath $package `
    -Force
```

Managed Dependencies can take several minutes to make `Az.Accounts` available after the first start.

## 5. Import Devices

The script does not read local CIM or MDM data. `-CsvPath` is always required and the CSV can contain one or more devices. CSV files are excluded from the repository through `.gitignore`.

Validate the CSV without signing in or calling the API:

```powershell
.\scripts\Import-AutopilotDevice.ps1 `
    -CsvPath '.\kilispaw3.csv' `
    -GroupTag 'PAW' `
    -ValidateOnly
```

Run the actual import:

```powershell
Install-Module Az.Accounts -Scope CurrentUser

.\scripts\Import-AutopilotDevice.ps1 `
    -CsvPath '.\kilispaw3.csv' `
    -GroupTag 'PAW'
```

`-FunctionUrl`, `-ApiApplicationIdUri`, and `-TenantId` remain available as optional overrides for values loaded from `client.settings.json`. Use `-ConfigPath` to select a different configuration file.

A successful request returns HTTP 202 with the import ID, authorized Group Tag, and initial Intune import status. A tag without a matching group rule returns HTTP 403. Intune processes the import asynchronously.

## Dynamic Device Group

For the Group Tag `Autopilot-Standard`, use this dynamic membership rule:

```text
(device.devicePhysicalIds -any (_ -eq "[OrderID]:Autopilot-Standard"))
```

The device becomes a member after Intune creates the Entra device object and synchronizes its physical IDs. A static group assignment during hash import is unreliable because an Entra device object usually does not exist yet.

## Tests

```powershell
Invoke-Pester .\tests\AutopilotImport.Tests.ps1
```

The tests cover Group Tag authorization, manager users and groups, the strict
Owner/Contributor boundary, installer rule parsing, and invalid hardware hashes.

## Versioning

The project version is stored in `VERSION` and follows
`1.0.<yyyyMMdd>.<counter>`, for example `1.0.20260811.1`. Every PowerShell
script, module, and data file contains the same `# Project-Version:` marker.
The canonical author is stored in `AUTHOR`, and the same files contain the
matching `# Author: andreas.lucas@microsoft.com (aka Kili)` marker.

After commits are pushed to `main`, the GitHub workflow increments the counter
by the number of commits in that push and commits the synchronized version
entries. On a new UTC date, the counter starts at `1`. The workflow-generated
version commit does not trigger another increment.

For a local manual increment, run:

```powershell
.\scripts\Update-ProjectVersion.ps1
```

## Operations and Security

- Application Insights logs the correlation ID, import ID, serial number, and object ID of the calling user.
- Hardware hashes and access tokens are not logged.
- Graph error details are not returned to the client.
- Allowed tags are stored in a private Storage blob and changed through the protected management endpoint.
- The explicit manager list remains in `MANAGER_AUTHORIZATION_POLICY` and can be changed only through Azure by an effective Owner or Contributor.
- Tag authorization is denied when the Entra group claim is missing. This also applies to group overage for users with a very large number of group memberships.
