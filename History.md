# Change History

This file describes the development of the project by released or recorded project version. Changes made by multiple commits with the same project version are consolidated into a single section.

## `1.4.20261019.2` - 2026-10-19

- Fix silent re-tagging failures for devices in restricted management administrative units: the queue worker now stops on Graph HTTP errors, audits the failed step, Graph error, status code and attempt with a remediation hint, and no longer records attribute, group or completion success after a failure. Import history, tag-change and import status (`workflowStatus: error`), the web trace/timeline and `Get-AutoPilotImportHistory` expose the failure until a later retry completes.
- Let the installer and updater assign the Function managed identity a Cloud Device Administrator role scoped to every restricted administrative unit used by rules (plus `-RestrictedAdministrativeUnitName`, skippable with `-SkipAdministrativeUnitRole`) through the packaged `Grant-ManagedIdentityAdministrativeUnitRole.ps1`; failures only warn with the manual command. Document the RMAU role requirement and managed identity token delay.
- Document PowerShell backup/export and import/restore in a dedicated README chapter with protected JSON files, pre-restore snapshots, replacement semantics, confirmation and verification. Keep direct REST usage, authentication headers, JSON payloads, concurrency and HTTP error handling in the Developer Guide.
- Record the successful same-installation live export/restore test on 2026-10-18: rules and manager configuration matched exactly after restore, and the focused client/API regression tests passed. Rebuild versioned frontend and local installation artifacts.

## `1.4.20261018.6` - 2026-10-18

- Replace the protected nextversion release-line model with arbitrary pushable development/fix branches promoted through tested PRs to dev and then main. Retain dev/main PR-only, merge-commit, no-force-push/no-deletion protections; require current dev ancestry and nondecreasing versions while allowing any development branch to prepare a new minor/major.
- Run complete PowerShell tests, frontend tests/type-check/build and installation packaging on branch pushes and dev/main PR merge previews. Publish every successfully validated main push as a version-tagged GitHub Release with a downloadable installation ZIP; reject version tags belonging to another commit and retain other branch packages as Actions artifacts only.
- Replace nextversion-only sync with GitHub repository automation that opens isolated dev-fix PRs for all ordinary branches. Never execute target-branch code, write their refs, auto-merge or overwrite manual conflict resolutions. Reuse PRs on rerun, normalize real HTTP empty-array responses, exclude protected/generated branches, support pagination and report API failures; resolve version/content conflicts deliberately on sync branches.
- Rebuild versioned frontend and installation artifacts, expand branch/sync/release regression tests, and document release downloads and staged protection rollout.

- Move the default Flex VNet to `172.16.0.0/24`, with Function integration on `172.16.0.0/26` and private endpoints on `172.16.0.64/27`, all within the private `172.16.0.0/12` range. Retain subnet sizes and hosting-specific behavior; document overlap checks and the need to plan migration of existing occupied Flex subnets.
- Add an Azure Overview as developer-guide chapter 1, explaining Entra applications, service principals, delegated versus application permissions, managed identity and Azure RBAC, with a Mermaid diagram of Function dependencies. Leave Contents unnumbered and update subsequent chapter numbers and internal links.
- Add network-prefix regression coverage and rebuild the versioned frontend and local nextversion installation package for testing.
- Add versioned JSON backup and restore for all rules and policy managers through `GET`/`PUT /api/management/policy-managers?backup=true`, `Export-AutoPilotConfiguration`, and `Restore-AutoPilotConfiguration`. Require API and caller-delegated ARM authentication with effective Azure Owner/Contributor rights. Support another installation in the same tenant while preserving its protected installer; replace rules/additional managers and restore the Intune-role-administrator flag, including empty policies.
- Validate schemas, rules, directory references and target concurrency before changes; conditionally save rules before replacing manager settings, preserve unrelated settings and audit both mutations. Report partial or unconfirmed restores explicitly without automatic rollback; manager writes can restart the Function. Export standalone UTF-8 JSON without tokens or unrelated settings, protect existing files unless `-Force` is supplied, and support confirmed restore and network-free `-WhatIf`. Document the REST/PowerShell contracts and expand regression coverage.
- Consolidate the configuration-backup development into nextversion. Preserve the pre-staged 1.3 commits through a history-only merge without reactivating their obsolete alternative retagging endpoint, status storage or version metadata; retain the current implementation and rebuild versioned artifacts.
- Fix updater URL discovery under strict mode with zero or one accessible subscription. Accept bound custom HTTPS domains through exact Azure Function hostname metadata/binding lookup, retain native Azure URL discovery, page subscription inventories, reject ambiguous targets and report inaccessible subscriptions/bindings. Add regression tests and updated invocation guidance; rebuild the versioned frontend and local test package.

## `1.4.20261017.7` - 2026-10-17

- Separate Rule management from installation and updates: remove Rule/group/tag/AU prompts and pipeline inputs, preserve existing policy blobs and the legacy setting verbatim, and start new installations with an explicitly empty policy that grants no import access. Keep local Client Tools, audited first-Rule creation and concurrency protection; reject malformed policies and empty replacement submissions.
- Use Linux Flex Consumption for new installations with private Blob/Queue/Table endpoints, linked private DNS, separate VNet subnets and managed-identity Storage/deployment access. Disable public Storage, anonymous blobs and shared keys while retaining public UI and Entra-protected APIs. Preserve existing Windows Consumption hosting on updates; require a separate new app for migration. Document endpoint/DNS charges and fail explicitly on unsupported hosting, regions, permissions or policy-incompatible legacy Storage.
- Prefer CurrentUser PSResource dependency installation with a terminating PowerShellGet fallback. Bundle compatible runtime modules for Flex, disable Managed Dependencies only in its staged ZIP and use an HTTP root redirect instead of legacy proxies. Publish via bearer-authenticated OneDeploy with unique request correlation and confirmed completion; retain legacy publishing and ship all shared deployment helpers.
- Fix SPA redirect concatenation when only one frontend is configured, keeping interactive and silent-auth URLs separate while preserving unrelated redirects. Add fresh-install regression tests and repair the affected Entra registration with approval; no Function redeployment is required for that registration repair.
- Hide both Policy Manager administration and its Azure sign-in button for ordinary policy managers. Check the authenticated caller's direct, group and inherited Azure Owner/Contributor assignments server-side before requesting delegated ARM consent; retain delegated authorization for every manager-data operation and report verification failures explicitly.
- Add a custom role granting only `Microsoft.Authorization/roleAssignments/read`, assigned to the Function identity at Function App scope. Installation and updates now also verify custom role definition write permission; no additional identity configuration/write rights are granted. Preserve existing policy and manager settings during upgrade.
- Add a manual Re-Tagging device reload and persisted multiline policy descriptions, preserving descriptions through client edits and upgrades. Match target-group/AU headings to Extension Attributes and hide empty activity panels on both management tabs.
- Add permanent policy and manager change histories with caller, timestamp, operation ID and before/after details in paginated popups. Insert audit requests before writes, confirm only after synchronous conditional policy saves or manager updates, and report uncertain outcomes explicitly. Route client manager writes through the same audited backend; retain existing admin-only authorization for manager history. Import cleanup never deletes management events; no application delete action or administrator-proof WORM guarantee is provided.
- Show policy history per saved rule using persistent rule IDs, including after renames; remove the global history control and confirm saves with "Rule updated". Label history buttons and popup headings "Policy changes" ("Policy-Aenderungen" in German) on both management tabs. Require ruleId on REST history queries, return only that rule's changed snapshots and preserve legacy history without fabricated confirmations. Add Get-AutoPilotTagPolicyHistory with pagination; preserve rule IDs and descriptions in normal client output, edits and upgrades. Deleting a rule removes its history view while stored audit records remain retained.
- Fix false concurrent-change failures when saving rules by comparing normalized policy content instead of raw blob-binding JSON formatting. Retain ETag-conditional writes and reject actual concurrent rule/description changes; cover reordered properties and trailing newlines with regression tests.
- Show Information/Error event severity in management history summaries instead of request/completion labels; retain the audit phase in details so pending requests cannot be mistaken for saved changes. Record failure events after policy or manager save/confirmation errors when audit storage remains available, without hiding uncertain outcomes.
- Make the authorized user group a required single-line selection with "Change group", no removal and no object-ID label suffix. Block saves until the selected group resolves successfully; preserve multiple device target groups. Validate picker searches immediately, rejecting control/formatting characters and invalid lengths while retaining Unicode names and punctuation.
- Show localized save-blocking popups listing all missing rule names, authorized user groups and Autopilot Group Tags together, excluding fields already supplied. Explain other local validation failures in a popup and do not send invalid rules to the server.
- Rebuild the versioned frontend and nextversion installation package; expand API, UI, least-privilege, deployment, runtime-archive and redirect regression coverage. Deploy the group-picker and required-field improvements to the existing live Function App on version 1.4.20261017.5 with unchanged application settings and verified assets; the subsequent history-label rename and local installer changes are packaged, not a new live Function deployment. Local validation does not establish successful end-to-end Flex deployment; Checkov is unavailable.

## `1.4.20261016.12` - 2026-10-16

- Simplified the policy workspace: localized save confirmation dialogs, no Import History on the policy tab, readable rule-only tag labels, and no redundant introductory/help paragraphs. Entering TagPolicies automatically reloads current rules, with discard confirmation for unsaved edits and visible load errors.
- Added a separate, automatically refreshed Policy Managers tab with live user/group object picking, selected-entry removal, explicit saves and protected installer access. Each request requires the caller's effective Azure Owner/Contributor role and a separate delegated ARM token; ordinary policy managers cannot administer managers. The updater registers SPA ARM consent without elevating the Function identity; other settings and existing Intune administrator access are retained, stale edits are rejected, and saves warn about a possible Function restart.
- Included the manager endpoint in both release-package and Function-publish allowlists; regression coverage now checks that every runtime function is shipped through both paths.
- Handle Graph's exact-ID cross-type 404 as no matching user/group so mixed manager picking works; retain visible permission, service and name-search failures.
- Expanded the chronological import/re-tagging trace with explanations of asynchronous queueing, submitted versus completed Device Hash imports, confirmed Group Tags, Entra resolution, applied attribute values, target/added/removed groups and AU membership. Audit/API/PowerShell output retain the recorded details; skipped writes and pre-existing memberships are not presented as new changes, and old operations are not backfilled from current policies.
- Removed Intune Scope Tag creation, assignment and post-enrollment retries from the pre-enrollment workflow, editor, client results and audit timer. Older policies remain readable and retain their effective Group Tag; normal audit retention now also applies to old pending scope records. Required Graph permissions return to RBAC read access without managed-device writes; no existing tags or cloud role grants are automatically deleted.
- Documented every client-module function, including private helpers, configuration discovery, error handling, polling, hash indexing and policy updates; added help-completeness and scope-removal regression coverage. Expanded function help and inline explanations throughout authorization, import/history and device-tag handlers, the shared runtime module, web serving, Bicep infrastructure, installation and updates without changing executable behavior.

- Added named device policies with required Group Tags, explicit single-line Extension Attributes (max. 1024 characters, no control characters; no rows means no writes) and durable policy-owned device-group synchronization. The German/English manager editor includes collapsible rules, per-rule dirty-state saves, confirmed deletion, new-rule navigation, attribute-slot selectors and modal Entra group/AU pickers with named selectable lists. Legacy authorization-only rules retain compatibility; device-group actions require additional Microsoft Graph permissions.
- Preserved all named policy actions, multiple attribute values, empty maps and device-group targets through the regular updater; kept installer policies, management GET responses and PowerShell full-rule submissions as flat JSON arrays, including single-rule upgrades from 1.3 and subsequent 1.4 updates.
- Hide the TagPolicies tab until server-confirmed manager access, including keyboard navigation; report authentication/dependency failures explicitly. Interpret Graph error name `None` with code `0` as no error in the import overview and trace, while preserving real errors and queued-processing status.
- Started the nextversion branch from dev on release line 1.4; dev remains on 1.3 until the future release is explicitly promoted.
- Added protected nextversion-to-dev-to-main promotion, release-line validation, and automated dev sync PRs that preserve the future major/minor; made version updates preserve the current release line and support explicit minor/major advances.
- Synchronized the completed dev workflow setup into nextversion without changing its 1.4 release line, enabled PR checks during default-branch bootstrap, and retained the current main ancestry for strict dev-to-main promotion.
- Clarified the operational difference between `Get-AutoPilotImportHistory` and `Get-AutoPilotImportStatus` so support and automation can distinguish the retained audit record from the live import workflow state.
- Documented the live workflow fields returned by the status endpoint, including `workflowStatus`, `extensionAttributeStatus`, and the final-state interpretation used by the client.
- Refreshed the project release metadata and README guidance, rebuilt the versioned frontend and deployment package for the committed release; the separately verified live deployment remains on 1.4.20261016.11.

## `1.3.20261015.1` - 2026-10-15

- Fixed the stale re-tagging table refresh after successful Group Tag changes by disabling browser caching for dynamic device-list requests and reloading the current device list immediately after queue completion.
- Added a frontend regression test covering the no-cache request behavior for live dashboard data so the stale tag display cannot regress.
- Advanced the project version and refreshed the generated web frontend artifacts for the latest release.

## `1.3.20261008.1` - 2026-10-08

- Removed the direct GitHub Actions push of generated deployment packages to
  protected `main`; packages remain available as workflow artifacts and
  versioned GitHub release assets.

## `1.3.20261007.4` - 2026-10-07

- Expanded the PowerShell script documentation with workflow descriptions, parameter and output help, inline explanations, version consistency guidance, deployment-package checks, change-history validation, and cross-version REST error handling.

- Restructured the README and Developer Guide to separate user installation guidance from deployment, pipeline, testing, versioning, and operational documentation, and added sanitized import and re-tagging workflow screenshots.

- Reworked the README into a GitHub-oriented project page with centered branding, build and platform badges, compact navigation, the project support link, clearer device-import paths for the web frontend, Windows OOBE, the PowerShell module, and direct REST calls, and a dedicated re-tagging guide for every supported client.
- Replaced the previous Yeti web asset with the new project logo in both the frontend source and generated Function content, including accessible alternative text and versioned frontend output.
- Added `Get-AutoPilotDeviceTagAssignment` and `Set-AutoPilotDeviceGroupTag` to list eligible uninstalled Autopilot devices and submit authorized Group Tag changes from PowerShell, with pipeline and multi-device input, `WhatIf`, optional completion polling, timeout controls, actionable service errors, and packaged-module exports.
- Documented the retagging Function contract, required Graph application permissions, and PowerShell client interfaces in `DEVELOPER.md`, and moved the README navigation into an `In this article` section below the branding and support link.
- Extended client and packaging tests for the new commands and verified the complete PowerShell suite with the project Pester and Azure module dependencies.
- Replaced the repository-managed self-hosted Linux runner with GitHub-hosted
  `ubuntu-latest` execution for deployment-package validation and publication.
- Changed GitHub Actions to retain generated deployment packages as workflow
  artifacts instead of pushing directly to protected `main`.

## `1.3.20261006.6` - 2026-10-06

- Simplified the import workspace header by removing the redundant new-import label, renaming the registration heading to explicitly reference Microsoft Intune in both supported languages, and moving the workspace content closer to the top of the page.
- Added the Yeti logo to the right side of the application header with responsive desktop and mobile sizing.
- Fixed binary web assets so the Yeti logo is returned as raw PNG data with the correct MIME type instead of a serialized byte array.
- Added an authorized multi-device Group Tag change workflow for uninstalled Autopilot devices, including devices with empty or differently assigned current tags, target-tag authorization, current Group Tag, Entra groups, administrative units, shared progress reporting, synchronized policy-managed administrative-unit membership, and Graph-compatible device enumeration; separated import and re-tagging into accessible tabs, combined processing status and import history in one activity card, replaced hash references with the last update time, added an accessible per-operation trace dialog, kept history permanently visible, and removed the redundant completion notification.
- Promoted the release line to 1.3, rebuilt the generated web frontend, and synchronized the project version for publication from `dev`.

## `1.2.20261004.9` - 2026-10-04

- Replaced the previous Microsoft author address with the author's personal Outlook address across project metadata, documentation, scripts, modules, Functions, installers, and tests.
- Licensed the project under Apache 2.0, replaced Microsoft-specific sample disclaimers with project license notices, added public license metadata and a changelog, and included both files in deployment packages.
- Enforced promotion to `main` through pull requests originating from the repository's `dev` branch, with direct and force pushes and branch deletion blocked by repository rules.
- Added resolved Azure Subscription and Entra Tenant display names to the installation confirmation and structured installer result while retaining their IDs.
- Changed the installer to detect an existing Function App immediately after the four deployment identity values are resolved, validate required update modules before delegation, and switch to update mode without requesting replacement application or policy configuration.
- Fixed MSAL token acquisition on custom domains by using a dedicated frame-compatible redirect page, reusing the interactive login token, and falling back to a top-level redirect when privacy controls time out the hidden iframe, while retaining clickjacking protection on the main UI.
- Updated the web header to identify the Device Hash import purpose and added linked author and Apache 2.0 license information to the footer.
- Advanced and synchronized the project version and regenerated versioned frontend and deployment artifacts after the repository, author-metadata, licensing, branch-policy, and installer updates.

## `1.2.20261003.1` - 2026-10-03

- Documented the Group Tag policy management Function end to end, including its authentication and authorization flow, policy normalization, administrative-unit validation, configuration fallback, output bindings, helper functions, and safe persistence behavior.
- Advanced and synchronized the project version and regenerated release artifacts for publication from `main`.

## `1.2.20260929.4` - 2026-09-29

- Added manager-aware import history to the web frontend, including requester, status, serial number, and shortened device-hash references, with automatic fallback to the signed-in user's own records.
- Clarified least-privilege installation requirements: subscription-level read access, the required Resource Group deployment and role-assignment permissions, and the applicable Entra directory roles.
- Restored GitHub deployment-package automation on a self-hosted Linux x64 runner, including Pester 5.7.1 and required Azure PowerShell test dependencies, cross-platform path assertions, conditional frontend builds, artifact upload, and publication of the current `main` installation package.
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
