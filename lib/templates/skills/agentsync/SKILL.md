---
name: agentsync
description: Create or edit AgentSync configuration — AGENTS.md, rules, skills, commands, subagents, settings, MCP servers, hooks, or per-tool configs. Use this skill when adding a rule, creating or scaffolding a skill, writing a slash command, defining a subagent persona, editing permissions, configuring an MCP server, setting up the `.ai/src/` directory, or running `agentsync sync` / `add` / `customize` / `resolve` / `simplify` / `profile` — even when the user does not name "AgentSync" explicitly but is editing files in `.ai/src/`, `.claude/`, `.cursor/`, or another tool-config directory.
---

# Working with AgentSync

Create and maintain AI agent instructions in the AgentSync format.

## Structure

```
.ai/src/                        # Source of truth. Edit ONLY here.
├── AGENTS.md                   # Agent identity: role, approach, principles
├── rules/                      # Always-on constraints (one file per topic)
│   ├── core.md
│   └── testing.md
├── skills/                     # On-demand recipes (one directory per skill)
│   └── deploy/
│       └── SKILL.md
├── commands/                   # Custom slash commands (.md files)
│   ├── review.md
│   └── fix-issue.md
├── agents/                     # Subagent personas (.md files)
│   └── code-reviewer.md
├── mcp.json                    # Shared MCP servers — applied to every tool
└── tools/                      # Per-tool config and overrides
    ├── claude.yaml             #   tool config: dest paths, format options
    └── claude/                 #   per-tool payload overrides (opt-in)
        ├── settings.json       #     permissions / settings override
        ├── hooks.json          #     hooks override
        └── mcp.json            #     per-tool MCP override (shadows mcp.json above)
```

After editing, run `agentsync sync` to distribute to all tools.

Settings, hooks, and per-tool MCP are overrides: they only exist once you opt in (`agentsync enable`, `agentsync customize`, `agentsync add mcp`). When absent, AgentSync falls back to its shipped base templates. The flat `settings/`, `mcp/`, and `hooks/` directories from older layouts still work but are deprecated — `agentsync migrate` moves them into the per-tool form above.

## Scaffolding new content

Use `agentsync add <kind> <name>` to create a new file with the correct frontmatter and placement:

- `agentsync add rule <name>` — creates `.ai/src/rules/<name>.md`
- `agentsync add skill <name>` — creates `.ai/src/skills/<name>/SKILL.md`
- `agentsync add command <name>` — creates `.ai/src/commands/<name>.md`
- `agentsync add subagent <name>` — creates `.ai/src/agents/<name>.md`
- `agentsync add mcp <name> (--command CMD [--args '…'] [--env K=V,…] | --url URL)` — adds a server to the shared `.ai/src/mcp.json`

The command refuses to overwrite existing files; pass `--force` (or `-f`) to replace them. Names must contain only letters, digits, hyphens, and underscores — no path separators, no `..`, no leading `.` or `-`.

## Writing AGENTS.md

The agent's identity. Every sentence should change behavior.

- **Be specific** — "Senior React/TypeScript Engineer" not "software engineer".
- **Include the stack** — The agent needs to know what it's working with.
- **Actionable principles** — "Prefer composition over inheritance" not "Write good code".
- **Boundaries** — Call out hard limits as required behavior ("treat `db/migrations/` as append-only", "every endpoint goes through `auth.requireUser`"). Phrase positively when practical; reserve `do not` for cases where the wrong action is genuinely tempting.
- 40–70 lines. No generic filler.

## Writing Rules

Always-on constraints. One file per topic in `.ai/src/rules/`.

- **One concern per file** — `testing.md`, `security.md`. Not `everything.md`.
- **Imperative and specific** — "Use `snake_case` for DB columns" not "Follow naming conventions".
- **Constraints, not tutorials** — Tell the agent what behavior to produce. Skip concept explanations the model already knows.
- **Prefer positive instructions** — Per Anthropic's prompt-engineering guidance, "respond in flowing prose" works better than "don't use bullet points". Phrase rules as what to do; reserve explicit `do not` for genuinely tempting wrong actions where the positive form would lose information.
- **20–50 lines per file** — If it grows beyond that, split by topic. Multiple small focused files beat one large catch-all.
- **Always-on by default — scope domain rules with `paths:`** — A rule with no frontmatter loads on every task. For a domain rule (state, routing, data…), add `paths:` frontmatter (a list of globs) so it loads only when matching files are touched. AgentSync translates `paths:` to each tool's native trigger (Claude `paths:`, Cursor `globs`+`alwaysApply:false`, Copilot `applyTo`, Windsurf/Antigravity `trigger: glob`). Keep the always-on set lean — a wall of always-on rules dilutes attention and the agent starts ignoring individual instructions.

## Writing Skills — The Most Important Part

Skills are the highest-leverage configuration. AgentSync skills follow the open [agentskills.io](https://agentskills.io) format — a portable standard supported by Claude Code, Codex, Cursor, Copilot, Gemini CLI, OpenCode, and ~30 other agents. Validate with `skills-ref validate <path>`.

The **description is the trigger** — vague descriptions never activate. Be imperative ("Use this skill when…"), pushy (list cases where the user doesn't name the domain), and keyword-rich. Hard limit: 1024 chars.

The **directory layout** is `SKILL.md` + optional `references/` (load-on-demand docs), `scripts/` (executable code), `assets/` (templates). Keep `SKILL.md` ≤ 500 lines / ≤ 5000 tokens; move detail behind explicit triggers ("read `references/X.md` when Y").

**When creating or editing a skill in `.ai/src/skills/<name>/`, read [`references/writing-skills.md`](references/writing-skills.md)** — it covers the full agentskills.io spec, frontmatter constraints, structure templates, calibration principles (procedures-over-declarations, defaults-not-menus, match-specificity-to-fragility), reusable patterns (Gotchas, Templates, Checklists, Validation loops, Plan-validate-execute), and the iteration loop with evals.

**Rule of three:** don't create a skill for everything. Three manual repetitions, *then* a skill.

## Writing Commands

Custom slash commands. Each `.md` file in `.ai/src/commands/` becomes a command (e.g., `review.md` → `/project:review`).

```markdown
---
description: What this command does (shown in command list)
argument-hint: "<optional-arg>"
---

[Prompt content with instructions for the AI.]
```

Key features:

- `$ARGUMENTS` — replaced with text after the command name.
- `` !`shell command` `` — runs a shell command and embeds output into the prompt.
- Keep commands focused — one workflow per command.
- Good commands: `review`, `fix-issue`, `deploy`, `migrate`.

## Writing Agents (Subagent Personas)

Specialized AI personas in `.ai/src/agents/`. Each `.md` file defines an agent with its own system prompt and tool restrictions.

```markdown
---
name: code-reviewer
description: >
  Expert code reviewer. USE PROACTIVELY when reviewing PRs or validating implementations.
model: sonnet # Cheaper model for focused tasks
tools: [Read, Grep, Glob] # Restrict to read-only tools
---

You are a senior code reviewer...
```

Guidelines:

- Restrict `tools` to what the agent actually needs. Read-only agents shouldn't have Write.
- Use `model: sonnet` or `model: haiku` for focused tasks to save cost.
- Only create agents for distinct specializations — don't duplicate what skills already do.

## Settings & Permissions

Each tool ships with base settings. To diverge, scaffold an override with `agentsync enable <tool>` or `agentsync customize <tool> settings` — it writes `.ai/src/tools/<tool>/settings.json`, which wins over the base on sync. Delete the file to go back to inheriting the base.

Example `.ai/src/tools/claude/settings.json`:

```json
{
  "permissions": {
    "allow": ["Bash(npm run *)", "Read", "Write", "Edit"],
    "deny": ["Bash(rm -rf *)", "Read(.env)"]
  }
}
```

## MCP Configs

One shared `.ai/src/mcp.json` reaches every enabled tool, so you define a server once. Add servers with `agentsync add mcp <name>` or edit the file directly:

```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["-y", "@anthropic/mcp-playwright"]
    }
  }
}
```

When one tool needs a different server map, `agentsync customize <tool> mcp` creates `.ai/src/tools/<tool>/mcp.json`, which shadows the shared file for that tool only.

## Inline Options

For tools without separate rules/skills directories, use inline options:

- **`inline_into_agents: true`** (rules) — appends lightweight rule REFERENCES (name + title) to the agents file instead of syncing rules as separate files. Used by: Codex, Gemini, Junie.
- **`inline_into_agents: true`** (skills) — appends lightweight skill INDEX (name + description) to the agents file instead of syncing skills as directories. Used by: Junie, Cline, Amazon Q, Zed.
- **`as_skills: true`** (commands) — emits each `.ai/src/commands/<name>.md` as a generated skill at `<targets.skills.dest>/command-<name>/SKILL.md`. For tools that have a skills dir but no native slash-command surface. Requires `targets.skills.dest`. Used by: Codex.
- **`inline_into_agents: true`** (commands) — appends a `## Commands` index (one `` `/<name>` — description `` line per command) to the agents file. For tools that have neither a commands dir nor a skills dir. Requires `targets.agents.dest` (or `rules.merge_to_file` fallback). Used by: Amazon Q, Zed.
- **`prepend_agents: true`** (rules with `merge_to_file`) — prepends AGENTS.md content before merged rules in a single output file. Used by: Zed.
- **`00-context.md` pattern** — for directory-based tools without separate agents support, AGENTS.md is copied as `00-context.md` inside the rules directory. Used by: Amazon Q, Cline.

## Adding a New Tool

1. Copy `.ai/src/tools/_TEMPLATE.yaml` to `.ai/src/tools/<tool>.yaml`.
2. Set `name`, `enabled: true`, and configure `targets`.
3. Run `agentsync sync --only <tool>` to test.

## Maintenance: drift, resolve, simplify

`agentsync update` snapshots the tool catalog and reports upstream changes to fields you've overridden into `.ai/.pending-resolutions.yaml`. Run `agentsync resolve` to walk and adopt or reject each one. Pass `--strict` to `agentsync update` in CI to fail the build when conflicts exist.

`agentsync simplify` drops user-override fields that already match the current base, surfacing only true divergences. Dry-run by default; `--apply` to write, `-y` to auto-delete emptied files.

**When running `agentsync update`, `resolve`, or `simplify`, or when investigating stale-override / upstream-drift problems, read [`references/maintenance.md`](references/maintenance.md)** for full file format, command semantics, idempotency rules, comment-preservation gotcha, and recommended cadence.

**Recovering a directly-edited generated file.** `agentsync sync` records every generated file in `.ai/.sync-manifest` (SHA-256), so a generated file edited by hand — or one a tool writes into out of band (e.g. a plugin registering itself in `.claude/settings.json`) — makes the next sync **abort** instead of overwriting it. Run `agentsync adopt <file>` to pull the current content back into `.ai/src/`, then sync again.

## Pulling new template content into an existing project

`agentsync refresh` walks the shipped templates (rules, skills, commands, agents) and compares each file against your `.ai/src/`. Use it after upgrading the CLI to inherit newly added rules/skills without re-running `init`.

It uses **three-way diff** via `.ai/.template-manifest` (written by `init` and updated on every refresh): the manifest records the template hash at scaffold/last-refresh time, so refresh can tell whether you've touched a file since the last sync.

- **Auto-update (silent)**: file you haven't touched + template moved → applied without a prompt.
- **NEW (prompt)**: file present in templates, never seen locally — offered for adding. Default Enter is **skip**; skipping records a manifest entry so the file isn't offered again (use `--include-deleted` to revisit).
- **CONFLICT (prompt with diff)**: both your version and the template diverged from the recorded baseline. Default Enter is **skip**; your local edits are not overwritten unless you type `[u]pdate`.
- **DELETED (silent)**: you removed a file locally that was once scaffolded → treated as an intentional decline. Pass `--include-deleted` to revisit.
- **USER_EDITED_NO_CHANGE (silent)**: you edited locally, template hasn't moved → not a conflict, your version stays.
- **Custom files (silent)**: anything in your `.ai/src/` that isn't in the templates is your own and is left alone.

Persistent overrides in `.ai/agent_sync.yaml` silence specific templates forever:

```yaml
template_overrides:
  declined:        # always-skip; never offered
    - rules/some-rule.md
  pinned:          # ignore template updates; keep your version even when it diverges
    - rules/my-version.md
```

Other behaviors:

- Scope by default = only categories that already have a subdirectory in your `.ai/src/`; pass `--only rules,skills,commands,agents` to opt into a category you don't have yet.
- AGENTS.md is excluded by default (almost always heavily customized); `--include-agents-md` surfaces it.
- `--dry-run` prints the plan without writing. `--yes` applies auto-updates and adds new files non-interactively; conflicts are always skipped under `--yes` (CI-friendly).
- Tool configs (`settings/`, `mcp/`, `hooks/`, `tools/`) are intentionally excluded — they're handled by `customize` / `simplify` / `resolve`.
- Commit `.ai/.template-manifest` to git so the team shares the same baseline; otherwise different developers will see different conflict sets.

`agentsync refresh --status` prints the current declined breakdown without prompting — useful when many overrides have accumulated. The list is split into **Persistent** (entries in `template_overrides.declined`) and **Local** (entries in `.template-manifest` whose file is missing on disk).

## Workspaces and shared content

A parent project at `workspace/.ai/src/` with sub-projects below — each with its own `.git` and `.ai/src/` — is supported. Two patterns to manage content shared between layers; pick whichever fits the use case better. They compose, but typically you'll pick one per category.

**Declarative inheritance — `shared:` in `agent_sync.yaml`.** The child names a parent path plus the categories it inherits:

```yaml
shared:
  path: "../"
  inherit: rules,skills,commands,agents
```

At sync time, AgentSync builds a transient shadow `.ai/src/` (child files first, then parent fillers; child wins on path collisions) and points `SOURCE_*` at it. Sync then walks the shadow tree, so every enabled tool — including ones without parent-loading semantics (Codex, Cursor, Junie, Cline, Amazon Q) — receives the inherited content materialised into its own output. The shadow tree never touches disk outside `$TMPDIR` and is torn down via an `EXIT` trap. **Inherited files do not enter the child's `.template-manifest`** — refresh continues to consider only the child's own files; the parent owns its content.

**Interactive cleanup — `agentsync dedupe`.** When the child has copy-paste duplicates of parent files in its own `.ai/src/`, dedupe surfaces them by hash:

- Identical hash → `[d]elete / [k]eep / [v]iew` prompt. Deletion writes a `template_overrides.declined` entry when the file is a shipped template (so refresh won't re-offer it).
- Different hash → diff shown, decision left to the human; dedupe never auto-resolves a divergence.

Modes: default walks up to the nearest parent `.ai/src/` (bounded by the git repository boundary so it never escapes the current repo); `--against PATH` accepts an explicit `.ai/src/` or project root; `--workspace` runs across every nested `.ai/` below cwd in bottom-up alphabetical order.

**Detection — `agentsync doctor`.** Doctor's "Cross-project" section flags identical-hash duplicates as advisories and divergent files as info. Rules and skills with `category: governance` in their frontmatter are upgraded to advisories when divergent, with explicit "likely a mistake, not an override" framing. All cross-project findings are exit-code-0 advisories — visible during interactive runs, invisible to CI. Combine with `agentsync sync --workspace` for batch syncs across the tree.

**`category:` frontmatter.** Optional field on any rule/skill/command/agent. Today only `governance` carries behavior; `domain`, `workspace`, `project` are recorded but currently informational. Add it to a file when divergence between parent and child would be a mistake, not a deliberate override.

## Profiles (config-home variants)

A profile produces a second, self-contained config-home directory for a tool — e.g. a work `~/.claude-hub/` next to your personal `~/.claude/` (run it with `CLAUDE_CONFIG_DIR=~/.claude-hub`). Its content is the base `.ai/src/` overlaid with profile-only extras, so shared rules stay shared while work-specific rules/MCP live only in the profile. This is the right tool when you sync from `$HOME` and juggle multiple accounts/subscriptions per tool.

**Create one — `agentsync profile add <name>`.** Scaffolds, per enabled tool (or `--tools a,b`):

- a thin variant tool `.ai/src/tools/<tool>-<name>.yaml` — `base: <tool>` (inherits every unset field), `profile_home: ".<tool>-<name>"`, and config-home `targets.*.dest` (everything inside the home dir);
- an overlay dir `.ai/profiles/<name>/src/` — drop profile-only `rules/`, `skills/`, `commands/`, `agents/`, or `AGENTS.md` here (profile wins on path collisions with base);
- a `profiles:` entry in `agent_sync.yaml`:

  ```yaml
  profiles:
    hub:
      overlay: ".ai/profiles/hub"
      active: true
      tools: [claude-hub, codex-hub]
  ```

Pass `--adopt` to pull the existing contents of `~/.<tool>-<name>/` into the overlay first (rules/skills/commands/agents into the overlay, `.mcp.json`/`settings.json`/`hooks.json` into `.ai/src/tools/<variant>/`), so the first sync doesn't clobber a hand-built directory. Profile-specific MCP/settings/hooks live in that per-variant payload dir; everything else flows through the overlay.

**Sync.** `agentsync sync` syncs personal tools plus every `active: true` profile; `agentsync sync --profile <name>` syncs personal tools plus just that one. Each profile's tools render with a per-profile overlay layered over the base (and over an active `shared:` overlay, if any — the two compose). Profile outputs are gitignored and drift-protected like any other output.

**Inspect / remove.** `agentsync profile list` shows profiles, their tools, and config homes. `agentsync profile remove <name>` deletes the config-home output and variant files, then drops the `profiles:` entry (overlay sources under `.ai/profiles/<name>/` are kept).

## Other commands

- `agentsync list` shows configured tools and status; `agentsync enable` / `disable <tool>` toggle them.
- `agentsync check` verifies generated output matches source and exits non-zero on drift (use it in CI).
- **Keep outputs fresh automatically** (so you never forget to sync): add `eval "$(agentsync shell-init zsh)"` to `~/.zshrc` to auto-sync the nearest project whenever you `cd` into it (silent no-op when nothing changed; eval'ing keeps it current across upgrades); `agentsync setup-hooks [--pre-commit]` syncs on `git pull` / `checkout`; `agentsync sync --if-stale` syncs only when source changed since the last sync. See the README "Automation" section.
- `agentsync doctor` validates the setup and surfaces drift, config warnings, and cross-project advisories.
- `agentsync generate [context]` prints a prompt you paste into any AI to draft a project-specific `.ai/src/`.
- `agentsync export` bundles `.ai/src/` into an archive; `agentsync import <src>` pulls a config from a repo, archive, or directory.
- `agentsync migrate` moves legacy flat-layout overrides into the per-tool form.
- `agentsync upgrade-config` re-pins the engine version in `agent_sync.yaml`.

## Gotchas

- Always edit files in `.ai/src/`, never in generated directories (`.claude/`, `.cursor/`, etc.). A file you add by hand to a generated dir is preserved with a warning (not silently deleted) — but it is never managed; move it into `.ai/src/`, or run `agentsync sync --force` to prune it. If you edited a generated file while iterating, `agentsync adopt <path>` promotes that edit back into the matching source file — or `agentsync adopt --all` to promote every drifted file at once (refused targets and same-source conflicts are skipped and listed).
- Run `agentsync sync` after every change to distribute updates.
- Tool-specific frontmatter fields (like `context: fork`) are passed through as-is — agentsync doesn't validate them.
- Keep skill triggers mutually exclusive. When two skills could fire on the same task, merge them or sharpen their descriptions.
- Native commands land in Claude, Cursor, Copilot, Gemini (as TOML), Junie, Cline, Windsurf, and Antigravity. Tools without a command surface get a conversion: Codex emits a generated skill under `command-*/`; Amazon Q and Zed inline a `## Commands` index into their agents file.
- Native subagents land in Claude, Copilot, Cursor, Gemini, and Junie. Codex receives them converted to TOML and Amazon Q as custom-agent JSON. Cline, Zed, Windsurf, and Antigravity have no subagent surface, so they get none.
- The shared `.ai/src/mcp.json` reaches every tool; per-tool settings and hooks each have their own format under `.ai/src/tools/<tool>/`.
