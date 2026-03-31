# Changelog

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
