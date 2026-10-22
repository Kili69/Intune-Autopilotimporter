# How To: Migrate an Existing Installation to Private Endpoints

Versions before 1.4 run on Windows Consumption (Y1) with a publicly reachable
Storage account. Version 1.4 runs on Linux Flex Consumption (FC1) and reaches
Storage only through private endpoints. This guide describes how an existing
installation is converted with
[`Migrate-AutopilotImportToPrivate.ps1`](src/Scripts/Migrate-AutopilotImportToPrivate.ps1)
and what you have to do.

Technical details are in the
[Developer Guide](DEVELOPER.md#legacy-consumption-to-private-flex-migration).

## What Happens

- The Function App keeps its name; the Windows app and its Y1 plan are deleted
  and recreated as Linux Flex Consumption.
- The existing Storage account stays. Policies, queues and import history
  (`importaudit` table) are kept.
- Public Storage access is disabled; Blob, Queue and Table get private
  endpoints and private DNS zones in a new VNet.
- The API/SPA app registrations, policy and settings are preserved. The new
  Function App has a new managed identity; its roles and Graph permissions are
  granted again.
- **Downtime:** from deletion of the old app until the new app passes its
  smoke test. Plan a maintenance window.
- A metadata backup (IDs and policy, no secrets) is written to your
  `AutopilotImport` documents folder first. Keep it until the migration is done.

## Prerequisites

- PowerShell 7 and Azure CLI, signed in with `az login`.
- Azure **Owner** (or Contributor plus role-assignment rights) on the
  resource group and subscription. Activate PIM roles beforehand; they must
  not expire during the run.
- An Entra admin able to grant Graph application roles (Application or Cloud
  Application Administrator). For administrative-unit scoped device-attribute
  roles, Privileged Role Administrator.
- A free private IPv4 `/24` (for example `192.168.0.0/24`) that does not
  overlap any VNet in the subscription, or any network you will peer with.
- A complete repository checkout of the target version. Run the commands below
  from its root directory. The deployment ZIP alone does not include the
  migration script or the repository layout it requires.

## Steps

1. **Preview** (nothing is changed):

   ```powershell
   pwsh .\src\Scripts\Migrate-AutopilotImportToPrivate.ps1 `
       -SubscriptionId '<subscription-guid>' `
       -TenantId '<tenant-guid>' `
       -ResourceGroupName 'rg-autopilot-import' `
       -FunctionAppName 'func-autopilot-contoso' `
       -VirtualNetworkAddressPrefix '192.168.0.0/24' `
       -AcceptCustomDomainCertificateReissue `
       -WhatIf
   ```

2. **Run** the same command without `-WhatIf`.

3. **If it fails after the old app was deleted**, fix the cause (usually an
   expired PIM role or Graph sign-in) and run the command again with
   `-BackupPath '<path to the migration-*.json backup>'`. If the new Flex app
   and plan already exist, they are reused, not deleted.

4. **Graph sign-in in a terminal without a browser window** (for example the
   VS Code terminal where WAM fails):
   - add `-ForceGraphSignIn` for device-code sign-in, or
   - pass a short-lived Graph token as `SecureString` with
     `-GraphAccessToken` (needs `Application.Read.All` and
     `AppRoleAssignment.ReadWrite.All`). It stays in memory and is never
     stored. Do not combine it with `-ForceGraphSignIn`.

5. **Administrative-unit role** (only if you use AU-scoped retagging): assign
   the custom device-attribute role to the new identity with
   `src\Scripts\Grant-ManagedIdentityAdministrativeUnitRole.ps1`
   (`-ForceGraphSignIn` if needed).

6. **Custom domain** (if used): the binding and certificate are not migrated.
   In the Azure Portal add the hostname to the new app and create/bind a
   site-scoped certificate. Keep the DNS CNAME on
   `<app-name>.azurewebsites.net`. Until then use the default hostname.

7. **Verify**: open the UI, sign in, check rules and history, and run a test
   import or retag. Later updates with `Update-AutopilotImport.ps1` keep the
   Flex setup and VNet range automatically.

## Notes

- Private endpoints and DNS zones cause additional Azure charges.
- Do not delete the Storage account or the backup file during migration.
- The migration is staged, not transactional; use the resume step above after
  any interruption.
