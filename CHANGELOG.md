# Changelog

## 0.10.2

### Fixed

- `agentsync init` crashed on macOS (bash 3.2) with `${default,,}: bad substitution`. The new interactive-prompt helper used the bash 4+ lowercase expansion `${var,,}`, which doesn't exist in macOS's stock `/bin/bash`. Replaced with a portable `tr '[:upper:]' '[:lower:]'` pipeline so `init` (and any future `prompt_confirm` caller) works on macOS's shipped bash without requiring `brew install bash`.

## 0.10.1

### Fixed

- `agentsync simplify` aborted under `set -euo pipefail` when no payload overrides were present because the payload pass returned a non-zero "nothing matched" code and `set -u` tripped on an unbound `any_considered` on exit paths. Switched to an explicit `_SIMPLIFY_PAYLOAD_MATCHED` out-flag and removed the unbound reads so `simplify` with no overrides now prints the friendly "nothing to simplify" message as intended.

## 0.10.0

### Added

- **Minimal `init`:** fresh projects get `.ai/agent_sync.yaml` + `AGENTS.md` + starter rules — payload files for hooks / MCP / settings are no longer eagerly copied for every supported tool. Opt in per tool with `--tools <csv>` or let auto-detection (`.claude/`, `.cursor/`, `CLAUDE.md`, ...) union in what you already use. A Claude-only project drops from ~20 scaffolded files to 3.
- **Interactive `init` wizard:** running `agentsync init` in a TTY opens a multiselect for tools (base catalog + auto-detected preselected) and content sections, then shows a plan + confirm before writing. Non-TTY (CI, scripts) skips the wizard silently. `--yes` accepts defaults in a TTY, `--dry-run` prints the plan without writing.
- **Base + override for hooks / MCP / settings:** `sync` now resolves each payload the same way tool YAMLs already do — project override (`.ai/src/<resource>/<tool>.<ext>`) wins, otherwise the shipped base template at `lib/templates/<resource>/<tool>.<ext>` is used. Delete an override and the base flows through on the next sync; no more per-tool payloads gating on files that have to exist somewhere.
- **`agentsync customize <tool> <resource>`:** dedicated path to create a payload override. `customize cursor hooks` copies the base hooks template into `.ai/src/hooks/cursor.json`; same pattern for `mcp` and `settings`. Hooks get a security gate — the base content is displayed first, and in non-TTY mode `--yes` is required before scaffolding.
- **`agentsync show <tool> <resource>` / `diff <tool> <resource>`:** inspect any payload resource — `show` tags `base` vs `★ user override`, `diff` prints a unified diff against the base.
- **Secret scanning in `doctor`:** `.ai/src/{mcp,settings,hooks}/*` are regex-scanned for common credential shapes (OpenAI/Anthropic `sk-*`, GitHub `ghp_*` / `github_pat_*`, AWS `AKIA*`, Slack `xox[baprs]-*`, Google `AIza*`, JWT). Placeholders (`${VAR}`, `<PLACEHOLDER>`) are ignored. JSON files are also syntax-validated when `python3` or `node` is available.
- **Version pinning:** `init` writes `agentsync_version: "<VERSION>"` at the top of `agent_sync.yaml`. `doctor` warns when the pinned version differs from the current CLI and suggests `agentsync upgrade-config` — the new command to re-pin.
- **`agentsync simplify` extended to payloads:** in addition to trimming redundant fields from tool YAML overrides, `simplify` now detects byte-identical payload overrides (scaffolded copies the user never edited) and offers to delete them so future updates to the base flow through automatically. `--apply -y` deletes non-interactively, `--apply` prompts in a TTY.
- **`list` resources column:** each tool row now shows `H M S` — hooks / MCP / settings indicators. Lowercase letter = base template available, `*` = user override present, `·` = no base for that resource. Summary line counts payload overrides separately from tool overrides.

### Changed

- **`init` no longer eagerly copies payloads for every tool.** Projects that opt in explicitly (`--tools claude,cursor`) or via auto-detection still get scaffolded copies; everything else falls through to base templates at sync time. Existing projects with per-tool payloads in `.ai/src/{hooks,mcp,settings}/` continue to work unchanged.
- **`customize <tool>` signature is now `customize <tool> [<resource>]`.** Without a resource argument it behaves exactly as before (tool YAML override). `<resource>` accepts `tool` (default), `hooks`, `mcp`, or `settings`.

### Migration

- Existing projects are not required to change anything. Run `agentsync simplify --apply` to clear out scaffolded-but-unedited payload overrides — the base templates will take over on the next sync without a behavior change. Run `agentsync upgrade-config` to re-pin `agentsync_version`.

## 0.9.0

### Added

- **`agentsync simplify [<tool>] [--apply] [-y]`:** walks every user override in `.ai/src/tools/` and drops fields whose value already matches the current base template. Trims the side effect of `customize --full` over time — redundant fields silently pin stale values and block upstream improvements, and `simplify` clears them out in one pass.
- **Dry-run by default:** prints a grouped preview — `Redundant (match base)`, `Kept (diverge from base)`, `Kept (no base value)` — so nothing is written until you pass `--apply`. When all fields match base, the preview reports the override file would be deleted outright.
- **`--apply -y` deletes emptied override files:** after `--apply` removes every redundant field, if the file has no real `key: value` content left, it's deleted automatically with `-y`. Without `-y`, an interactive shell prompts `[y/N]`; in non-TTY contexts (CI) the empty file is kept untouched.
- **Idempotent:** re-running `simplify --apply` on an already-minimized override is a no-op. Safe to add to pre-commit or CI hygiene checks.

## 0.8.0

### Added

- **Upstream drift detection on `agentsync update`:** before pulling a new release, the CLI snapshots the install-dir tool catalog and compares it against the new base catalog field-by-field. When an upstream change lands on a field you have overridden in `.ai/src/tools/<tool>.yaml`, the update prints a grouped warning — `<tool>: <field> — base changed from X to Y, your override is Z` — so silent upstream improvements can't be masked by a stale override.
- **`.ai/.pending-resolutions.yaml` queue:** conflicts surfaced by an update are persisted to this file (schema 1, with `from_version`, `to_version`, and the full before/after/override triple per conflict). Acts as an actionable to-do list between an update and your next resolve pass.
- **`agentsync resolve` reads the pending queue:** flags each conflicted field with `⚡` (vs. the default `◆`) and prints a banner listing how many fields were queued by the last update. Walking every override clears the queue automatically.
- **`agentsync update --strict`:** non-zero exit when any upstream change collides with a user override. Intended for CI — blocks a merge until someone reviews the drift.

## 0.7.0

### Added

- **`agentsync add <kind> <name>`:** scaffolds new source content with the right frontmatter and placement — `rule` → `.ai/src/rules/<name>.md`, `skill` → `.ai/src/skills/<name>/SKILL.md`, `command` → `.ai/src/commands/<name>.md`, `subagent` → `.ai/src/agents/<name>.md`. Refuses existing files by default; pass `--force` / `-f` to overwrite. Names are validated against path separators, `..`, leading `.` or `-`, and non-`[A-Za-z0-9_-]` characters — no surprise writes outside the `.ai/src/` tree.
- **Content templates:** new `lib/templates/content/{rule,skill,command,subagent}.md` ship minimal stubs with the `{{NAME}}` placeholder and the conventions each kind expects (`USE WHEN` clauses for skills, `## Gotchas`, `$ARGUMENTS` / `` !`cmd` `` hints for commands, `model` + `tools` frontmatter for subagents).

## 0.6.0

### Added

- **Layered tool configs:** tool YAMLs now follow an ESLint `extends` / Kustomize-style model. Each tool has a hidden base template in the install-dir catalog; users create per-field overrides in `.ai/src/tools/<tool>.yaml` that merge on top of the base. Fresh updates to base fields flow automatically to any field a user hasn't customized — no silent loss of upstream improvements.
- **`agentsync enable` / `disable`:** explicit opt-in/out of tools via the project `agent_sync.yaml` `tools.enabled` list. Replaces per-tool `enabled: true` flags (legacy form still recognized with a deprecation warning from `doctor`).
- **`agentsync customize <tool>`:** creates an empty override stub in `.ai/src/tools/<tool>.yaml` (or `--full` to copy the entire base for heavy editing). Stub points users to `agentsync show <tool> --base` for reference.
- **`agentsync show <tool>`:** prints the effective merged config for a tool, marking each field as `base` or `user`. `--base` prints just the upstream template.
- **`agentsync diff`:** lists tools with user overrides and shows which fields diverge from base.
- **`agentsync resolve`:** interactive walkthrough of diverging fields — `[k]eep` the override, `[a]dopt` the base value (removes the field so inheritance resumes), or `[s]kip`. Read-only notice in non-TTY contexts.
- **`agentsync doctor`:** four-section health check (project layout, enabled tools, user overrides, source directories). Exit codes 0/1/2 for clean / warnings / fatal. Flags legacy `enabled: true` overrides and missing base templates.
- **Auto-detection on `init`:** detects existing tool markers (`.claude/`, `.cursor/`, `.github/copilot-instructions.md`, etc.) and pre-fills `tools.enabled` so users don't have to manually opt in tools they're already using.
- **`list` markers:** ● enabled, ○ available, ★ customized — at-a-glance view of which tools are active and which have user overrides.

### Changed

- **`agentsync init` no longer scaffolds `.ai/src/tools/`** — the base catalog is hidden in the install-dir. Tools are opted in via `agentsync enable <tool>`. Existing projects with per-file `.ai/src/tools/*.yaml` overrides continue to work unchanged.
- **Sync engine reads layered configs:** `sync.sh` and `check.sh` now resolve each field via the layered lookup (user override → base template → built-in default) instead of reading a single YAML per tool. Sync output is unchanged for users who don't customize.
- **Empty `tools.enabled`** in `agent_sync.yaml` is now emitted inline as `enabled: []` (was multi-line with a stray empty-list marker).

### Fixed

- **`set -u` safety:** empty-array expansions in `enable.sh` no longer trip `unbound variable` under strict mode when no unknown tools are passed.
- **`disable` no-op bug:** `PROJECT_CONFIG_PATH` resolution was missing from the enable/disable context, causing `is_tool_enabled` to always return false. Now resolved and exported consistently across `enable`, `disable`, `customize`, `show`, `diff`, `doctor`, `resolve`.
- **YAML list append with inline `[]`:** appending a dash-item to `enabled: []` previously produced invalid YAML. The inline form is now rewritten to a bare `key:` before the item is appended.

## 0.5.4

### Changed

- **Update check:** runs in the background on every command instead of blocking once every 24 hours. The notification appears on the next invocation after a newer version is detected — zero latency on any command.

## 0.5.3

### Fixed

- **Sync performance for disabled tools:** dest paths are no longer parsed or resolved for tools with `enabled: false` when cleanup is off. Previously, each skipped tool triggered ~9 `parse_yaml_value` calls and up to 8 path-resolution calls before the enabled check — causing noticeable lag with several disabled tools.

## 0.5.2

### Fixed

- **Update check for help commands:** `help`, `--help`, and `-h` now trigger the update check alongside other interactive commands, so users see version notices when asking for help.

### Changed

- **`.gitignore`:** moved `.mcp.json` and `CLAUDE.md` exclusions outside of the `.claude/` directory scope to match their new root-level destinations (introduced in 0.5.1).

## 0.5.1

### Changed

- **Claude `CLAUDE.md` now writes to project root** instead of `.claude/CLAUDE.md`. Both paths are valid per Claude Code docs, but root is the canonical team-shared location shown in the best-practices guide and aligns with the AGENTS.md cross-tool spec used by Cursor / Codex / Windsurf.
- **Claude `.mcp.json` now writes to project root** instead of `.claude/.mcp.json`. Claude Code only auto-discovers project-scope MCP servers from `./.mcp.json` — the previous `.claude/.mcp.json` location was never picked up as project scope.

### Fixed

- **`tests/sync_options.bats`** — corrected `.cursor/AGENTS.md` assertions to root `AGENTS.md` (broken since 0.5.0 moved Cursor's agents dest to root).

## 0.5.0

### Added

- **Per-tool settings, MCP, and hooks coverage:** added missing canonical config targets across the matrix:
  - **Aider** — `settings → .aider.conf.yml` with auto-loaded `read: CONVENTIONS.md` (so the conventions file is actually picked up without `--read`).
  - **Amazon Q** — `mcp → .amazonq/mcp.json`; `subagents → .amazonq/cli-agents/*.json` via new MD→Amazon Q JSON converter (preserves `name`/`description`/`model`/`tools`).
  - **Cline** — `commands → .clinerules/workflows/*.md` (Cline slash commands).
  - **Codex** — `settings → .codex/config.toml` with `[mcp_servers.X]` template skeleton.
  - **Continue** — migrated from legacy `.continuerules` to canonical `.continue/rules/*.md` directory; `settings → .continue/config.yaml`.
  - **Cursor** — `commands → .cursor/commands/*.md` (Cursor 1.6 slash commands).
  - **Gemini CLI** — `settings → .gemini/settings.json` (combined config + MCP servers + hooks).
  - **Junie** — `skills → .junie/skills/`, `commands → .junie/commands/`, `subagents → .junie/agents/`, `mcp → .junie/mcp/mcp.json`.
  - **Windsurf** — `commands → .windsurf/workflows/*.md` (Cascade workflow slash commands), `hooks → .windsurf/hooks.json` (Cascade Hooks).
  - **Antigravity** — `commands → .agent/workflows/`.
  - **Zed** — `settings → .zed/settings.json` (holds `context_servers` for MCP).
- **MD→Amazon Q JSON converter** (`lib/helpers/format_conversion.sh`) — generic frontmatter parser now extracts `model:` and `tools:` (both inline `[a, b]` and YAML list forms); new `_json_escape` helper; new `convert_md_agent_to_amazonq_json` / `sync_agents_as_amazonq_json` functions; sync dispatcher accepts `format: amazonq_json`.
- **Frontmatter merge for rule sync** — new `merge_or_prepend_header()` in `lib/helpers/rule_operations.sh`. When a rule file already has frontmatter, the tool's default header only fills missing keys; source keys win. Lets users override `globs` / `trigger` / `applyTo` per rule for Cursor / Copilot / Windsurf without losing the tool default.
- **Templates:** new skeletons for `lib/templates/settings/{aider.yaml,codex.toml,continue.yaml,gemini.json,zed.json}`, `lib/templates/mcp/{amazonq.json,junie.json,windsurf.json}`, `lib/templates/hooks/{copilot.json,windsurf.json}`.
- **`enable_tools` test helper** in `tests/test_helper.bash` for opt-in test scenarios after the disabled-by-default change.

### Changed

- **AGENTS.md / GEMINI.md identity files now live at the canonical project root** for tools that follow the open spec — Cursor, Windsurf, Gemini CLI, Antigravity all moved their identity dest from `.<tool>/AGENTS.md` (or `.<tool>/GEMINI.md`) to the repository root. Aligns with the AGENTS.md cross-tool spec, deduplicates identical content across `.tool/` namespaces, and lets tools share one source of truth alongside Codex / Amp / Devin.
- **Junie** — agent identity moved from legacy `.junie/guidelines.md` to preferred `.junie/AGENTS.md` (per JetBrains docs); rules now inlined into the AGENTS.md (legacy `.junie/rules/` was unsupported).
- **Antigravity** — agent identity moved from `.agent/AGENTS.md` to canonical root `GEMINI.md`.
- **Claude `settings.json` template expanded** — added `model: sonnet`, `includeCoAuthoredBy: true`, `permissions.defaultMode`, an `ask` permission list, and an extended `deny` list covering secrets, PEM keys, and SSH keys.
- **Claude `rules` target** — removed redundant `append_imports: true`; Claude Code auto-discovers `.claude/rules/*.md` per docs, so the explicit `@import` block was double-loading content into CLAUDE.md.
- **Tool YAMLs** — stripped noise comments across all tool configs (`# X Configuration`, `# Reads AGENTS.md from root`, etc.) — the YAML structure is self-documenting.

### Removed

- **Amp, Devin, Tabnine** tool configs removed (not maintained against current docs; users with those tools can copy `_TEMPLATE.yaml`).
- Legacy `append_imports` usage in Claude scaffold and tests.

### Fixed

- **Tests aligned with disabled-by-default policy** — `tests/sync.bats`, `sync_options.bats`, and `check.bats` now call `enable_tools` after `init` instead of relying on shipped enabled defaults; `init.bats` asserts all tools default to `enabled: false`.

### Documentation

- **`agentsync` skill** rewrites — added Claude `settings.json` reference (model / env / statusLine / outputStyle / hooks-in-settings), Claude `.mcp.json` reference (stdio / http / `${VAR}` expansion), per-tool hooks comparison table (Claude / Cursor / Copilot / Codex / Windsurf), per-tool MCP comparison table, per-rule frontmatter override section.

## 0.4.2

### Changed

- **All tools disabled by default:** `agentsync init` now creates all 17 tool configs with `enabled: false`. Users explicitly enable only the tools they need via `.ai/src/tools/<name>.yaml → enabled: true`. Previously 6 tools (Claude Code, Cursor, Copilot, Gemini, Codex, Windsurf) were enabled out of the box.
- **`defaults.enabled` set to `false`:** the global fallback in `config.yaml`, `sync.sh`, and the scaffolded `.ai/agent_sync.yaml` now defaults to `false`, so tools that omit the `enabled` key are skipped rather than synced.

## 0.4.1

### Changed

- **`agent_sync.yaml` moved inside `.ai/`:** project config is now created at `.ai/agent_sync.yaml` instead of the repository root, keeping all AgentSync files in one place and simplifying export/import.
- **Backward compatible:** `sync`, `export`, and `import` check `.ai/agent_sync.yaml` first, then fall back to the legacy root-level `agent_sync.yaml` — existing projects continue to work without changes.
- **`init` respects both locations:** skips config creation if either path already exists.

### Fixed

- **`set -e` safety in `_resolve_source_paths`:** `[[ -n "" ]] && ...` without `|| true` caused silent exit under `set -e` when `agent_sync.yaml` keys were missing.

## 0.4.0

### Added

- **`agentsync export`** — bundles `.ai/src/` (rules, skills, commands, agents, settings, mcp, hooks, tools) and `agent_sync.yaml` into a single shareable `agentsync-bundle.tar.gz` archive.
- **`agentsync import <source>`** — imports agent config from three source types:
  - **GitHub URL** — downloads repository archive by branch (`--branch`, auto-detects `/tree/<branch>` in URL, falls back from `main` to `master`)
  - **Archive file** — extracts a `.tar.gz` / `.tgz` bundle (e.g. from `agentsync export`)
  - **Local directory** — copies `.ai/` and `agent_sync.yaml` from another project
- **Selective import** — `--only rules,skills` imports only specified targets
- **Diff preview** — both commands show a summary of new / updated / unchanged files before writing
- **Dry-run** — `--dry-run` on both export and import previews changes without writing
- **Confirmation prompt** — import asks before overwriting existing files (skip with `--force`)
- **Dynamic source paths** — export and import resolve source paths from `agent_sync.yaml` overrides and auto-detect `.ai/src/` vs `.ai/` (legacy) layout

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
