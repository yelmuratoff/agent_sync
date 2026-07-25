---
description: Bump version, update CHANGELOG.md, and prepare a release
argument-hint: "<major|minor|patch>"
---

Prepare a release for AgentSync with version bump type: $ARGUMENTS (default: patch).

## Current State

!`cat VERSION`

!`git status --porcelain`

!`git log --oneline $(git describe --tags --abbrev=0 2>/dev/null || echo HEAD~20)..HEAD`

## Pre-release checks

Run these first. Stop on the first failure and report — don't quietly skip or auto-fix.

1. **Working tree clean** — the `git status` block above must be empty. Commit or stash first.
2. **Tests pass** — run `bats tests/`. Any failure halts the release.
3. **ShellCheck clean** — run `shellcheck -x -S warning -e SC1091 bin/agentsync.sh lib/sync.sh lib/check.sh lib/setup_hooks.sh lib/helpers/*.sh`.
4. **CHANGELOG covers user-facing commits since last tag** — walk the `git log` block above. Every commit that changes CLI behaviour, output, supported tools, or a user-hittable bug needs a line in the new CHANGELOG section. Internal refactor / test / CI / dev-tooling commits stay out.
5. **Docs reflect current behaviour** — spot-check for stale docs:
   - `README.md` — command list, flag list, supported tools.
   - `.ai/src/commands/*.md`, `.ai/src/skills/**/SKILL.md` — descriptions and examples match what `bin/agentsync.sh` accepts.
   - `.ai/src/rules/*.md` — invariants and the module map in `architecture.md` match current `lib/helpers/` layout.
   - `.ai/src/tools/_TEMPLATE.yaml` — every option used by `lib/sync.sh` is documented; nothing documented is dead.
   - If `bin/agentsync.sh` or `lib/sync.sh` changed since the last tag and no doc files did, ask the user whether docs need a follow-up before tagging.

Fix any doc gaps in the **same release commit** rather than punting to a "docs" release.

## Steps

1. Run the pre-release checks above. Stop on first failure.
2. Read the current version from `VERSION`.
3. Bump the version according to the bump type ($ARGUMENTS): major, minor, or patch.
4. Review recent commits since the last release tag to understand what changed (the `git log` block above).
5. Update `CHANGELOG.md`:
   - Add a new `## X.Y.Z` section at the top (after the `# Changelog` header).
   - Group changes under `### Added`, `### Changed`, `### Fixed`, `### Removed` as appropriate.
   - Each entry: bold prefix describing the feature/fix, then a clear description of what changed and why.
   - Follow the existing style in CHANGELOG.md — look at previous entries.
6. Update the `VERSION` file with the new version number (just the number, no `v` prefix).
7. Commit with message: `release: v<new_version>`. Include any doc files fixed during the pre-release checks in the same commit.
8. Do NOT push or create tags — CI handles tagging automatically when `VERSION` changes on `main`.

## Important

- CHANGELOG entries must describe user-facing impact, not implementation details.
- Don't include changes that are internal refactors with no user-visible effect.
- The `auto-tag.yaml` CI workflow creates the annotated git tag (CHANGELOG section as the message) when VERSION changes on main.
- Releases are tag-only — no GitHub Release is published. `agentsync update` pulls new versions from tags.
- Never ship a release with known-stale docs to "fix later".
