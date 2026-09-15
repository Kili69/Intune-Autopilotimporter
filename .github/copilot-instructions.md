# Project Guidelines

## Commits And Versioning

- Do not create commits unless the user explicitly requests one.
- Before every non-automation commit, update `VERSION` with `src/Scripts/Update-ProjectVersion.ps1` and update `History.md`.
- Keep exactly one `History.md` section for the UTC date encoded in `VERSION`. Use the current, highest version as that section's heading, merge all changes from the same date into it, and remove older headings for that date.
- Consolidate same-day changes into concise, thematic bullets without dropping user-visible behavior, security changes, deployment changes, or compatibility notes.
- Rebuild generated frontend and deployment-package artifacts when their embedded version changes.
- After committing, run `src/Scripts/Test-ChangeHistory.ps1 -BaseCommit HEAD^ -HeadCommit HEAD`. Amend the commit if validation fails.

## Validation

- Run the focused tests for changed code and the full Pester suite before packaging a release.
- Do not revert unrelated working-tree changes.