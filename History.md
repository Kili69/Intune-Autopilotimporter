# Change History

This file describes the development of the project by released or recorded
project version. Changes made by multiple commits with the same project version
are consolidated into a single section.

## `1.1.20260913.3` - 2026-09-13

- Fixed Group Tag policy updates so a restricted management administrative
  unit applies only to the rule that explicitly declares it, rather than being
  used as a global fallback for other rules.

## `1.1.20260913.2` - 2026-09-13

- Added `WhatIf` support to device imports and retained it for all mutating
  client module commands while removing confirmation prompts from normal use.
- Changed `Get-AutopilotTagPolicy` and `Add-AutopilotTagPolicy` to return
  reusable policy-rule objects with group IDs, names, tags, restricted
  management administrative units, and correlation IDs.

## `1.1.20260913.1` - 2026-09-13

- Fixed creation of the first Group Tag policy when Azure Functions supplies
  the JSON request body and nested policy rules as dictionaries.
- Added a CI policy that requires every pushed commit to update both
  `History.md` and `VERSION`.

## `1.1.20260912.2` - 2026-09-12

- Simplified the installation prerequisites and moved frontend build
  requirements to the developer guide.
- Added an Advanced Setup section with least-privilege role guidance and
  interactive and parameterized installer examples.
- Changed the GitHub package workflow so every successful push still publishes
  a workflow artifact and successful `main` pushes additionally commit the
  current ZIP under `InstallationPackage`.
- Removed the legacy `artifacts` directory during automated main-package
  publication and prevented recursive CI runs with a skip marker.

## `1.1.20260912.1` - 2026-09-12

- Standardized the project structure, developer documentation, and PowerShell
  source documentation.
- Changed client configuration to persistent, user-specific settings and gave
  the related commands unambiguous names.
- Configured Application Insights to use an explicitly provisioned Log
  Analytics workspace in the Function App resource group. After an actual
  migration, the updater identifies the previous managed workspace as
  potentially removable.
- Added `Get-AutopilotImportHistory`, allowing managers to retrieve import
  operations currently retained by Intune and their status. The new Function
  endpoint uses the existing manager authorization and does not return hardware
  hashes or product keys.
- Added Function URL discovery to the update script so it can resolve the
  subscription, tenant, resource group, and Function App through Azure Resource
  Manager.
- Improved Microsoft Graph authorization failures with concise remediation in
  the console while preserving complete diagnostics in the installer and update
  logs.
- Added an appendix for publishing the web frontend under a company-owned DNS
  name, including DNS validation, TLS binding, Entra redirect configuration,
  and end-to-end verification.
- Updated the deployment package, documentation, and tests for the new
  functionality.

## `1.1.20260911.1` - 2026-09-11

- Organized development sources in a consistent `src` structure while keeping
  package and runtime paths compatible with existing installations.
- Promoted the validated development state from `dev` to `main`.
- Normalized generated web index line endings for stable cross-platform builds
  and diffs.
- Corrected the documented deployment package example path.
- Added project version validation before package creation.
- Rebuilt the distributed web UI artifacts for version 1.1.
- Updated the central version declarations to `1.1.20260911.1`.

## `1.0.20260911.1` - 2026-09-11

- Extended the Azure deployment with private storage and an updated web
  interface.

## `1.0.20260902.1` - 2026-09-02

- Improved the web frontend experience and authorization flow for tag-based
  Autopilot imports.

## `1.0.20260901.1` - 2026-09-01

- Extended policy management to handle individual Group Tags.
- Enabled CI to create a traceable deployment package from every commit.
- Improved detection of existing installations and installer error diagnostics.

## `1.0.20260831.1` - 2026-08-31

- Normalized frontend file line endings.
- Added a PowerShell command to display the effective client configuration.
- Enabled Bicep installation on systems without `winget`.
- Made deployment wait for the frontend route to become reachable before
  reporting success.
- Added deployment support for prebuilt frontend artifacts and included the
  generated assets in deployment packages.
- Protected installation and runtime flows against a missing web client ID.
- Tightened input validation and policy manager authorization.
- Corrected validation of pre-authorized permission IDs in Entra.
- Merged the web frontend development branch into `dev` and synchronized it
  with `main` during development.
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

- Added restricted device management scopes and an explicit Microsoft Graph
  sign-in.
- Added a controlled workflow for updating an existing deployment.

## `1.0.20260813.1` - 2026-08-13

- Promoted the validated Entra device tag workflow.
- Added processing that stores imported Autopilot tags on the corresponding
  Entra devices.

## `1.0.20260812.2` - 2026-08-12

- Promoted the validated development state from `dev` to `main`.
- Controlled branch promotion using repository status.
- Documented the known authorization boundary for Autopilot tags.
- Enforced the intended pull request flow from `dev` to `main` in CI.
- Added a PowerShell command for retrieving the asynchronous status of an
  existing Autopilot import.
- Added authenticated PowerShell client commands for the protected import
  service.
- Removed a CI workflow targeting an unavailable hosted runner.

## `1.0.20260812.1` - 2026-08-12

- Made the Azure Function App name configurable.

## `1.0.20260811.2` - 2026-08-12

- Added authorization and management for permitted Autopilot Group Tags.
- Created the initial project structure for Windows Autopilot imports,
  including Azure Functions, PowerShell modules, infrastructure, and tests.
