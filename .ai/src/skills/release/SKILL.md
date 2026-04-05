---
name: release
description: >
  Bump version, write CHANGELOG entry, and prepare a release commit.
  USE WHEN releasing, bumping version, writing changelog, preparing a new version, or asked to cut a release.
---

# Release

Prepare a new AgentSync release: bump VERSION, update CHANGELOG.md, commit.

## Steps

1. **Check current state** — Read `VERSION` for current version. Ensure working tree is clean (`git status`).
2. **Determine bump type** — `major` (breaking changes), `minor` (new features), `patch` (bug fixes). Default: `patch`.
3. **Calculate new version** — Parse `MAJOR.MINOR.PATCH` from VERSION, increment the appropriate component.
4. **Gather changes** — Run `git log --oneline $(git describe --tags --abbrev=0 2>/dev/null || echo HEAD~20)..HEAD` to list commits since last release.
5. **Write CHANGELOG entry** — Add `## X.Y.Z` section at the top of `CHANGELOG.md` (after `# Changelog`):
   - Group under `### Added`, `### Changed`, `### Fixed`, `### Removed`.
   - Bold the feature/component name: `- **Export command:** added --dry-run support.`
   - Describe user-facing impact, not implementation details.
   - Match the tone and format of existing entries.
6. **Update VERSION** — Write the new version number to `VERSION` (no `v` prefix, no trailing newline).
7. **Commit** — `git add VERSION CHANGELOG.md && git commit -m "release: vX.Y.Z"`.
8. **Don't push** — CI handles the rest:
   - `auto-tag.yaml` creates the git tag when VERSION changes on `main`.
   - `release.yaml` creates the GitHub Release using the CHANGELOG section as release notes.

## CHANGELOG Format

```markdown
## 0.5.0

### Added
- **Feature name:** Description of what was added and why it matters.

### Changed
- **Component:** What changed and how it affects users.

### Fixed
- **Bug description:** What was broken and how it's fixed now.
```

## Gotchas

- Don't add a `v` prefix to the VERSION file — it's just `0.4.3`, not `v0.4.3`.
- Don't create git tags manually — `auto-tag.yaml` does this when VERSION changes on main.
- Don't push directly — let the user review the commit first.
- CHANGELOG entries extracted by CI use `awk` with exact `## X.Y.Z` matching — the version header must be `## X.Y.Z` with no extra text.
- The `agentsync release` CLI command exists but is for maintainer use with interactive confirmation. The AI workflow should just edit files and commit.
- Don't include internal refactors that have no user-visible effect in the CHANGELOG.
