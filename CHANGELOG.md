# Changelog

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
