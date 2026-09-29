# Change History

This file describes the development of the project by released or recorded project version. Changes made by multiple commits with the same project version are consolidated into a single section.

## `1.2.20260929.2` - 2026-09-29

- Added manager-aware import history to the web frontend, including requester, status, serial number, and shortened device-hash references, with automatic fallback to the signed-in user's own records.
- Clarified least-privilege installation requirements: subscription-level read access, the required Resource Group deployment and role-assignment permissions, and the applicable Entra directory roles.
- Restored GitHub deployment-package automation on a self-hosted Linux x64 runner, including automatic installation of Pester and the required Azure PowerShell test modules, conditional frontend builds, artifact upload, and publication of the current `main` installation package.
- Advanced and synchronized the 1.2 project version across the Function, installer, scripts, client module, generated frontend, and deployment metadata.

## `1.2.20260922.1` - 2026-09-22

- Promoted the project release line from 1.1 to 1.2 and refreshed the central version metadata so the current package and PowerShell module version are aligned.
- Added the manager-aware import history view to the web UI and exposed the stored device-hash index in the backend history payload for current-user and manager-wide audit visibility.
- Kept the generated deployment package and version markers consistent with the active source release line.

## `1.1.20260921.2` - 2026-09-21

- Added a runtime API version field to the client configuration output so installers and support staff can confirm the Function App version they are actually calling, which helps diagnose mismatches between the deployed REST API and the loaded PowerShell client.
- Kept the serial-number import history filter and documentation aligned with the live client and backend behavior, and refreshed the shipped package metadata so the current module version is visible through `Get-Module`.
- Rebuilt the deployment package after the version bump so the generated installation artifact matches the current PowerShell module manifest and Function App metadata.

## `1.1.20260918.4` - 2026-09-18

- Extended Group Tag policies and queued device processing to assign imported Entra devices to both management and restricted management administrative units, with exact and unique Microsoft Graph validation before policy storage or deployment.
- Standardized the policy, queue, installer, client, and documentation contract on `administrativeUnitName` and `AdministrativeUnitName`, removing the previous restricted-only compatibility schema.
- Added attributable import audit history with the requesting user, timestamps for each processing milestone, owner-scoped default results, targeted Import ID, serial-number, or device-hash lookup, and manager-authorized access to all retained records.
- Added hourly cleanup of import audit records and centralized the 30-day visibility and deletion period as an overridable runtime default.

## `1.1.20260915.7` - 2026-09-15

- Changed Group Tag authorization to resolve current Entra group memberships through Microsoft Graph with the Function managed identity, including token group overage support and the least-privileged `GroupMember.Read.All` and `User.ReadBasic.All` application permissions.
- Added the signed-in user's UPN below their display name in the web frontend.
- Hardened Entra SPA redirect synchronization for fresh installations and updates by handling empty optional redirects, preserving URI arrays, discovering existing Function App Custom Domains under PowerShell strict mode, and reading Azure hostname bindings directly.
- Removed obsolete standalone policy-management script references from the client tools documentation in favor of the PowerShell module commands.
- Enforced one consolidated change-history section per version date in the commit validation workflow and documented the rule for repository automation.

## `1.1.20260914.3` - 2026-09-14

- Added automatic synchronization of Function App custom domains with the Entra SPA redirect URIs during updates while preserving existing redirects.
- Allowed updates without local administrator rights by installing the current client module in the current user's PowerShell module paths when the system-wide module cannot be updated, with a warning to update the system-wide installation later from an elevated session.
- Prevented installation and update failures caused by running `npm ci` when a complete prebuilt web frontend is already included in the deployment package.

## `1.1.20260913.16` - 2026-09-13

- Expanded import history with reliable Function publishing, actionable API errors, module autoloading guidance, a concise default view including `ImportId`, and complete structured records for automation.
- Improved Group Tag policy commands with reusable structured results, `WhatIf` support, noninteractive mutation defaults, comma-separated tag input, rule-specific restricted administrative units, concise removal output, deployed Function version reporting, and dictionary-based first-policy creation.
- Added structured Group Tag manager discovery and management, including automatic Function App resolution across subscriptions and Custom Domains, persistent deployment metadata, URL-bootstrap parameters, and clearer Azure role requirements.
- Hardened updates by validating the structured installer result, separating formatted status output, updating system-wide client modules and configuration, cleaning older versions, and checking elevation early.
- Decoupled prebuilt frontend artifacts from the central package version and limited frontend rebuilds to source changes under `src/Web`.
- Standardized `AutoPilot` command naming and moved mandatory change-history and version validation from GitHub Actions to Azure Pipelines.

## `1.1.20260912.2` - 2026-09-12

- Standardized the project structure, PowerShell source documentation, developer guidance, and persistent user-specific client configuration.
- Added manager-authorized import history without exposing hardware hashes or product keys, plus Azure Resource Manager discovery of Function deployment details during updates.
- Provisioned an explicit Log Analytics workspace for Application Insights and reported previous managed workspaces as potential cleanup candidates after migration.
- Improved Microsoft Graph authorization diagnostics and documented least-privilege installation, interactive and parameterized setup, frontend build requirements, and company-owned Custom Domains.
- Updated packaging so every successful push publishes an artifact, successful `main` pushes additionally store the current ZIP, legacy artifacts are removed, and recursive CI runs are prevented.

## `1.1.20260911.1` - 2026-09-11

- Organized development sources under `src` while preserving package and runtime compatibility with existing installations.
- Extended the Azure deployment with private storage, rebuilt the updated web interface, and normalized generated index line endings for stable cross-platform diffs.
- Added package version validation, corrected the documented package path, synchronized central version declarations, and promoted the validated development state from `dev` to `main`.

## `1.0.20260902.1` - 2026-09-02

- Improved the web frontend experience and authorization flow for tag-based Autopilot imports.

## `1.0.20260901.1` - 2026-09-01

- Extended policy management to handle individual Group Tags.
- Enabled CI to create a traceable deployment package from every commit.
- Improved detection of existing installations and installer error diagnostics.

## `1.0.20260831.1` - 2026-08-31

- Normalized frontend file line endings.
- Added a PowerShell command to display the effective client configuration.
- Enabled Bicep installation on systems without `winget`.
- Made deployment wait for the frontend route to become reachable before reporting success.
- Added deployment support for prebuilt frontend artifacts and included the generated assets in deployment packages.
- Protected installation and runtime flows against a missing web client ID.
- Tightened input validation and policy manager authorization.
- Corrected validation of pre-authorized permission IDs in Entra.
- Merged the web frontend development branch into `dev` and synchronized it with `main` during development.
- Completed frontend routing for custom domains.
- Added an OOBE PowerShell helper and custom-domain guidance.
- Added PowerShell commands for reading and changing Group Tag policies.

## `1.0.20260828.1` - 2026-08-28 to 2026-08-31

- Improved the secure update flow and the German and English web interfaces.
- Added an Entra-protected web interface for Autopilot imports.
- Prepared the version and release information for `1.0.20260828.1`.

## `1.0.20260826.1` - 2026-08-26 to 2026-08-28

- Enforced the intended CI promotion path from `dev` to `main`.
- Simplified the installation guidance.
- Hardened the update process and deployment package generation.
- Expanded configurable deployment values and their documentation.
- Merged the validated development state from pull request 3.
- Improved Azure resource provisioning and its security checks.

## `1.0.20260813.2` - 2026-08-13 to 2026-08-14

- Added restricted device management scopes and an explicit Microsoft Graph sign-in.
- Added a controlled workflow for updating an existing deployment.

## `1.0.20260813.1` - 2026-08-13

- Promoted the validated Entra device tag workflow.
- Added processing that stores imported Autopilot tags on the corresponding Entra devices.

## `1.0.20260812.2` - 2026-08-12

- Promoted the validated development state from `dev` to `main`.
- Controlled branch promotion using repository status.
- Documented the known authorization boundary for Autopilot tags.
- Enforced the intended pull request flow from `dev` to `main` in CI.
- Added a PowerShell command for retrieving the asynchronous status of an existing Autopilot import.
- Added authenticated PowerShell client commands for the protected import service.
- Removed a CI workflow targeting an unavailable hosted runner.

## `1.0.20260812.1` - 2026-08-12

- Made the Azure Function App name configurable.

## `1.0.20260811.2` - 2026-08-12

- Added authorization and management for permitted Autopilot Group Tags.
- Created the initial project structure for Windows Autopilot imports, including Azure Functions, PowerShell modules, infrastructure, and tests.
