# Changelog

## 0.3.0

### Improvements
- **`agent_sync.yaml` — full project config support:** `agentsync sync` now reads `defaults.enabled`, `defaults.cleanup`, `post_sync.allow`, and `post_sync.skip` from the project config file. Previously only `source.*` paths were honoured; all other settings were env-var-only or dead fields.
- **`defaults.enabled`:** tools that omit the `enabled` key in their YAML now fall back to `defaults.enabled` (default `true`) instead of hard-erroring.
- **`defaults.cleanup`:** setting `defaults.cleanup: false` prevents agentsync from deleting generated files when a tool is disabled.
- **`post_sync.allow` / `post_sync.skip`:** post-sync hook execution can now be controlled from `agent_sync.yaml`; `AGENTSYNC_ALLOW_POST_SYNC` and `AGENTSYNC_SKIP_POST_SYNC` env vars still take precedence.
- **`source.commands` and `source.subagents` overrides:** these two source paths can now be overridden in `agent_sync.yaml` just like `agents`, `rules`, `skills`, and `tools`.
- **`gitignore.update`:** setting `gitignore.update: false` in `agent_sync.yaml` disables automatic `.gitignore` management for projects that handle it manually or via another tool.

## 0.2.8

### Improvements
- **`agentsync init` generates `agent_sync.yaml`:** a project-level config file is now scaffolded in the repository root on first init, giving users a ready-made place to override source paths (`agents`, `rules`, `skills`, `tools`) without touching the global config.

## 0.2.7

### Improved
- **Line count guidelines added to `generate.md`:** each generated file type now has an explicit recommended size — `AGENTS.md` (40–70 lines), rules (20–50), skills (50–100), commands (15–40), agents (30–70) — so AI-generated configs stay focused and scannable.
- **Split-over-grow principle documented:** both `generate.md` and the `agentsync` skill now explicitly state that multiple small focused files are preferred over one large catch-all, for both rules and skills.
- **`agentsync` skill updated:** size guidelines and the split principle added to the "Writing Rules" and "Writing Skills" sections; AGENTS.md limit updated from `Under 60 lines` to `40–70 lines`.

## 0.2.6

### Fixed
- **ShellCheck SC2155:** split `export REPO_ROOT_CANONICAL="$(…)"` into two lines in `sync.sh` — assign first, then export — so a non-zero exit code from the subshell is not masked.

## 0.2.5

### Fixed
- **ShellCheck SC2034:** `REPO_ROOT_CANONICAL` in `sync.sh` marked as `export` so ShellCheck recognises it is consumed by sourced helper scripts (`helpers/paths.sh`) and stops reporting it as unused.

### Changed
- **Annotated git tags:** `agentsync release` now creates an annotated tag (`git tag -a`) whose message is the corresponding CHANGELOG.md section instead of a bare lightweight tag.
- **Auto-tag CI:** `auto-tag.yaml` likewise creates an annotated tag with the changelog body, so the tag object on GitHub carries the release notes.
- **GitHub Release body from CHANGELOG:** `release.yaml` now populates the GitHub Release description from the CHANGELOG.md section for the tagged version instead of a raw git-log dump.

## 0.2.4

### Fixed
- **Multi-version update changelog:** `agentsync update` now shows release notes for every version skipped during an update, not just the final one. Versions are displayed in ascending order (oldest → newest). Previously, jumping from e.g. v0.2.0 to v0.2.3 silently omitted the intermediate release notes.

## 0.2.3

### Code Quality
- **Sync engine modularized:** `lib/helpers/files.sh` (628 lines) split into four focused modules — `filters.sh`, `file_ops.sh`, `rule_operations.sh`, and `format_conversion.sh` — each with a single responsibility.
- **Path resolution extracted:** eight path utility functions moved from `sync.sh` into a dedicated `helpers/paths.sh`, reducing `sync.sh` by ~180 lines.
- **`cmd_init` refactored:** monolithic 227-line function broken into four private sub-functions (`_init_create_directories`, `_init_copy_source_templates`, `_init_copy_tool_configs`, `_init_print_summary`) with a thin orchestrator.

## 0.2.2

### Fixed
- **Shell arithmetic across all sync functions:** replaced `((count++))` with `count=$((count + 1))` in `sync_dir`, `copy_rules`, and `sync_rules` — prevents false exit code 1 when counter is zero under `set -e`, which caused `agentsync sync` to silently abort mid-run.

### CI
- **Windows support:** tests now run on `ubuntu-latest`, `macos-latest`, and `windows-latest`; bats installed via `git clone` on Windows, all steps use `shell: bash`.
- **Node.js 24:** added `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true` at workflow level to silence Node 20 deprecation warnings.
- **Auto-tagging:** pushing to `main` with a changed `VERSION` file now automatically creates and pushes the corresponding git tag, triggering a GitHub Release.

## 0.2.1

### Fixed
- **`cd` safety:** `cd` calls in `update` and `release` commands now abort on failure (`|| exit 1`) instead of silently continuing in the wrong directory.
- **`rm -rf` guard:** destination path in `sync_dir` uses `${dest:?}` to prevent accidental root deletion if the variable is unset.

### CI
- ShellCheck: added `SC2039` and `SC2166` to the ignore list to suppress false positives on intentional bash-isms.

## 0.2.0

### Added
- `agentsync generate` — interactive mode with project description input
- `agentsync release [major|minor|patch]` — bump version, tag, and push
- Bats test suite — 101 tests covering all commands (cli, init, sync, check, generate, list, hooks, release)
- CI/CD via GitHub Actions — ShellCheck linting + tests on Ubuntu and macOS
- Automated GitHub Releases on tag push
- Update notification banner when a new version is available
- Symlink auto-repair on `agentsync update` (handles renames across versions)
- `init` now shows enabled tools list and improved next steps
- Migration guide in README for existing configurations

### Changed
- Default enabled tools reduced to top 6: Claude Code, Cursor, GitHub Copilot, Windsurf, Gemini CLI, OpenAI Codex
- Flattened `lib/system/` → `lib/`, `lib/system/lib/` → `lib/helpers/`
- Removed duplicate docs: `lib/README.md`, `lib/docs/STRATEGY.md`, `lib/system/README.md`

### Fixed
- Cross-platform `readlink` compatibility in update command
- macOS `sed` compatibility in generate command
- Disabled tool cleanup no longer deletes files owned by other enabled tools

## 0.1.2

- Initial public release
- 17 AI tools supported
- Sync engine with format conversions (MD → MDC, TOML, instructions.md)
- Git hooks for auto-sync
- `agentsync check` for CI validation
