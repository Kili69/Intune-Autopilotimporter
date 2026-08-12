# Intune Autopilot Import Function

This Azure Function imports Windows Autopilot hardware hashes from a CSV file. The user authenticates to the Function API with their Entra account. Microsoft Graph is called exclusively through the system-assigned managed identity of the Function.

The client requests a Device Tag. The Function accepts it only when the server-side policy permits that tag for at least one Entra security group in the caller's token.

## Process

1. The client script reads the serial number and hardware hash from an Autopilot CSV supplied as a parameter.
2. `Az.Accounts` requests a user token for the Function API.
3. Azure App Service Authentication, also known as Easy Auth, validates the token.
4. The Function requires the `DeviceHash.Importer` app role and a matching group-to-tag rule.
5. The managed identity submits only the authorized tag to Microsoft Graph v1.0.
6. Intune processes the import asynchronously.

## Prerequisites

- An Azure subscription and an active Intune tenant
- PowerShell 7.2 or later on the importing computer
- An Autopilot CSV containing `Device Serial Number` and `Hardware Hash`
- For deployment: `Az.Accounts`, `Az.Resources`, `Az.Websites`, and the Bicep CLI; `-InstallMissingModules` installs missing components
- For the one-time permission assignment: `Microsoft.Graph.Authentication`
- The appropriate Entra ID licensing for dynamic device groups

## 1. Entra Application for the Function API

By default, the installer searches the selected tenant for an app registration named `Autopilot Import API`. If it does not exist, the installer creates and configures it automatically. During installation, Microsoft Graph requests `Application.ReadWrite.All`, `AppRoleAssignment.ReadWrite.All`, and `Group.Read.All` once. The signed-in administrator must be allowed to manage app registrations and app-role assignments.

These delegated permissions apply only during installation. Function users do not receive them. The managed identity continues to receive only `DeviceManagementServiceConfig.ReadWrite.All`.

The installer configures:

- A single-tenant app registration
- Application ID URI `api://<Application-Client-ID>`
- Delegated scope `DeviceHash.Import`
- Preauthorization for Microsoft Azure PowerShell
- App role `DeviceHash.Importer` and security-group claims
- An enterprise application that requires user or group assignment
- Assignment of the configured Entra groups to the app role

Use `-EntraClientId '<Client-ID>'` to select a specific existing application. Without this parameter, the installer searches by `-EntraApplicationName`, which defaults to `Autopilot Import API`.

The groups supplied to the installer are automatically assigned to the **Import Autopilot devices** role under **Enterprise applications > Autopilot Import API > Users and groups**.

### Manual Alternative

Create a single-tenant app registration in the Entra admin center, for example `Autopilot Import API`.

Under **Expose an API**:

- Application ID URI: `api://<Application-Client-ID>`
- Delegated scope: `DeviceHash.Import`
- Consent: administrators only
- Authorized client application: `1950a258-227b-4e31-a9cf-717495945fc2` (Microsoft Azure PowerShell)
- Select the `DeviceHash.Import` scope for that client

Under **App roles**, create this role:

| Setting | Value |
| --- | --- |
| Display name | Import Autopilot devices |
| Allowed member types | Users/Groups |
| Value | `DeviceHash.Importer` |
| Enabled | Yes |

Then configure the enterprise application:

1. Set **Assignment required?** to **Yes**.
2. Under **Users and groups**, assign the authorized Entra group to `DeviceHash.Importer`.

The app role authorizes access to the Function API. The delegated scope only allows Azure PowerShell to request a token for that API. It does not grant the user Microsoft Graph or Intune permissions.

## 2. Deploy Azure Resources

The installer prompts for all values that were not supplied as parameters, validates the Bicep template, deploys the resources, assigns the Graph permission, publishes the Function code, and verifies that Easy Auth rejects anonymous requests with HTTP 401:

```powershell
pwsh .\Install-AutopilotImport.ps1 -InstallMissingModules
```

After a successful deployment, the installer writes `client.settings.json` containing the Function URL, API Application ID URI, and Tenant ID. The file contains no credentials, but it is environment-specific and therefore excluded from Git. The import script loads these values automatically.

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

New-AzResourceGroup `
    -Name $resourceGroupName `
    -Location $location

$deployment = New-AzResourceGroupDeployment `
    -ResourceGroupName $resourceGroupName `
    -TemplateFile .\infra\main.bicep `
    -functionAppName $functionAppName `
    -entraClientId $entraClientId `
    -tagAuthorizationPolicy $tagPolicy
```

The template enables HTTPS, Easy Auth, Application Insights, and a system-assigned managed identity. Unauthenticated requests are rejected with HTTP 401 before the Function code runs.

## 3. Assign the Graph Permission

This action requires an administrator who can assign app roles. The managed identity receives only `DeviceManagementServiceConfig.ReadWrite.All`.

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
    -Path .\host.json, .\requirements.psd1, .\profile.ps1, .\ImportDevice, .\src `
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

The tests cover role validation, allowed and rejected group-to-tag combinations, installer rule parsing, and invalid hardware hashes.

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
- Allowed tags are changed through the `TAG_AUTHORIZATION_POLICY` Function App setting or a new Bicep deployment.
- Tag authorization is denied when the Entra group claim is missing. This also applies to group overage for users with a very large number of group memberships.
