---
name: release
description: Bump the AgentSync version, write a CHANGELOG entry summarising changes since the last tag, and prepare a clean release commit. Use this skill when the user asks to release, ship, cut a version, bump major/minor/patch, tag, or prepare a new version — including phrasings like "let's ship 0.12", "поднять версию", "сделай релиз", or when asked to update CHANGELOG.md after a stretch of work.
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
8. **Leave the push to the user** — CI handles the rest:
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

- Write the VERSION file as `0.4.3`, never `v0.4.3` — the `v` prefix breaks the auto-tag workflow.
- Leave git tag creation to CI. `auto-tag.yaml` runs when VERSION changes on `main`.
- Stop after the commit — let the user review before pushing.
- CHANGELOG entries extracted by CI use `awk` with exact `## X.Y.Z` matching — the version header must be `## X.Y.Z` with no extra text.
- The `agentsync release` CLI command exists for maintainer use with interactive confirmation. The AI workflow edits files and commits.
- Keep CHANGELOG entries to user-visible changes. Internal refactors with no behavioural effect stay out.
