---
description: Bump version, update CHANGELOG.md, and prepare a release
argument-hint: "<major|minor|patch>"
---

Prepare a release for AgentSync with version bump type: $ARGUMENTS (default: patch).

## Current State

!`cat VERSION`

!`git log --oneline -10`

## Steps

1. Read the current version from `VERSION`.
2. Bump the version according to the bump type ($ARGUMENTS): major, minor, or patch.
3. Review recent commits since the last release tag to understand what changed:
   - `git log --oneline $(git describe --tags --abbrev=0 2>/dev/null || echo HEAD~20)..HEAD`
4. Update `CHANGELOG.md`:
   - Add a new `## X.Y.Z` section at the top (after the `# Changelog` header).
   - Group changes under `### Added`, `### Changed`, `### Fixed`, `### Removed` as appropriate.
   - Each entry: bold prefix describing the feature/fix, then a clear description of what changed and why.
   - Follow the existing style in CHANGELOG.md — look at previous entries.
5. Update the `VERSION` file with the new version number (just the number, no `v` prefix).
6. Commit with message: `release: v<new_version>`.
7. Do NOT push or create tags — CI handles tagging automatically when `VERSION` changes on `main`.

## Important

- CHANGELOG entries must describe user-facing impact, not implementation details.
- Don't include changes that are internal refactors with no user-visible effect.
- The `auto-tag.yaml` CI workflow creates the git tag when VERSION changes on main.
- The `release.yaml` CI workflow creates the GitHub Release from the tag + CHANGELOG section.
