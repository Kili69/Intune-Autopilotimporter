<!-- markdownlint-configure-file { "MD024": { "siblings_only": true } } -->

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This project uses a date-based four-part version scheme instead of Semantic Versioning. The detailed development record is available in [History.md](./History.md).

## [1.4.20261017.6] - 2026-10-17

### Changed

- Show Information or Error in management history summaries, retaining request/completion phase in details. Record policy and manager save/confirmation failures when audit storage is available; errors do not imply rollback.
- Rename management history buttons and popup headings to "Policy changes" ("Policy-Aenderungen" in German).
- Use a required single-line authorized user group with "Change group", no removal or object-ID label suffix. Require successful group resolution before saving; keep device-group multi-selection. Validate search lengths and reject control/invisible formatting characters while supporting Unicode names and punctuation.
- Display localized save-blocking popups listing every missing policy name, authorized user group and Autopilot Group Tag; show other local validation failures in a popup without sending invalid rules.
- Replace global policy history with a History button in each saved rule. Filter changes server-side by persistent rule ID, preserve identity across renames and show a short "Rule updated" confirmation after saving. Keep Policy Manager history separate and permanently retained.
- Require `ruleId` for REST policy-history queries and return only that rule's changed before/after snapshots, including completion events. Preserve IDs through client policy edits and upgrades; support pre-ID snapshots without inventing missing confirmations.
- Introduce a Function-scoped custom identity role containing only `Microsoft.Authorization/roleAssignments/read` for consent-independent eligibility checks, including inherited/group assignments. Require custom role definition write permission during installation/update and surface role-verification failures without enabling access.
- Rebuild the versioned frontend and nextversion installation package and expand API, browser/UI, least-privilege and installer permission regression coverage. The group-picker and required-field changes were verified live on 1.4.20261017.5 without application-setting changes; this release's history-label rename has not been redeployed.
- Audit before configuration mutations, confirm only after completed saves, and report uncertain outcomes explicitly. Use synchronous conditional policy blob writes and route PowerShell manager mutations through the audited backend. Manager history remains restricted to Azure Owner/Contributor.
- Align Entra device-group and Administrative Unit headings with Extension Attributes; remove the empty activity panel from both management tabs.

### Added

- `Get-AutoPilotTagPolicyHistory -RuleId` with pagination and explicit API errors. Include rule IDs and descriptions in normal PowerShell policy output.
- Manual Re-Tagging device reload and persisted multiline policy descriptions, retained by PowerShell edits and deployment updates.
- Permanent policy and Policy Manager change histories with authenticated caller, timestamp and before/after details in paginated popups. No application deletion or import-retention expiry; not WORM-locked against Azure administrators.

### Fixed

- Compare normalized policy content rather than raw JSON when saving rules, avoiding false concurrent-change errors caused by blob-binding formatting. Preserve ETag-conditional writes and reject actual rule or description changes.
- Hide manager administration and its Azure sign-in button for ordinary policy managers. Only server-confirmed Azure Owner/Contributor assignments enable the controls; delegated ARM authorization remains mandatory for manager reads, searches and changes.

## [1.4.20261016.12] - 2026-10-16

### Changed

- Show a localized popup after saving a rule, hide Import History on TagPolicies, use readable rule names in tag selectors, and remove redundant introductory/help paragraphs.
- Automatically reload current rules on entering TagPolicies, retaining unsaved edits unless discard is confirmed and surfacing reload failures.
- Include every runtime function, including Policy Manager administration, in both release and publication allowlists; verify both paths in package regression tests.
- Support Graph's exact-ID 404 when a manager search checks the other object type; do not suppress permission/dependency or name-search failures.
- Explain each recorded import/re-tagging step chronologically, including queueing versus completion, confirmed Group Tags, attribute values, group changes and AU membership. Preserve action details in audit/API/PowerShell history; distinguish skipped writes and existing memberships, and retain honest missing-detail handling for older records.
- Document all PowerShell client functions and their non-obvious implementation details; expand function help and inline documentation for runtime handlers, the shared module, web serving, Bicep infrastructure, installation and updates without changing executable behavior.

### Removed

- Intune Scope Tags in rules, runtime assignment/creation, client history and post-enrollment retries. This workflow only processes pre-enrollment devices. Old policy input retains its effective Group Tag but no Scope Tag action; old pending records use normal audit retention. RBAC read access replaces the write requirement, and managed-device write permission is no longer required. Existing tags and historical role grants are not automatically removed.

### Added

- Separate Policy Managers tab, visible only after server-verified Azure Owner/Contributor access, with current-manager reloads, live user/group name/UPN/ID picking, removal and confirmed saves. Protect the installer, preserve unrelated settings and reject stale edits. Register delegated ARM consent for the SPA without new Function managed-identity permissions; manager-setting saves may restart the Function.
- Named device policies with a web editor (collapsible rules, per-rule saves, confirmed deletion, tag validation, attribute-slot selectors and modal Entra group/AU pickers with selectable named lists), required Group Tags, explicit single-line extension-attribute values (max. 1024 characters, no control characters; no rows means no writes), and policy-owned Entra device-group synchronization. Device-group actions require additional Graph write permission; legacy authorization-only rules retain compatibility.

### Changed

- Show the TagPolicies tab only after server-confirmed manager access; omit it from keyboard navigation for non-managers. Do not classify Graph's `None`/`0` error sentinel as an import failure in the overview or trace; keep actual errors visible.

- Regular updates preserve complete named policy actions; installer policies, management GET responses and PowerShell full-rule submissions use flat JSON arrays, supporting single-rule upgrades from 1.3 and repeated 1.4 updates without losing attribute/group configuration.

- Started the nextversion development cycle at 1.4 without advancing the dev or main release line.
- Added guarded nextversion/dev/main promotion and dev sync PRs, preserving future release lines until explicitly promoted; version tooling now supports minor/major advances without resetting subsequent updates.
- Synchronized the completed dev setup into nextversion while preserving 1.4, and made initial PR-policy activation compatible with strict protection and the existing default-branch workflow.
- Clarified the operational difference between `Get-AutoPilotImportHistory` and `Get-AutoPilotImportStatus` so support and automation can distinguish the retained audit record from the live import workflow state.
- Documented the live workflow fields returned by the status endpoint, including `workflowStatus`, `extensionAttributeStatus`, and the final-state interpretation used by the client.
- Refreshed release metadata and README guidance, and rebuilt the versioned frontend and deployment package; the separately verified live deployment remains on 1.4.20261016.11.

## [1.3.20261008.1] - 2026-10-08

### Changed

- Removed the protected-branch-incompatible package publication push from
  GitHub Actions; generated ZIPs remain available as workflow artifacts and
  versioned GitHub release assets.

## [1.3.20261007.4] - 2026-10-07

### Changed

- Replaced the repository-managed self-hosted Linux runner with GitHub-hosted
  `ubuntu-latest` for deployment-package validation and publication.
- Kept generated deployment packages as workflow artifacts instead of pushing
  ZIP files directly to the protected `main` branch.

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
