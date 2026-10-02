# Changelog

All notable user-facing changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Project versions use the repository's date-based version scheme. Earlier
development history remains available in [History.md](./History.md).

## Unreleased

## 1.3.20261002.3 - 2026-10-02

### Added

- Added REST and PowerShell support for assigning an authorized Group Tag to an
  existing, not-yet-enrolled Windows Autopilot device.
- Added web selection of `notContacted` Autopilot devices below the CSV upload,
  including the current Group Tag and the caller's authorized target tags.
- Added persistent, owner-scoped reassignment operation IDs and end-to-end
  status polling for Intune updates, extension attributes, and Administrative
  Unit processing.

### Changed

- Reused the existing post-processing workflow after reassignment, including
  removal from Administrative Units configured for the previous tag and
  assignment to the target Administrative Unit.
- Reduced the height of the CSV drop area.
- Changed Autopilot device lookups to tenant-compatible unfiltered Microsoft
  Graph requests with local filtering and pagination.
- Changed the web status to remain pending until all reassignment
  post-processing has completed.

### Fixed

- Fixed contradictory reassignment results that displayed `Complete` while the
  details still said that post-processing had only started.
- Fixed production device-list and device-lookup failures caused by unsupported
  Intune Graph query options in some tenants.
- Added explicit reporting when Group Tag reassignment succeeds but subsequent
  Entra post-processing fails.

### Security

- Rejects reassignment before changing Intune when the device is already a
  member of a configured Restricted Management Administrative Unit that the
  service cannot manage.
- Restricts reassignment status records to the user who started the operation.
