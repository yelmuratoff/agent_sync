# Changelog

## Unreleased

### Fixed

- **Interrupting a command no longer leaves garbage behind — or a half-written project.** Every handler was armed on `EXIT` only, and a Bash script killed by a signal never runs its `EXIT` trap. Ctrl-C during `sync` therefore leaked the shared-overlay tree (a full copy of `.ai/src`), leaked the backup staging directory (a full copy of the managed write set, inside the repository), *and* skipped the transactional restore, leaving destinations half-written. Handlers now cover `INT`, `TERM`, and `HUP`, pass the signal's status explicitly instead of reading `$?` — which inside a signal handler holds the last completed command's status and is frequently `0` — and re-raise so the caller still sees a real interrupt.
- **Orphaned backup staging is reclaimed.** A run killed mid-snapshot left `.ai/backups/.tmp.<op>.*` in the project permanently: the names are dot-prefixed, so `backup_prune`'s glob never saw them, and it also required a `.complete` marker they never get. `backup_create` now sweeps staging and metadata temporaries older than 24 hours, a threshold that leaves a concurrently running sync's staging untouched.
- **Temp files no longer accumulate in `$TMPDIR`.** `agentsync_legacy_warn_<pid>` was written on every invocation that saw a legacy payload override and removed by nothing; a dozen other `mktemp` sites had no cleanup on their error paths. All scratch now lives in one per-run directory reclaimed on every exit path, and atomic-write staging files are registered for cleanup where they must stay beside their destination.
- **Shared and profile overlays are cleaned up under any `TMPDIR`.** Teardown only removed paths matching `/tmp`, `/private/tmp`, or `/var/folders`, so a custom `TMPDIR` (`TMPDIR=$RUNNER_TEMP` on CI) leaked a full `.ai/src` copy per sync and printed a "looks suspicious" warning. The guard now checks provenance — the overlay must live in the directory this run created — which is both correct under any `TMPDIR` and narrower: the old check would have removed any unrelated directory that happened to sit under `/tmp`.
- **A run of failing syncs no longer accumulates snapshots.** Pruning ran only on the success path. It now also runs after a failed `sync` or `init` whose restore completed — but never when the restore failed, since the store then holds the only copy of the pre-operation state.

### Changed

- **Backups are bounded by age as well as count.** A snapshot is retained only if it is among the newest `AGENTSYNC_BACKUP_LIMIT` (default 10) *and* younger than `AGENTSYNC_BACKUP_MAX_AGE_DAYS` (default 30); either set to `0` disables that bound alone. The newest snapshot is always retained, so rollback stays available however long a project sits idle, and a snapshot whose name carries no parseable timestamp is never aged out. Age is computed with integer civil-date arithmetic — `date -u -v-30d` is BSD-only and `date -u -d` is GNU-only, and a failed substitution would have yielded an empty cutoff that compares equal to everything.

## 0.33.5

### Fixed

- **`agentsync check` now works in a global install.** Check copied the whole project root into its temporary workspace. For a global install that root is `$HOME`, so it tried to read OS-protected directories (`~/Library`, `~/Pictures`) and multi-GB tool caches — aborting with `Failed to prepare temporary workspace` on macOS, and filling the disk on the way there. It now copies only the `.ai/` source tree plus the outputs recorded in `.sync-manifest`, excludes `.ai/backups/`, and compares just those managed paths instead of diffing the entire root. Files beside the project no longer count as drift, and a partial copy is reported as a failure instead of passing as "in sync".

## 0.33.4

### Fixed

- **Sparse shared overlays no longer abort sync.** Nested workspace sync now skips optional shared categories that have no files instead of exiting under `set -e`; rules, skills, commands, and agents can be listed in `shared.inherit` before their source directories exist.

## 0.33.3

### Changed

- **English-only skill discovery examples:** replaced Russian trigger phrases in bundled skill descriptions and writing guidance with English equivalents, removing redundant examples. Existing projects receive the updated templates through `agentsync refresh`; new projects receive them through `agentsync init`.

## 0.33.2

### Added

- **`agentsync init --no-templates`.** Scaffold the usual `.ai/src/` section directories (and an empty `AGENTS.md` when the agents section is selected) without copying shipped starter rules, skills, commands, or subagents. Pairs with `--no-detect` for nested `.ai/` trees or migrations where you bring your own content; use `agentsync refresh` later to adopt shipped templates selectively.

## 0.33.1

### Added

- **AI-assisted project migration prompt.** `agentsync migrate` now prints a self-contained prompt and automatically copies it with the available macOS, Linux, Wayland, X11, or Git Bash clipboard tool. The prompt grounds an AI migration in the project's pinned version, every relevant official changelog entry, and the latest matching documentation and templates; it requires a recoverable checkpoint, minimal source-of-truth edits, supported AgentSync migration commands, and `doctor` / `sync` / `check` verification. The historical layout migration remains available as `migrate --legacy` for dry-run and through the backwards-compatible `migrate --apply [--yes]` route.

### CI

- **Windows backup safety tests now exercise real symlinks.** Git Bash normally turns `ln -s` targets into copies, so the backup containment tests were checking ordinary in-project directories and incorrectly reporting three security guards as failures. The shared fixture now requests native symlinks with `MSYS=winsymlinks:nativestrict` and verifies each link before the test continues.

## 0.33.0

### Added

- **Transactional `init` and `sync`.** Before either command changes managed files, AgentSync now creates a complete snapshot under the Git-ignored `.ai/backups/` store. If the operation fails midway, it automatically restores the exact pre-operation state, including removing destinations that did not exist before the run.
- **Manual rollback for accidental syncs.** `agentsync rollback` restores the latest snapshot, while `agentsync rollback <backup-id>` selects an older one. Use `rollback --list` to inspect available snapshots, `--dry-run` to preview every restore/remove action, and `--yes` for non-interactive recovery. Every rollback first creates its own safety snapshot, so the rollback can itself be undone.

### Changed

- **Bounded, low-noise backup lifecycle.** Successful operations retain the latest 10 complete snapshots by default; set `AGENTSYNC_BACKUP_LIMIT` to another non-negative value or `0` for unlimited history. Dry runs, fresh `sync --if-stale` calls, drift-preflight failures, and isolated `agentsync check` runs do not create snapshots.
- **Recovery covers the full managed write set.** Tool and profile destinations, disabled-tool cleanup targets, `.ai/.sync-manifest`, and AgentSync's `.gitignore` block are restored together. Arbitrary side effects from trusted `post_sync` hooks outside declared destinations remain outside the rollback boundary.

### Security

- **Snapshot restore stays inside the project.** Backup creation and rollback reject the repository root, the backup store itself, paths outside the repository, path traversal, and symlink escapes. Incomplete snapshots are ignored, metadata pointers are replaced atomically, and nested destinations are collapsed before copying.

## 0.32.0

### Added

- **First-class Kimi Code target.** AgentSync now syncs project instructions with inline rule references, native skills, commands as `command-*` skills, and canonical MCP configuration into Kimi Code's project layout. Kimi's built-in agents and global-only hooks remain outside project sync.
- **Complete OpenCode agent-layer target.** OpenCode now receives project instructions, inline rule references, skills, native commands, portable subagents converted to safe OpenCode Markdown, settings, canonical MCP, and an AgentSync-owned project plugin for hooks.
- **Ownership diagnostics for composed OpenCode configuration.** `sync`, `doctor`, and `adopt` now surface conflicting settings/MCP sources and multi-source outputs explicitly instead of silently choosing an owner.

### Changed

- **Canonical MCP now composes into OpenCode atomically.** The shared `mcpServers` map is validated, converted to OpenCode's local/remote schema, and merged into the top-level `mcp` field while preserving unrelated settings. A per-tool canonical MCP override still takes precedence over the shared source.
- **Tool support documentation now separates coding tools from model providers.** Kimi Code is documented as a standalone target, while Kimi models and GLM/Z.AI provider setups continue to use the target for their host tool. The documented ownership boundary excludes credentials, UI preferences, arbitrary OpenCode extensions, and Kimi's global runtime home.

### Security

- **Portable OpenCode subagents keep unknown tools denied by default.** Permission conversion grants only recognized portable tools; misspelled or unsupported tool names can no longer broaden a generated subagent's access.

## 0.31.0

### Added

- **Per-target category opt-out.** Set `targets.<category>.enabled: false` in a tool YAML to skip that category while continuing to sync the tool's other outputs. This is especially useful for `base:` profile variants that should inherit most destinations but let another config own one category.

### Fixed

- **Shell auto-sync now runs only at an AgentSync project root.** The `chpwd` hook previously walked up from every descendant to the nearest `.ai/src`, repeatedly checking the same parent workspace on ordinary navigation and resurfacing its drift errors. It now syncs only when the current directory itself contains `.ai/src`.

## 0.30.0

### Security

- **Post-sync hooks now require an out-of-repo trust signal.** A `post_sync` hook runs arbitrary shell from a tool YAML, and it used to be enabled by `post_sync.allow: true` in the project's own `.ai/agent_sync.yaml` — so cloning an untrusted repo and running `agentsync sync` could execute its hook. Enabling a hook now requires a signal outside the synced repo: `AGENTSYNC_ALLOW_POST_SYNC=true`, or `post_sync.allow: true` in the install-dir `config.yaml`. The in-repo `post_sync.allow` is no longer honored. `post_sync.skip: true` in the project file still disables hooks (skip only ever removes capability). **Action:** if you relied on in-repo `post_sync.allow`, export `AGENTSYNC_ALLOW_POST_SYNC=true` or set it in the global config.

### Fixed

- **Glob filters no longer collapse against the working directory.** `include`/`exclude` globs were word-split unquoted, so a pattern like `*.md` was expanded against the run's cwd (the project root) before matching. When the tested filename was absent from the cwd the real pattern was dropped — rules were silently skipped and previously-synced outputs swept. The split now runs with pathname expansion disabled (same fix in the inline-list YAML and frontmatter-tools parsers).
- **Empty/filtered rule sets no longer abort a merge.** `merge_rules_to_file` iterated an unguarded array; on bash 3.2 under `set -u` an empty array is a fatal "unbound variable", and it fired after the destination file was removed, so an empty rules dir could delete the old output and abort before the manifest was written (causing false drift on the next sync). The dead, same-bug `copy_rules` helper was removed.
- **No more spurious "Kept"/"Removed" churn on shared and nested destinations.** Two tools sharing a skills dir (Codex + Antigravity both write `.agents/skills`) made the non-generating tool warn `Kept …` for the other's generated `command-*` skills, and an AGENTS file written into a rules dir (`.amazonq/rules/00-context.md`) was swept then re-copied every run. The reserved `command-*` namespace is now always excluded from the skills sweep, and no sweep prunes a file the same run already wrote.
- **Generated command/agent TOML and Amazon Q JSON now escape quotes and backslashes**, so a `name`/`description` containing `"` no longer produces an unparseable file.
- **Deleting a source `.md` now removes its generated TOML/JSON.** The command/agent converters had no differential cleanup, so an orphaned `.toml`/`.json` lingered forever; they now sweep obsolete generated files (preserving user-added files, like the rules sync).
- **A misconfigured per-tool source no longer aborts the whole run.** A missing source (e.g. a typo'd `targets.rules.source`) made the copy/sync helpers return non-zero, which under `set -e` killed the entire run mid-pass — before the manifest was written — so later tools went unsynced and the next sync reported false drift. A missing source now logs its existing warning and is skipped; the run continues and finalizes normally.

### Changed

- **Faster sync.** Removed hot-path `$(...)` forks in the tool-config resolver (`get_tool_value_r` sets `REPLY` instead of echoing) and memoized the profile-tool lookup once per run. On an 11-tool sync this cuts user+sys CPU ~9% on macOS (larger on Git Bash/Windows, where forks cost more); output is byte-identical.

## 0.29.0

### Added

- **`agentsync adopt --all`:** batch-adopt every drifted (manually-edited) generated file back into `.ai/src/` in one pass, instead of naming each file. It scans the sync manifest for drift, previews the plan, and after a single confirmation promotes each edit and refreshes the manifest so the next `sync` is drift-free. Transformed targets that single-file `adopt` already refuses (header-injected rules, merged/inlined files, TOML/JSON-converted commands/subagents) are skipped and listed. When two edited outputs resolve to the same source with different content — e.g. `CLAUDE.md` and `GEMINI.md` both mapping back to `.ai/src/AGENTS.md` — both are skipped rather than one silently clobbering the other, so you adopt the intended file explicitly. Honours `--dry-run` and `--yes`.

## 0.28.5

### Changed

- **Disabled tools no longer clutter `sync` output:** a run where most tools are off used to print a `Skipping X (disabled)` line (and a blank line) for each one, burying the tool that actually synced under a wall of near-identical blocks. Skipped tools — disabled or excluded via `--only`/`--skip` — are now collected silently and reported once as a single `Skipped: a, b, c` line beside the final summary. A disabled tool whose stale output is actually removed still logs that cleanup.

## 0.28.4

### Changed

- **Readable `sync` logs:** every source→destination line now prints paths relative to the project root instead of absolute (`.ai/src/rules/ → .claude/rules/` rather than `/Users/you/.ai/src/rules/ → /Users/you/.claude/rules/`), with a `~`-relative fallback for paths outside the project. This drops the repeated home-directory prefix that pushed long lines onto a wrapped second row, so a global sync from `$HOME` is far easier to scan. Display only — what gets synced is unchanged.

## 0.28.3

### Fixed

- **`agentsync update` no longer misreports a moved tag as a network error:** when an upstream release tag had moved, the `--tags` fetch refused to overwrite the stale local copy and aborted the whole update with a misleading "Check your network connection". The install mirrors upstream and never owns tags, so the fetch now force-syncs them; a genuine fetch failure prints git's real error instead of always blaming the network.

### Changed

- **Releases are published as tags only:** the GitHub Release workflow has been removed, so cutting a version no longer creates a noisy GitHub Release entry. The annotated git tag still carries the CHANGELOG section as its message, and `agentsync update` continues to discover and pull new versions from tags — the update flow is unchanged.

## 0.28.2

### Changed

- **`shell-init` now recommends the `eval` form:** the help, README, and bundled skill now point to `eval "$(agentsync shell-init zsh)"` in your rc file rather than appending a frozen copy with `>>`. Eval-ing regenerates the hook from `agentsync` each session, so upgrades and fixes apply automatically without re-editing your rc (the same pattern as direnv/starship/zoxide). Appending the snippet directly still works for anyone who prefers to avoid the per-session call.

## 0.28.1

### Fixed

- **`shell-init` no longer breaks zsh on `cd`:** the auto-sync hook installed by `agentsync shell-init` ran an internal `cd`, which — being a zsh `chpwd` hook — re-triggered itself and aborted every directory change with `maximum nested function level reached`. The hook now points the sync at the project via `AGENTSYNC_REPO_ROOT` instead of `cd`-ing, and guards against re-entry. If you installed the hook from 0.28.0, remove the old block from your rc file and re-run `agentsync shell-init zsh >> ~/.zshrc`.

## 0.28.0

### Added

- **Auto-sync on directory change — `agentsync shell-init`:** prints a shell hook (`shell-init zsh|bash`, shell auto-detected from `$SHELL`) that runs `agentsync sync --if-stale` for the nearest `.ai/` project whenever you `cd` into it — and when you open a shell there — so generated rules/skills stop going stale between edits across many projects. It is a silent no-op when nothing changed, so it costs nothing in already-synced directories. Append it once: `agentsync shell-init zsh >> ~/.zshrc`. Set `AGENTSYNC_NO_AUTO_SYNC=1` to disable without removing the snippet.
- **`agentsync sync --if-stale`:** a cheap staleness probe that runs a full sync only when a source input is newer than `.ai/.sync-manifest`, and otherwise exits silently. It is the primitive the shell and pre-commit hooks build on, safe to call on every prompt.
- **`agentsync setup-hooks --pre-commit`:** optionally installs a pre-commit hook that runs `sync --if-stale` before each commit.

### Fixed

- **Git hooks now actually sync in real projects:** `setup-hooks` previously wrote a hook body that only invoked the in-repo `lib/sync.sh` or a `dart` wrapper, so in a normally installed project the `post-merge` / `post-checkout` hooks silently did nothing. They now call the installed `agentsync` binary (falling back to the in-repo engine), and every hook is non-fatal — a failed sync warns but never blocks the git operation.

## 0.27.2

### Changed

- **Faster `sync`:** the sync engine does the same work with about half the process forks. Manifest hashing now runs as a single batched pass instead of one `sha256sum` per file (drift-check and write), per-tool config lookups resolve without per-call subshells, hot-loop `basename`/`dirname` calls use Bash parameter expansion, and the enabled-tools set is computed once per run rather than per tool. Generated output is byte-identical and `agentsync check` still passes; an 11-tool sync runs roughly 1.6× faster.

## 0.27.1

### Fixed

- **`--help` on argument-less subcommands:** `agentsync check|setup-hooks|doctor|list|show|diff|disable|resolve --help` now prints the top-level usage instead of mis-reading `-h`/`--help` as a positional argument.
- **`copy_rules` refuses to delete an empty destination:** rule sync now aborts with a clear error instead of running `rm -rf` against an empty `dest_dir`, guarding against wiping an unintended directory.

### Changed

- **Drift-abort message points to `adopt`:** when `sync` aborts because a generated file was changed out of band (e.g. a plugin writing into `.claude/settings.json`), the guidance now suggests `agentsync adopt <file>` to pull the change into `.ai/src/`, alongside the existing move-to-source and `--force` options.

## 0.27.0

### Added

- **`paths:`-scoped rules now translate to every tool's native trigger:** a rule that declares `paths:` frontmatter (a list of globs) is emitted with each tool's _scoped_ trigger instead of the always-on header — Cursor `globs` + `alwaysApply: false`, Copilot `applyTo`, Windsurf/Antigravity `trigger: glob`, while Claude keeps `paths:` verbatim — so a domain rule (state, routing, data…) loads only when matching files are touched, keeping the always-on context lean. Configured via the new `targets.rules.scoped_header` option (a header string with a `{globs}` placeholder); rules without `paths:` still get the always-on `header`. Tools that inline rules into their agents file now skip a rule's frontmatter when building the index, so a scoped rule shows its heading rather than the `---` delimiter.
- **`doctor` flags always-on rule bloat:** a new advisory under a "Rules" section warns when the always-on rule set (rules without `paths:`) grows past ~20 KB / ~5k tokens, since a large always-on set dilutes attention and agents start ignoring individual instructions. Advisory only — like other techdebt detections it prints `⚠` but never affects the exit code.

## 0.26.3

### Changed

- **`agentsync add mcp` merges `mcp.json` without python3:** the shared MCP source is now edited in pure Bash + awk instead of an embedded python3 script. Previously the command hard-exited with "python3 is required to edit mcp.json safely" on any machine without python3 — contradicting AgentSync's zero-runtime-dependency guarantee. The new merge is string-, escape-, and brace-depth-aware, so it preserves existing servers (including arbitrary nesting) and JSON-escapes values correctly. Server entries are now written one per line (compact JSON values); an existing `mcp.json` reflows to that shape the next time you run `add mcp`.

### Fixed

- **Docs match the shipped behavior:** corrected the `agentsync adopt` refused-target lists (header tools are cursor/copilot/windsurf/antigravity, only zed merges rules into one file, and the inline set is codex/gemini/junie for rules plus amazonq/cline/zed for skills), removed a reference to a non-existent `sync --cleanup` flag, and fixed the `agentsync update` description (it runs a background check on each interactive run, not a 24h timer). Surfaced `--profile` in `sync --help` and the workspace forwarded-options list. Added a Profiles section to the README and refreshed the bundled `agentsync` skill — and its shipped template — for current tool coverage, `add mcp`, and the per-tool override layout.

## 0.26.2

### Fixed

- **Windows: text files check out with LF so frontmatter parsing works:** a `.gitattributes` (`* text=auto eol=lf`) now pins LF line endings on every platform. On Windows (Git Bash), `core.autocrlf` checked text files out as CRLF, and the frontmatter parsers match `/^---$/` exactly — a `---\r` delimiter never matched, so description extraction returned empty and broke the command-rendering paths (Codex `command-*` skills, Amazon Q / Zed inline "## Commands" sections). Scripts and the `.md` templates/fixtures the parsers read now check out LF identically on macOS, Linux, and Windows.

## 0.26.1

### Fixed

- **`agentsync update` self-heals local install-dir drift instead of failing:** when the global install (`~/.agentsync`) had a local edit to a tracked file that an incoming release also touched, the underlying `git pull` aborted ("Your local changes would be overwritten by merge") and the real git error was hidden — you saw only a generic "git pull failed, try reinstalling" message. `update` now reconciles the install dir toward the release: local edits to tracked files are set aside into a recoverable stash (`git stash list`), the update fast-forwards to the fetched release, and a diverged history is reset onto it. Untracked files (`.update_cache`) and the conflict snapshot (`.snapshot/`) are left intact, and the run reports when edits were set aside. The install dir mirrors a release, not a working branch, so reconciling toward it is the intended behavior.

## 0.26.0

### Changed

- **Sync preserves hand-placed files in generated dirs:** `agentsync sync` no longer treats a tool's output directory as fully sync-owned. Previously, a file you added by hand to a generated dir (e.g. `.claude/rules/my-own.md`) was silently deleted on the next sync because it wasn't regenerated from `.ai/src/`. Sync now consults the manifest: an extraneous entry it never generated is kept — with a per-file warning and a run-summary tally ("Preserved N user-added file(s)…") — instead of removed. The file is still _unmanaged_; move it into `.ai/src/` to manage it, or run `agentsync sync --force` to restore the old prune-everything behavior. Manifest-unaware callers keep their previous semantics, so only real sync runs change.

### Fixed

- **`profile add` scaffolds a README instead of empty overlay dirs; `--adopt` dereferences symlinks:** `agentsync profile add` no longer pre-creates empty `rules/`/`skills/` overlay directories (clutter git can't track anyway) — it writes a self-documenting README at the overlay root and creates content dirs on demand. With `--adopt`, an existing `~/.<tool>-<name>/` directory is now copied with `cp -RL`, so symlinked plugin skills are dereferenced into real files and broken links are skipped rather than copied dangling.
- **`snapshot_save` rejects empty target directories:** an empty `snapshot_dir` made the internal cleanup target a bare `/tools` path. Both `install_dir` and `snapshot_dir` are now validated and the function returns early on either being empty.

## 0.25.0

### Added

- **List form for `include` / `exclude` filters:** `targets.<resource>.include` and `targets.<resource>.exclude` now accept a YAML list — block style (one `- glob` per line) or inline `[a, b]` — in addition to the original space-separated scalar. Long filter lists (e.g. preserving plugin-managed skills) become one glob per line instead of a single wide string. Read via the new layered `get_tool_filter` resolver; existing scalar configs are unchanged.

## 0.24.0

### Added

- **`agentsync profile` — config-home profiles for per-account tool variants:** a profile fans one source tree out into a second, self-contained config-home directory for the same tool — e.g. a work `~/.claude-hub/` (run with `CLAUDE_CONFIG_DIR=~/.claude-hub`) alongside your personal `~/.claude/` — each with its own content. `agentsync profile add <name> [--tools a,b] [--adopt]` scaffolds, per tool, a thin variant config `.ai/src/tools/<tool>-<name>.yaml` (declaring `base: <tool>` to inherit every unset field, with config-home `targets.*.dest`), an overlay dir `.ai/profiles/<name>/src/` for profile-only rules/skills/commands/agents, and a `profiles:` block in `agent_sync.yaml`. `agentsync profile list` and `agentsync profile remove <name>` round out the lifecycle. Use `--adopt` to pull an existing `~/.<tool>-<name>/` directory into the overlay before the first sync.
- **`agentsync sync --profile <name>`:** sync personal tools plus the named profile; a plain `agentsync sync` also syncs every profile marked `active: true`. Each profile renders with a per-profile source overlay (`.ai/src/` base ⊕ `.ai/profiles/<name>/src/`, profile wins on path conflicts), composing on top of an active `shared:` overlay. Profile outputs are gitignored and drift-protected like any other output.
- **`base:` tool field:** a tool config may declare `base: <tool>` to inherit every field it does not set (formats, extensions, inline flags) and the base tool's `settings`/`mcp`/`hooks` templates from another tool. This backs profile variants but is available to any custom tool that wants to extend a shipped one.

## 0.23.3

### Fixed

- **`sync` and `init` refuse to run from inside the `.ai/` source directory:** running either command while the working directory was inside `.ai/` (e.g. `cd project/.ai && agentsync sync`) rooted the engine at the source tree, so `sync` wrote tool outputs _under_ `.ai/` and `init` created a nested `.ai/.ai/` — instead of generating at the project level alongside `.ai/`. Both commands now detect this, stop with exit code `2`, and point you at the project root (the parent of `.ai/`): `cd "<project>" && agentsync sync`. The new `ai_dir_enclosing_root` helper in `lib/helpers/paths.sh` backs the guard. No change for runs started from the project root.

## 0.23.2

### Added

- **Git rule and commit skill now forbid AI-attribution trailers:** `lib/templates/rules/git.md` and `lib/templates/skills/commit/SKILL.md` (and this project's own `.ai/src/` copies) gain an explicit instruction barring `Co-Authored-By:`, `Generated with …`, and tool/model signatures from commit messages — a commit records the human author only. The Claude `settings.json` template already sets `includeCoAuthoredBy: false`, but that knob is Claude-specific; the other ten tools have no equivalent, so the prohibition lives in the synced rules where every tool reads it. Existing projects pick it up via `agentsync refresh`; new projects get it on `init`. No change to the sync engine.

## 0.23.1

### Fixed

- **Templates no longer ship an invalid `model: "default"` pin (regression from 0.23.0):** 0.23.0 replaced the hardcoded `model: sonnet`/`opus` in the Claude `settings.json` template and subagent scaffolds with the literal `model: "default"`. Claude Code reads that literal as a nonexistent custom model — it surfaces as a "Custom model" in `/model` and errors on operations like `/compact` ("the selected model (default) may not exist"). The correct way to express "use the recommended default model" is to **omit** the `model` field entirely (the `/model` "Default" option clears the key rather than writing a value). 0.23.1 drops the `model` field from `lib/templates/settings/claude.json`, `lib/templates/agents/code-reviewer.md`, `lib/templates/content/subagent.md`, and the `agentsync generate` prompt, so scaffolds inherit the account default. Existing projects: run `agentsync refresh` to pick up the corrected templates, and remove any `"model": "default"` line a 0.23.0 scaffold wrote into `.claude/settings.json` or a subagent's frontmatter.

## 0.23.0

### Changed

- **Shipped templates stop pinning a model in scaffolds:** the Claude `settings.json` template (`lib/templates/settings/claude.json`) and the subagent scaffolds (`lib/templates/agents/code-reviewer.md`, `lib/templates/content/subagent.md`, and the `agentsync generate` prompt) drop the hardcoded `model: sonnet`/`opus` so new projects inherit the account's recommended model instead of a pinned snapshot. (0.23.0 set the field to `model: "default"`, which Claude Code rejects as an unknown model; corrected in 0.23.1 to omit the field.) Projects that deliberately pin a model through a `.ai/src/tools/<tool>/` override are unaffected; the skill's cost-saving guidance to pin `sonnet`/`haiku` for focused subagents still stands as an opt-in.

- **`prompt-engineering` skill updated for Claude Opus 4.8:** the tool-specific notes now treat Opus 4.8 as the current most-capable GA model — it builds on 4.7 with no breaking API changes (the carried-over behavioral notes still apply), `effort` defaults to `high` (set `xhigh` for coding), the 1M context window is served by default, and mid-conversation `role: "system"` messages are accepted. The pinned-snapshot example moves from `claude-opus-4-7` to `claude-opus-4-8`, and carried-over behavior labels shift from `4.7` to `4.7+`. Surfaces on existing projects via `agentsync refresh`; new projects get it on `init`. No change to the sync engine.

- **README and bundled best-practices reference brought back in line with the engine:** the README "Supported Tools", "Format Conversions", "Key Fields", and CLI command tables now match the actual `lib/templates/tools/*.yaml` configs and `bin/agentsync.sh` — corrected Junie (`.junie/AGENTS.md` + inlined rules, skills dir), Cursor (`commands`), Windsurf (`workflows`, `hooks`), Amazon Q (`mcp`, `cli-agents` MD→JSON), Gemini/Codex/Zed (`settings`) targets; documented the `amazonq_json` subagent converter; added the 12 previously-undocumented commands (`enable`, `disable`, `add`, `customize`, `simplify`, `show`, `diff`, `resolve`, `export`, `import`, `upgrade-config`, `release`); and fixed the tool count to 11. The vendored `knowledge/best-practices.md` is on the Claude Opus 4.8 guidance.

## 0.22.0

### Changed

- **Google Antigravity output moved from `.agent/` to `.agents/`:** the Antigravity CLI's workspace output directory changed from `.agent/` (singular) to `.agents/` (plural) to match its current plugin convention. `lib/templates/tools/antigravity.yaml` and the example project now write `rules`, `skills`, and `commands` under `.agents/`. The `agents` target stays at the canonical root `GEMINI.md`. Existing projects pick up the new layout on the next `agentsync sync`; the old `.agent/` directory is now treated as pre-v0.6 legacy and surfaced by `agentsync doctor` / `migrate` for cleanup.

- **`doctor` and `migrate` no longer protect `.agent/` when antigravity is enabled:** the dual-purpose guard added in 0.20.2 (treat `.agent/` as live Antigravity output when antigravity is in `tools.enabled`) is removed. With Antigravity's path now `.agents/`, the guard would shield stale `.agent/` directories from cleanup — the opposite of what the user wants on a transitional project. `.agent/` is once again pure pre-v0.6 legacy regardless of tool enablement; `doctor` advises on it and `migrate --apply --yes` removes it. The shared-`.agents/` orphan check in doctor was extended to skip when antigravity is enabled (it already skipped for codex).

## 0.21.0

### Added

- **`targets.commands.as_skills`:** new per-tool YAML option that emits each `.ai/src/commands/<name>.md` as a generated skill at `<targets.skills.dest>/command-<name>/SKILL.md` for tools without a native slash-command surface. Codex CLI is the headline beneficiary — its built-in slash commands are hardcoded and OpenAI explicitly recommends skills as the replacement, so AgentSync's project-local commands now reach Codex through `.agents/skills/command-*/` automatically. Generated skills regenerate frontmatter (`name: command-<name>`, description carried over) and rewrite Claude-flavoured slash sugar (`$ARGUMENTS` → `<arg>`, leading `` !` `` → `` ` ``) into prose the skill reader can use. The `command-` prefix avoids collisions with native skills of the same name — `release` and `command-release` coexist as separate dirs. Enabled by default in the base template for Codex; toggle with `agentsync customize codex` and override `commands: { as_skills: false }`.

- **`targets.commands.inline_into_agents`:** parallel option for tools that lack BOTH a native commands surface AND a skills dir (Amazon Q, Zed). Appends a `## Commands` index to the agents-like file (or to the merged rules file when `rules.merge_to_file: true`) with one ``- `/<name>` — <description>`` line per command. Enabled by default for Amazon Q (`.amazonq/rules/00-context.md`) and Zed (`.rules`).

- **`agentsync doctor` per-tool config conflict checks:** doctor now warns when a tool mixes `targets.commands.dest`, `.as_skills`, and `.inline_into_agents` — only one wins in sync, the others are silently ignored. Also warns when `as_skills: true` is set without `targets.skills.dest`, or `inline_into_agents: true` without `targets.agents.dest`, since both options would no-op.

- **`agentsync sync` info line for fallback modes:** when sync emits commands as skills or inlines them into AGENTS.md (rather than copying to a native commands dir), it now prints a one-line explanation so first-time users understand why their `.ai/src/commands/` lands in an unexpected destination.

### Changed

- **`matches_filter` now accepts space-separated patterns:** `include` and `exclude` in YAML can list multiple globs separated by spaces (e.g. `exclude: "draft-*.md tmp-*.md"`); the filter matches if ANY pattern matches. Single-pattern usage is unchanged.

- **`sync_dir` cleanup honors `exclude`:** files in the destination directory that match the caller's `exclude` glob are no longer swept as extraneous. This lets a second sync step (e.g. `sync_commands_as_skills`) safely own a subset of the destination without the primary `sync_dir` call deleting its output on each run.

- **`--help` / `-h` flag now works on `agentsync customize`, `enable`, `add`, `show`, `diff`:** previously these subcommands rejected `--help` as "Unknown flag". Each now prints a usage block with flags, positional args, and a one-line summary of what the command does.

## 0.20.4

### Fixed

- **`agentsync init` and `refresh` now copy nested skill subdirectories:** previously `init` shallow-copied each skill via `cp "$skill_dir"*` (no `-R`), and the `find` walks under `skills/` in `refresh`, `dedupe`, `doctor`, and the template-manifest healer were limited to `*.md` / `*.markdown`. Skills that ship companion content under `references/` or `scripts/` (e.g. `prompt-engineering/references/agent-persona.md`, `humanizer/references/wikipedia_signs_of_ai_writing.md`) were silently dropped on `init` and never picked up by `refresh` — the user got a `SKILL.md` that linked to files which weren't on disk. The `init` copy now iterates entries and uses `cp -R` so subdirectory layouts survive, and the four `find` walks now match every non-hidden file under `skills/` (`! -name '.*'`) instead of just markdown. `refresh` will now offer the missing nested files as NEW on existing projects; new projects get the full skill tree on `init` automatically.

## 0.20.3

### Changed

- **Humanizer skill expanded:** added a "Matching a sample" section so the skill calibrates to a user-provided writing sample when one is supplied (matching sentence-length patterns, paragraph openings, recurring word choices, and punctuation habits instead of defaulting to the skill's house voice). New pattern entries cover tailing negation fragments (", no guessing," ", no wasted motion," tacked onto a sentence end), persuasive authority tropes ("The real question is," "At its core," "Fundamentally"), signposting and self-narration ("Let's dive in," "Here's what you need to know"), elegant variation (synonym cycling for the same noun within a passage), and fragmented headers (a heading followed by a one-line restatement of the heading before the real content begins). The final-pass checklist gains a fourth meta-audit step that asks the model to name remaining AI tells in the draft — too-symmetrical rhythm, slogan-y closers, placeholder-sounding names — and rewrite those specific spots. Surfaces on existing projects via `agentsync refresh`; new projects pick up the refined content automatically on `agentsync init`. No behavioural change in the sync engine.

## 0.20.2

### Fixed

- **`agentsync dedupe` now honors `shared.path` symmetric with `doctor` 0.20.1:** in a monorepo where some sub-projects have their own `.git`, `dedupe` without `--against` silently skipped them because git-bounded walk-up stopped at their boundary. The `--workspace` mode doesn't accept per-project `--against`, so the workaround was a manual `cd subproj && dedupe --against ../` fan-out that defeats the point of `--workspace`. After 0.20.1, users could rely on `doctor` to catch governance drift across the whole workspace, but their natural next step — clean it up with `dedupe` — fell back into the asymmetry that `doctor` had just escaped. `dedupe` now resolves the parent via `shared.path` first (matching how the sync-time overlay and `doctor` already cross repo boundaries), and falls back to git-bounded walk-up only when `shared:` isn't declared. `--against` keeps winning over both. The "Parent:" line gains a `(from shared.path)` hint when the override took effect, mirroring `doctor`'s output. Applies to both single-project and `--workspace` modes — `--workspace` in particular now correctly dedupes every sub-project that declared `shared.path` regardless of git topology.

- **`agentsync doctor` no longer flags `.agent/` as legacy when Google Antigravity is enabled:** doctor's `Tool outputs` section unconditionally treated `.agent/` (singular) as the pre-v0.6 monolithic layout that needed cleanup. But `.agent/` is also Google Antigravity's current canonical output directory — same path, completely different meaning. With antigravity enabled, the false-positive advisory pollutes `OK with N advisory(ies)` summaries and conditions users to ignore the entire section. The check now skips when `antigravity` is in `tools.enabled`; without it, the legacy detection works as before.

- **`agentsync migrate` no longer destroys Google Antigravity output:** the same `.agent/` collision had a more dangerous form on the migrate side — `migrate --apply --yes` would delete the directory because `_migrate_has_legacy_agent_dir` returned true regardless of tool enablement. A user running migrate in a script after enabling Antigravity would erase live tool output silently. Migrate now applies the same enablement check as doctor: with antigravity enabled, `.agent/` is treated as managed output and left alone; with antigravity disabled, the existing legacy detection and cleanup paths still run. As a corollary, `_migrate_prepare_context` now resolves `PROJECT_CONFIG_PATH` (the same way `_doctor_prepare_context` does) so the enablement check can actually read the project config — previously migrate was missing this setup entirely, which silently broke any helper that depended on it.

## 0.20.1

### Fixed

- **`agentsync doctor` now honors `shared.path` as a cross-project parent override:** in a workspace where some sub-projects share `.git` with the parent and others have their own `.git`, doctor previously flagged governance divergence in the former but stayed silent in the latter — even though both opted into the same `shared:` declaration. Walk-up correctly stops at the git boundary as an auto-detection safety guard, but it shouldn't override an explicit user declaration. Doctor now resolves the parent via `shared.path` first (matching how the sync-time overlay already crosses repo boundaries), and falls back to git-bounded walk-up only when no `shared:` is declared. The "Parent source:" line gains a `(from shared.path)` hint when the override took effect, so it's clear which mechanism resolved the parent. Existing behaviour without `shared:` is unchanged — the git-boundary guard still prevents doctor from comparing unrelated repos during auto-detection. `agentsync dedupe` was not affected by the bug because it already exposes `--against PATH` as an explicit escape hatch.

## 0.20.0

### Added

- **`agentsync dedupe` — interactive cross-project duplicate cleanup:** new command that compares this project's `.ai/src/` against a parent project's `.ai/src/` (auto-detected by walking up to the first parent containing one, bounded by the git repository boundary so it never escapes the current repo). For each shared path it shows either an identical-hash duplicate (offer to delete from this project) or a divergent file (show diff and let the human decide — dedupe never auto-resolves a divergence). For files that originated as shipped templates, the deletion is paired with a `template_overrides.declined` entry so `refresh` won't re-offer the file. Manual duplicates that aren't shipped templates are deleted without a manifest entry — declined is a template-only mechanism, and writing dangling entries for non-template files would break refresh's lookup semantics. Three modes: default (compare against the walked-up parent), `--against PATH` (compare against an arbitrary `.ai/src/` or project root), and `--workspace` (bottom-up alphabetical fan-out across every `.ai/` below cwd; each child is deduped against its own nearest parent). Non-interactive use via `--yes` deletes identical-hash files but never picks a side on divergent ones. Empty parent skill directories left behind after deletion are pruned automatically so the tree doesn't accumulate empty `skills/<name>/` shells after their `SKILL.md` is removed.

- **`agentsync sync --workspace` — recursive fan-out across nested projects:** new flag that runs `sync` in every `.ai/` below the current directory, in bottom-up alphabetical order (deeper paths first, siblings sorted by `LC_ALL=C` for reproducible output across runs and machines). Continue-on-failure: a broken sub-project doesn't abort the loop; the run reports the max exit code at the end. All other sync options (`--only`, `--skip`, `--dry-run`, `--force`) forward to each per-project invocation. Replaces the manual `cd msd && sync && cd ../resume && sync && ...` shell loops that workspace users had been writing by hand. A bare `.ai/` directory without `src/` or `agent_sync.yaml` is skipped — only AgentSync-managed trees are picked up, so unrelated `.ai/` directories from other tooling don't pollute the loop.

- **`agentsync doctor` — cross-project, orphan-output, and empty-skill detection:** doctor gains three new sections. **Cross-project** compares the project's source files against a walked-up parent `.ai/src/` (same walk-up as `dedupe`, bounded by git repository), flagging identical-hash duplicates as advisories and divergent files as info — `category: governance` files (see below) are upgraded from info to advisory with explicit "likely a mistake, not an override" framing. **Tool outputs** flags any `.claude/`, `.cursor/`, `.codex/`, etc. directory whose owning tool isn't enabled in this project (orphan from a prior run after the tool was disabled, or a leftover from a different project copy-pasted into the tree), plus the legacy `.agent/` (singular) layout from before v0.6 — that directory was never cleaned up by `sync` because the current engine doesn't know it exists. **Skills** flags skill directories that lack a `SKILL.md` (a no-op artifact that lists nowhere and dispatches nothing). All three detections use a new **advisory tier** that displays as a yellow ⚠ but does not increment `DOCTOR_WARNINGS` and does not change the exit code — so users who run `doctor` in pre-commit hooks or CI pipelines get the techdebt nudge without breaking the build. Hard errors (missing `.ai/`, invalid YAML) still exit 2; warnings (legacy `enabled: true`, version drift, manual edits since last sync) still exit 1; the new techdebt category is exit-0 by design.

- **`shared:` resources — declarative inheritance from a parent `.ai/src/`:** new optional section in `agent_sync.yaml` that lets a nested project pull source files from its parent at sync time. Syntax is intentionally minimal — no YAML parser changes — using inline CSV for the inherit list:

  ```yaml
  shared:
    path: "../"
    inherit: rules,skills,commands,agents
  ```

  At sync, AgentSync builds a transient shadow `.ai/src/` tree under a temp directory: child's own files first, then parent files in inherited categories filling in any path the child doesn't already have (child wins on path collisions — overlay never overwrites local content). Sync then reads from the shadow tree so every enabled tool — including ones without parent-loading (Codex, Cursor, JetBrains Junie, etc.) — receives the inherited content materialized into its own output. The shadow tree is read-only from the child's perspective and is torn down via an EXIT trap, so there's no on-disk state to manage. **Manifest interaction is deliberately one-sided:** `.template-manifest` continues to track only files actually present in the child's `.ai/src/`; inherited files are not in the manifest and are never offered by `refresh` — they belong to the parent. This is the design point that came out of the v1 → v2 architectural review: a single state mechanism, no "inherited" flag bag, no second source of truth that can drift out of sync with the first. When `doctor` finds a same-path duplicate in an inherited category, it appends `(inherited via shared: — safe to delete)` to nudge users toward deletion — once deleted, parent will continue to provide the content via overlay on every subsequent sync.

- **`category:` frontmatter field — declaration of intent for rules and skills:** optional `category:` in any YAML frontmatter (rules, skills, commands, agents). Today only `governance` carries behavior — when `doctor` finds a child file that diverges from its parent's same-path version and the parent file has `category: governance`, the message escalates from info ("review intent") to advisory ("governance file diverges from parent — likely a mistake, not an override"). Other category values (`domain`, `workspace`, `project`) are accepted and recorded but currently informational; future tooling can build on them without forcing existing projects to migrate. Designed so adding a category to an existing template is a non-breaking, opt-in declaration.

- **`agentsync refresh --status` — declined breakdown:** new flag that prints the full list of declined templates and exits, split into **Persistent** (entries in `template_overrides.declined` in `agent_sync.yaml`) and **Local** (entries in `.template-manifest` whose file is missing on disk). Useful for users with many accumulated overrides who want to see what's declined without scanning the YAML by hand or running `--include-deleted` (which has different semantics — it re-offers the files for restoration). Returns 0 with no output if nothing is declined.

- **`agentsync migrate` — legacy `.agent/` (singular) detection and cleanup:** migrate now recognizes the pre-v0.6 monolithic `.agent/` layout (a single directory holding `AGENTS.md`, `workflows/`, `rules/`, `skills/` without per-tool separation). The current engine doesn't know about it, so `sync --cleanup` never sweeps it. Dry-run lists the contents so the user can confirm before removal. `--apply --yes` removes the directory; `--apply` without `--yes` on a non-TTY leaves it in place with a hint (conservative: never silently remove user content). Detection runs alongside the existing flat-layout `.ai/src/{hooks,mcp,settings}/` move logic, so a single `migrate --apply --yes` cleans up both in one pass.

### Changed

- **`agentsync refresh` up-to-date output splits declined sources:** when the run is a no-op, the summary now reports `Persistently declined (agent_sync.yaml): N file(s)` and `Locally declined (.template-manifest): M file(s)` as separate lines, and appends `Pass --status for the full list.` when either count is non-zero. Replaces the single ambiguous `N file(s) previously declined` line from 0.16.0 that conflated the two sources — relevant for users who have accumulated entries in both the persistent override list (which `--include-deleted` ignores) and the local manifest (which `--include-deleted` revisits).

- **`agentsync doctor` exit-code semantics — new advisory tier never breaks CI:** doctor's existing errors (exit 2) and warnings (exit 1) keep their current behavior. The new techdebt detections (cross-project duplicates, orphan tool outputs, empty skills, legacy `.agent/`) live in a third tier that prints as a yellow ⚠ but does not increment `DOCTOR_WARNINGS` and does not affect the exit code. The summary line now reports `OK with N advisory(ies)` when only advisories were found. Lets users wire `doctor` into pre-commit / CI gates without legacy techdebt forcing a fail-on-warning policy to be relaxed — the cleanup nudges are visible during interactive runs but invisible to automation.

## 0.19.0

### Removed

- **Aider, Augment Code, and Continue support dropped:** the three lowest-traffic tool integrations are gone — `lib/templates/tools/{aider,augment,continue}.yaml`, the matching `lib/templates/settings/{aider,continue}.yaml` base settings, the auto-detect markers in `agentsync init`, the README tool table rows, the conversion-matrix rows, the knowledge index sections, and the bats assertions all removed. Rationale: market data through April–May 2026 shows Aider sitting on a small terminal-only niche, Continue having pivoted away from rules-as-files toward CI checks (so its sync surface no longer matches the AgentSync model), and Augment serving an enterprise-only compliance audience that doesn't bootstrap via `curl | bash`. Maintaining all three was costing ~15–20% of the per-release tool-config surface for a sliver of real users. Existing projects with `aider`, `augment`, or `continue` entries in `.ai/src/tools/` will see those tools silently skipped on the next `sync` — no error, just no output written. Users who still want one of these tools can keep their tool YAML in `.ai/src/tools/` (the sync engine is config-driven and will continue to honour a project-local file), or copy the last shipped version from git history (`git show 0.18.0:lib/templates/tools/aider.yaml`) into their own project as a custom integration.

### Changed

- **Rule and skill templates rewritten for clarity:** `lib/templates/AGENTS.md`, `lib/templates/rules/{comments,core,git}.md`, and most of `lib/templates/skills/*/SKILL.md` (agentsync, comments, commit, debug, humanizer, prompt-engineering, refactor, review) trimmed and sharpened — same constraints, shorter lines, tighter examples, fewer redundant "what to avoid" lists collapsed into single positive-form statements. Surfaces via `agentsync refresh` on existing projects (the manifest will offer the updated files); new projects pick up the refined content automatically on `agentsync init`. No behavioural change in the sync engine.

## 0.18.0

### Changed

- **`agentsync refresh` — `[s]kip` on a conflict is now remembered:** 0.16.0 left `[s]kip` on a CONFLICT deliberately unrecorded, so every subsequent refresh re-prompted for the same file until the user resolved or pinned it. In practice, that meant a tree with a handful of intentionally diverged rules surfaced the same wall of conflicts on every refresh — friction that pushed users toward editing `template_overrides.pinned` by hand to silence the noise. `[s]kip` now records the current template hash in `.ai/.template-manifest`, so the divergence stays silent on future refreshes until a newer template ships (at which point the conflict resurfaces automatically against the new content — you never lose visibility of a real update). The post-skip confirmation reads `skipped (remembered — agentsync refresh --review to revisit)` so the new behavior is discoverable from the prompt itself. `template_overrides.pinned` in `agent_sync.yaml` remains the stronger, unconditional pin (never resurfaces, even when the template moves) — `[s]kip` is now the lightweight "remember until something changes" choice that handles the common case.

### Added

- **`agentsync refresh --review` — revisit remembered skips and local edits:** new flag that resurfaces every local divergence from the shipped templates, including conflicts you previously `[s]kipped` and files you've edited locally since the last refresh. Use it to revisit earlier decisions ("did I really mean to skip that?"), audit local edits against the upstream templates, or sweep through divergences in batch. `template_overrides.pinned` still wins — pinned files stay silent even under `--review`, so the YAML override remains the definitive way to opt out forever. Pairs with the new "skip is remembered" behavior: on a normal refresh, silently-kept files don't clutter the summary; on a `--review` refresh, they're listed as conflicts with the same `[u]pdate / [s]kip / [v]iew / [q]uit` prompts. Under `--yes`, surfaced conflicts are reported but never overwritten — keeps the existing CI-safety guarantee that `--yes` never makes a destructive choice on a divergence.
- **`agentsync refresh` summary hint when files differ silently:** the summary block (and the `Already up to date!` no-op message) now appends `· N silently kept (local edits or earlier skips) — pass --review to revisit` whenever the classifier finds files that match the manifest baseline but diverge from the template. Makes the new flag discoverable without forcing users to read `--help`, and quietly nudges users who have accumulated local edits to do an audit pass.

## 0.17.0

### Added

- **`humanizer` skill bundled with init templates:** `lib/templates/skills/humanizer/SKILL.md` plus a `references/wikipedia_signs_of_ai_writing.md` reference and a deterministic `scripts/strip-ai-chars.sh` cleanup script now ship with `agentsync init`, so freshly bootstrapped projects inherit a ready-to-use skill for rewriting AI-flavored prose (and for generating long-form deliverables — blog posts, essays, newsletters, op-eds, short stories — in the same plain, grounded voice from the first draft). The skill triggers on humanize / de-AI / de-slop requests in any language, on prose-deliverable asks, and explicitly skips code, casual chat, and technical documentation. Guidance is language-agnostic: instead of an English-only banned-word list, the skill teaches the underlying principle (swap any word that sounds inflated, abstract, or official compared to how a person would actually say the thing for the plain everyday equivalent) and lets the model apply it in whatever language the piece is in. Detection criteria cover punctuation tells (em/en dashes, semicolons, framing colons, mid-paragraph bold), inflated vocabulary (utilize, leverage, delve, tapestry, robust, multifaceted, etc.), structural tics (forced triads, contrastive negation, pivot transitions, significance inflation, empty intensifiers, metaphor verbs, fiction tropes, sycophantic openers, chatbot closers), and rhythm/format issues (monotone medium-length sentences, bullets that should be prose). The `references/wikipedia_signs_of_ai_writing.md` companion is a condensed reference distilled from Wikipedia's "Signs of AI writing" so the skill stays under its primary context budget while keeping the full detection catalog one read away.
- **`scripts/strip-ai-chars.sh` — deterministic typographic cleanup:** ported from the MIT-licensed [humanize-ai-lib](https://github.com/Nordth/humanize-ai-lib), this `perl -CSDA -pe`-driven filter takes text on stdin and writes a cleaned version to stdout. It strips zero-width and bidi-control watermarks (the invisible characters often used to fingerprint AI output), C0/C1 controls, tag-character watermarks (U+E0000–E007F), and decorative Unicode blocks no keyboard produces (math alphanumerics, arrows, math operators, box/block drawing, enclosed alphanumerics, dingbat bullets). It also normalizes the visible-but-AI-tell punctuation that the prose pass would otherwise have to catch by ear: non-breaking spaces collapse to regular spaces, en/em dashes become hyphens, curly/guillemet quotes become straight quotes, smart apostrophes become straight apostrophes, ellipsis characters become three dots, and trailing whitespace is trimmed. Idempotent and dependency-free beyond Perl (preinstalled on every macOS / Linux / Git Bash environment AgentSync supports), so the skill's prose pass can focus on rhythm and word choice while the script handles the deterministic character-level cleanup.

## 0.16.0

### Added

- **`agentsync refresh` — three-way diff via `.ai/.template-manifest`:** the manifest is a content-addressed record (one `<rel-path>\t<sha256>` line per file, LC_ALL=C sorted) of every template file copied into `.ai/src/` via `init` or accepted via `refresh`. `init` now writes a baseline on every fresh scaffold; `refresh` reads it and routes each template through three-way diff (template-old vs template-new vs user-current), so the file-classification graph becomes much richer than 0.15.0's two-way (NEW / CONFLICT / UNCHANGED). New states: **AUTO_UPDATE** — user untouched + template moved → applied silently without a prompt (the big UX win for users who are several CLI versions behind: a project with 12 unchanged-by-user templates and 4 user-edited ones now sees 12 silent auto-updates and only 4 interactive conflicts, instead of 16 indistinguishable conflict prompts); **USER_EDITED_NO_CHANGE** — user edited locally + template static → silent (their custom version stays, no nag); **DELETED** — file removed locally that was once scaffolded → treated as an intentional decline and silent (pass `--include-deleted` to revisit). Skipping a NEW prompt now records a manifest entry, so a declined-by-skip template isn't offered again on subsequent refreshes — pass `--include-deleted` to revisit them. Skipping a CONFLICT deliberately does **not** record, preserving the "unresolved divergence" signal until the user accepts or pins it. Backward compatibility is preserved: projects without a manifest fall back to two-way diff (every divergence is a CONFLICT, `--yes` skips), and the first refresh on such a project heals the manifest from currently-matching files so subsequent refreshes get full three-way semantics without forcing a wall of accepts. Commit `.ai/.template-manifest` to git so the team shares the same baseline; otherwise different developers will see different conflict sets.
- **`template_overrides` in `agent_sync.yaml` — persistent skip and pin:** two new optional lists silence specific templates forever. `template_overrides.declined: [rel/path/to.md, ...]` makes refresh ignore those templates entirely (never surfaced, never offered, even with `--include-deleted`). `template_overrides.pinned: [rel/path/to.md, ...]` accepts that the user maintains a divergent version and suppresses the conflict prompt on those files (template moves silently, user's version stays). Read-only in this revision — users edit the YAML directly to mark overrides; an interactive write-from-prompt is deferred to a future release. Closes the UX gap where every refresh kept asking about the same skipped files.
- **`agentsync refresh --include-deleted`**: surfaces files the user removed locally so they can be restored. Lists them in the dry-run plan and offers per-file `[a]dd / [s]kip / [v]iew / [q]uit` prompts in interactive mode. Under `--yes` they remain skipped — restoring a previously-declined file is a deliberate choice that should not happen by default in a non-interactive run. Lets users recover from accidental `rm` or revisit a template they earlier dismissed without remembering exactly which one.
- **`lib/helpers/template_manifest.sh`**: new module mirroring `lib/helpers/manifest.sh`'s shape (parallel `TEMPLATE_MANIFEST_KEYS` / `TEMPLATE_MANIFEST_VALUES` arrays, sha256 via `sha256sum` or `shasum -a 256`, atomic write via temp + `mv`, `LC_ALL=C sort -u` for byte-stable output). Pure bash 3.2, zero external deps beyond coreutils. Exposes `template_manifest_load` / `_lookup` / `_record` / `_write` plus `template_manifest_heal_from_match` — the helper that `init` and `refresh` both use to populate manifest entries for files that already match the current template (lets v0.15.0-era projects upgrade to three-way diff without re-accepting every file).

### Changed

- **`agentsync init` writes `.ai/.template-manifest`**: after scaffolding source content, init now records the template hash for every file it copied. This is the baseline that `refresh` needs to do three-way diff. The behavior is fully backward compatible — pre-0.16 projects without a manifest get two-way diff on their first refresh (with `--yes` skipping conflicts), then the manifest is healed from matches and subsequent refreshes get three-way semantics.

## 0.15.0

### Added

- **`agentsync refresh` — pull template updates into an existing `.ai/src/`:** new command that walks the shipped templates (rules, skills, commands, agents) and compares each file against the project's `.ai/src/`. New templates are offered for adding; modified files show a unified diff so the user can update or skip per file. Files in `.ai/src/` that aren't part of the templates (the user's custom rules/skills) are left alone. Closes the long-standing gap where users had no path to inherit template additions (e.g. the `comments` rule/skill from 0.14.0) or rewrites (e.g. the positive-form rewrite from 0.13.0) without re-running `init` from scratch — `init` refuses on existing trees by design, and `import` only knows how to pull from external bundles, not from the locally installed templates. Behavior is safety-first throughout: default action on Enter is **skip** (never auto-accept a conflict), `--yes` adds new files but skips conflicts (CI-friendly; conflicts must be reviewed manually), non-TTY without `--yes` errors with a hint, and the default scope is auto-detected from existing subdirectories so refresh respects the categories the user originally chose at `init --content`. AGENTS.md is excluded by default (almost always heavily customized; opt-in via `--include-agents-md`). Tool configs (`settings/`, `mcp/`, `hooks/`, `tools/`) are intentionally excluded — they have their own `customize` / `simplify` / `resolve` flow. Flags: `--only <csv>` to scope to specific categories (or opt into a category not yet in the tree), `--dry-run` to preview the plan, `--yes` for non-interactive use, `--include-agents-md` to surface AGENTS.md, `--help`. Documented in the `agentsync` skill template under "Pulling new template content into an existing project". 18 bats tests cover the full matrix (clean tree, conflict, --dry-run, --only, --include-agents-md, scope auto-detection, custom-files preservation, idempotency, non-TTY error, unknown values, `--only=value` syntax, nested skill references).

## 0.14.0

### Added

- **Commenting guidance baked into init templates:** `lib/templates/rules/comments.md` (always-on rule) and `lib/templates/skills/comments/SKILL.md` (on-demand skill) now ship with `agentsync init`, so freshly bootstrapped projects inherit a single language-agnostic policy on when to comment and what to leave out. The rule frames the default as "code over commentary" — make the code self-explanatory first, then comment only the _why_ a reader can't see (hidden constraints, external quirks, workarounds, surprises). The skill layers in two contrasting code blocks (narration / AI-thought-trail anti-pattern → contract-doc-plus-quirk pattern) and an `Edge cases` list covering apologies-in-code, task/PR/caller references, untracked TODOs, line-by-line code translation, decorative banners, and commented-out blocks. Both files are written in imperative-positive form consistent with 0.13.0's template rewrite, so Claude Opus 4.6+/4.7 follows them more reliably than the equivalent `Don't` lists. Addresses the recurring failure mode where Opus leaves `// Step 1:`, `// loop through users`, `// AI thought:` narration scattered through generated code.

## 0.13.0

### Changed

- **Templates and prompts rewritten in positive form:** every rule template, skill template, and the `agentsync generate` prompt (`lib/templates/AGENTS.md`, `lib/templates/rules/*`, `lib/templates/skills/agentsync/SKILL.md`, `lib/templates/skills/prompt-engineering/{SKILL.md,references/*}`, `lib/prompts/generate.md`) now phrase constraints as required behaviors instead of `Don't` lists, `## Anti-Patterns`, or `## What Not To Do` sections. Aligned with Anthropic's prompt-engineering guidance — Claude Opus 4.6+/4.7 follow positive instructions ("respond in flowing prose") more reliably than prohibitions ("don't use bullet points"), and over-comply with aggressive `MUST/NEVER/CRITICAL` framing. Section headers map predictably (`## Anti-Patterns` → `## Discipline`, `## What Not to Commit` → `## Keep Out of Commits`, `## What Never Goes In` → `## Keep Out of History`), and the bullet rewrites preserve the same constraints in imperative-positive form. `agentsync generate` and the `agentsync` skill itself now teach this pattern, so freshly bootstrapped projects inherit it.

### Added

- **`prompt-engineering` skill — Opus 4.7 specifics:** the Claude entry under `Tool-specific notes` expanded from a single line into a structured sub-section covering effort levels (`low / medium / high / xhigh / max`) with defaults for coding and agentic work, the `thinking: {type: "adaptive"}` syntax that replaces deprecated `budget_tokens`, subagent-spawning behavior changes on 4.7, tool-use undertriggering, the more-direct tone shift, the persistent cream/serif/terracotta frontend default and how to override it, and the deprecation of prefilled assistant messages on 4.6+. Lets maintainers tune prompts that were authored against earlier Opus versions without re-reading the full Anthropic guide.
- **`prompt-engineering` skill — three new snippets** in `references/snippets.md`:
  - `Frontend variety — propose options before building`: replaces the lost `temperature` knob for design variation on Opus 4.7 (which has a persistent default house style) by having the model propose 4 distinct directions before committing.
  - `Subagent control`: dual-direction guidance for steering subagent fan-out — reining in 4.6's over-spawning on trivial tasks, and prompting 4.7 (which spawns fewer by default) to delegate when it should.
  - `Multi-context-window workflow`: extends the existing state-tracking snippet with concrete patterns from Anthropic's agentic guidance — `init.sh` setup script, structured `tests.json`, freeform `progress.txt`, git checkpointing, and the fresh-context recovery sequence (`pwd` → progress notes → tests → git log → integration test) before resuming work.

## 0.12.3

### Fixed

- **`agentsync add` headings:** scaffolded rule/skill/subagent files now derive the top-level `# Heading` from the kebab-case name (`code-reviewer` → `# Code Reviewer`) instead of emitting the raw lowercase identifier (`# code-reviewer`). Matches the heading convention used by every built-in skill (`# Commit`, `# Code Review`) so freshly added files don't need a manual rename pass.

## 0.12.2

### Fixed

- **`agentsync update` silently exited with code 1:** if the `VERSION` file had no trailing newline, `read -r VERSION < VERSION` returned 1 (EOF without `\n`), and `set -euo pipefail` killed the script before a single character reached the terminal — `agentsync update` looked like it was hanging or doing nothing. `bin/agentsync.sh`, `update`, and `release` now tolerate a newline-less `VERSION` and fall back to the previous value if the read fails. The repo's `VERSION` file is also rewritten with a trailing `\n` so existing installs heal on the next pull.

## 0.12.1

### Fixed

- **`agentsync add` skill/subagent frontmatter:** scaffolded `SKILL.md` and `agents/<name>.md` files now emit YAML-safe frontmatter — `name` values are quoted and `description` uses a folded block scalar (`>-`). Previous templates broke YAML parsers (and downstream tooling that lints frontmatter) whenever the description contained a colon, quote, parenthesis, or multilingual example. The `add` substitution maps the new sentinel names (`"content"`, `"template-agent"`) back to the user-provided name on top of the existing `{{NAME}}` rewrite, so the templates themselves stay parseable on disk before substitution.
- **`agentsync generate` prompt:** the AI prompt that bootstraps `.ai/src/` now instructs the model to emit the same YAML-safe frontmatter (`name: "..."`, `description: >-`) for skills, commands, and subagents, plus a final reminder to mentally validate every generated file before output. Stops the generated bundle from landing with frontmatter that fails to parse the moment a description contains punctuation.

## 0.12.0

### Added

- **Drift detection** (`.ai/.sync-manifest`): every successful `sync` now writes a content-addressed manifest — one SHA-256 hash per generated file, sorted, no timestamps. On the next run, AgentSync compares each destination against the manifest before writing. If a dest was edited manually since the last sync (typical IDE-iteration flow: tweak `.claude/rules/foo.md` directly while testing), `sync` aborts with the list of edited files instead of silently overwriting them. Commit `.ai/.sync-manifest` to git so CI catches a forgotten commit. Pass `--force` to discard the edits and rewrite from source. `doctor` adds a Drift section that lists each tracked file as ✓ in-sync, ⚠ edited, or ⚠ missing. `check` keeps its existing semantics (regenerate fresh in a temp tree, diff against the repo) — drift is caught by the diff step there.
- **`agentsync adopt <dest-file>`**: reverse of sync — promote a manual edit in a generated file back into `.ai/src/` as the new canonical content, then refresh the manifest entry so the next `sync` is drift-free. Resolves the destination through the same YAML targets `sync` uses (so `.claude/rules/core.md` → `.ai/src/rules/core.md`, `.claude/settings.json` → `.ai/src/tools/claude/settings.json`). Settings/MCP/hooks scaffold the canonical per-tool override path when none exists yet, matching the 0.11 layout. Supports `--dry-run` (unified diff + plan, no writes), `--yes` (skip TTY confirm), and refuses transformed targets up front (`cursor` rules with header injection, `merge_to_file` / `inline_into_agents` variants, `format=toml` / `format=amazonq_json` outputs) — the round-trip would corrupt the shared source.

### Changed

- **`sync --force`**: new flag bypasses the drift check and rewrites every dest from source. Existing behavior of `sync` (write everything) becomes the explicit `--force` path; the default is now drift-aware.
- **`check` runs sync with `--force` internally**: the in-temp regenerate-and-diff loop is unchanged for users; the flag prevents drift detection inside the temp tree from short-circuiting the diff that produces the actual "out of sync" report.

## 0.11.2

### Fixed

- **`local x="$(...)"` masking subshell exit codes in `customize` / `list`:** the `_show_payload` source-label resolution and the `cmd_list` shared-MCP hint both initialized `local` variables from a command substitution on the same line, which silently swallows the subshell's exit status (ShellCheck SC2155). Split into separate declaration + assignment so a failing color/format helper now surfaces under `set -e` instead of leaving the caller with a half-built label.
- **Unused `label` read in `doctor` secret scan:** `_doctor_scan_file` parsed a `label` field from each secret pattern but never used it, so a malformed pattern row was harder to diagnose. Dropped the dead read; behaviour unchanged.

## 0.11.1

### Changed

- **`init` `Next steps` now points at `agentsync generate`:** the post-init summary previously listed only `list` / `enable` / `sync`, leaving newcomers to discover the AI-assisted bootstrap flow on their own. The new step ("Run `agentsync generate` — print an AI prompt to tailor `.ai/src/` to your codebase") sits right after the `AGENTS.md` edit hint, so a fresh project can go from `init` → AI-generated rules/skills without reading the README first.
- **`generate` clipboard tip is now platform-aware:** the trailing "Tip: run `agentsync generate | pbcopy`" hint hardcoded macOS's `pbcopy`, which prints noise on Linux where the binary doesn't exist. `generate` now probes `pbcopy` → `wl-copy` → `xclip -selection clipboard` → `xsel --clipboard --input` and prints the tip only when one of them is available, so Linux users see the right command and headless environments see no tip at all.

## 0.11.0

### Added

- **Per-tool override layout** (`.ai/src/tools/<tool>/<resource>.<ext>`): all tool-specific payloads (settings, hooks, per-tool MCP) live alongside their tool YAML under a single directory, so customizing a tool no longer scatters files across `.ai/src/{hooks,mcp,settings}/`. The resolver reads the new path first and falls back to the legacy flat layout for backward compatibility.
- **Shared MCP source** (`.ai/src/mcp.json`): one file describes the MCP servers every enabled tool should receive. Sync propagates it as `.mcp.json` / `.cursor/mcp.json` / etc., matching each tool's destination. Per-tool overrides (`.ai/src/tools/<tool>/mcp.json`) still win for the rare cases that need a different map.
- **`agentsync add mcp <server>`**: append (or create) an MCP server entry in the shared `.ai/src/mcp.json` without hand-editing JSON. Supports `--url`, `--command`, `--args`, `--env`, `--force`, and validates the merge with `python3`.
- **`agentsync migrate`**: moves legacy flat-layout overrides to the canonical per-tool layout (`mv` per file, dry-run by default, `--apply` to persist). When every legacy `.ai/src/mcp/*.json` is byte-identical it offers to consolidate them into the shared `.ai/src/mcp.json` (accept in TTY with `Y`, in non-TTY with `--yes`).
- **`enable <tool>` scaffolds editable copies**: after adding a tool to `tools.enabled`, `enable` copies the base settings / hooks templates into `.ai/src/tools/<tool>/` so the user has a concrete file to edit. MCP is deliberately not scaffolded — it resolves through the shared file. Pass `--no-scaffold` to opt out, `--scaffold` to force. TTY users get a single `Scaffold editable copies for <tool>?` confirm; non-TTY defaults to scaffold.
- **`enable` edit-paths block**: after enabling, each tool now prints a short block pointing at exactly which file to edit (`.ai/src/tools/<tool>/settings.json`), where shared MCP lives, and which commands unlock the rest (`agentsync customize <tool> hooks`, `agentsync add mcp`).
- **`doctor` Edit paths section**: lists each enabled tool with `✓` for existing overrides and `·` for payloads still inheriting from base, with the exact `customize` / `add mcp` command to materialize them.
- **`update` migration banner**: after pulling a 0.11+ release into a project still on the flat layout, `update` prints a banner pointing at `agentsync migrate --apply` so nothing silently breaks on a future release.

### Internal

- **Shared edit-paths formatter** (`lib/helpers/edit_paths.sh`): `enable` and `doctor` both reach through a single `tool_edit_paths_rows` helper for "what can the user edit for this tool?" instead of each maintaining its own resolution logic. Two thin formatters (`_block` for enable, `_checklist` for doctor) hang off it. Side effect: the `enable` block no longer prints a phantom `.ai/src/mcp.json` path when the shared file doesn't exist yet — it points at `agentsync add mcp <server>` directly.

### Changed

- **`init` `Next steps` now advertises the customization surface** (`agentsync add mcp <server>` and `agentsync customize <tool> <resource>`) so new users discover shared MCP and per-tool overrides without digging into the README.
- **`doctor` legacy-layout warning** now points at `agentsync migrate --apply` instead of suggesting re-running `customize` per file.
- **`resolve_payload_source` resolution order** (canonical as of 0.11): `.ai/src/tools/<tool>/<resource>.<ext>` → explicit `targets.<resource>.source` in the tool YAML → `.ai/src/<resource>/<tool>.<ext>` (legacy, emits one-shot deprecation warning) → `.ai/src/mcp.json` (for MCP only) → shipped base template.

### Migration

- Legacy flat-layout overrides (`.ai/src/{hooks,mcp,settings}/<tool>.<ext>`) are still read; sync continues to work unchanged. A one-line warning prints per run when a legacy file is the effective source. `agentsync migrate --apply` moves every legacy file into the canonical per-tool layout and, when safe, consolidates identical MCP copies into `.ai/src/mcp.json`. Legacy paths will be removed in 0.12.
- Projects wanting to opt out of the new `enable` scaffolding (e.g. CI provisioning scripts) should append `--no-scaffold` to their `agentsync enable` invocations.

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
