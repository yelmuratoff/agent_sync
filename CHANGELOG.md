# Changelog

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
