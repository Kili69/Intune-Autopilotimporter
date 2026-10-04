# Changelog

All notable user-visible changes to Intune Autopilot Import are recorded here.
The detailed development record is available in [History.md](./History.md).

## `1.2.20261004.4` - 2026-10-04

- Licensed the project under the Apache License 2.0.
- Added public license metadata and included the license and changelog in deployment packages.
- Moved the canonical repository to `Kili69` and updated the project author address.
- Required all changes to `main` to arrive through a pull request from `dev`.

## `1.2.20261003.1` - 2026-10-03

- Documented Group Tag policy management, authorization, validation, and persistence behavior.

## `1.2.20260929.4` - 2026-09-29

- Added manager-aware import history with requester, status, serial-number, and device-hash filtering.
- Restored automated deployment-package validation and publication.
- Clarified least-privilege Azure and Entra deployment requirements.

## `1.1.20260918.4` - 2026-09-18

- Added management and restricted-management administrative-unit assignment.
- Added attributable import auditing and automatic retention cleanup.
- Standardized policy and queue contracts for administrative-unit processing.

## `1.1.20260915.7` - 2026-09-15

- Added current Entra group-membership resolution through Microsoft Graph.
- Hardened SPA redirect synchronization and installer update behavior.

## `1.1.20260913.16` - 2026-09-13

- Expanded import history, Group Tag policy management, manager authorization, and deployment diagnostics.

## `1.0.20260902.1` - 2026-09-02

- Improved the web frontend and tag-based authorization flow.

## `1.0.20260828.1` - 2026-08-28

- Added the initial secured Azure Function workflow for Windows Autopilot imports.
