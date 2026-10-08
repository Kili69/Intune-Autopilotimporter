<!-- markdownlint-configure-file { "MD024": { "siblings_only": true } } -->

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This project uses a date-based four-part version scheme instead of Semantic Versioning. The detailed development record is available in [History.md](./History.md).

## [Unreleased]

## [1.3.20261007.4] - 2026-10-07

### Changed

- Replaced the repository-managed self-hosted Linux runner with GitHub-hosted
  `ubuntu-latest` for deployment-package validation and publication.

### Added

- Added `Get-AutoPilotDeviceTagAssignment` and
  `Set-AutoPilotDeviceGroupTag` to list eligible Autopilot devices and submit
  authorized Group Tag changes from PowerShell, including pipeline input,
  `WhatIf`, completion polling, and timeout controls.

### Changed

- Restructured the README and Developer Guide with clearer installation,
  re-tagging, interface, packaging, testing, versioning, deployment, and
  operational guidance plus sanitized workflow screenshots.
- Replaced the previous web asset with the new project logo and refreshed the
  generated Function frontend.
- Expanded the PowerShell script documentation with workflow descriptions,
  complete help, and explanations of non-obvious behavior.

## [1.2.20261006.1] - 2026-10-06

### Added

- Added a responsive Yeti logo to the right side of the web header.

### Changed

- Removed the redundant new-import label, identified Microsoft Intune directly in the device-registration heading, and reduced the whitespace above the import workspace.

## [1.2.20261004.9] - 2026-10-04

### Added

- Added public license metadata and included the license and changelog in deployment packages.
- Added Azure Subscription and Entra Tenant names alongside their IDs in the installer.

### Changed

- Licensed the project under the Apache License 2.0.
- Moved the canonical repository to `Kili69` and updated the project author address.
- Required all changes to `main` to arrive through a pull request from `dev`.
- Preserved deployed application and policy configuration when the installer detects an existing Function App, validates update prerequisites, and switches to update mode.
- Replaced the header subtitle with `Device Hash Import` and added author and Apache 2.0 license information to the footer.

### Fixed

- Reported a missing `Microsoft.Graph.Authentication` prerequisite before entering the nested update flow and retained explicit opt-in installation through `-InstallMissingModules`.
- Fixed MSAL token acquisition on custom domains and InPrivate browser sessions by reusing the interactive login token and falling back from a timed-out hidden iframe to a top-level redirect without weakening the main UI's frame protection.

## [1.2.20261003.1] - 2026-10-03

### Changed

- Documented Group Tag policy management, authorization, validation, and persistence behavior.

## [1.2.20260929.4] - 2026-09-29

### Added

- Added manager-aware import history with requester, status, serial-number, and device-hash filtering.

### Changed

- Clarified least-privilege Azure and Entra deployment requirements.

### Fixed

- Restored automated deployment-package validation and publication.

## [1.1.20260918.4] - 2026-09-18

### Added

- Added management and restricted-management administrative-unit assignment.
- Added attributable import auditing and automatic retention cleanup.

### Changed

- Standardized policy and queue contracts for administrative-unit processing.

## [1.1.20260915.7] - 2026-09-15

### Added

- Added current Entra group-membership resolution through Microsoft Graph.

### Fixed

- Hardened SPA redirect synchronization and installer update behavior.

## [1.1.20260913.16] - 2026-09-13

### Added

- Expanded import history, Group Tag policy management, manager authorization, and deployment diagnostics.

## [1.0.20260902.1] - 2026-09-02

### Changed

- Improved the web frontend and tag-based authorization flow.

## [1.0.20260828.1] - 2026-08-28

### Added

- Added the initial secured Azure Function workflow for Windows Autopilot imports.

[Unreleased]: https://github.com/Kili69/Intune-Autopilotimporter/compare/v1.3.20261007.3...dev
[1.3.20261007.3]: https://github.com/Kili69/Intune-Autopilotimporter/releases/tag/v1.3.20261007.3
[1.2.20261006.1]: https://github.com/Kili69/Intune-Autopilotimporter/compare/v1.2.20261004.9...dev
[1.2.20261004.9]: https://github.com/Kili69/Intune-Autopilotimporter/commits/main/?since=2026-10-04&until=2026-10-05
[1.2.20261003.1]: https://github.com/Kili69/Intune-Autopilotimporter/releases/tag/v1.2.20261003.1
[1.2.20260929.4]: https://github.com/Kili69/Intune-Autopilotimporter/commits/main/?since=2026-09-29&until=2026-09-30
[1.1.20260918.4]: https://github.com/Kili69/Intune-Autopilotimporter/commits/main/?since=2026-09-18&until=2026-09-19
[1.1.20260915.7]: https://github.com/Kili69/Intune-Autopilotimporter/releases/tag/v1.1.20260915.7
[1.1.20260913.16]: https://github.com/Kili69/Intune-Autopilotimporter/releases/tag/v1.1.20260913.16
[1.0.20260902.1]: https://github.com/Kili69/Intune-Autopilotimporter/commits/main/?since=2026-09-02&until=2026-09-03
[1.0.20260828.1]: https://github.com/Kili69/Intune-Autopilotimporter/releases/tag/v1.0.20260828.1
