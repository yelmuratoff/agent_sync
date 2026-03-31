# AgentSync System

This directory contains the sync engine that maps AI source files to tool-specific config layouts.

For authoring guidelines, see `.ai/README.md`.

## Inputs and Outputs

### Source inputs (defaults from `config.yaml`)

```yaml
source:
  agents: ".ai/src/AGENTS.md"
  rules: ".ai/src/rules"
  skills: ".ai/src/skills"
  tools: ".ai/src/tools"
```

`sync.sh` also supports:

- Flat layout auto-detection:
  - `.ai/AGENTS.md`
  - `.ai/rules`
  - `.ai/skills`
  - `.ai/tools`
- Project overrides via `<repo>/agent_sync.yaml`:
  - `source.agents|rules|skills|tools` (preferred)
  - `agents|rules|skills|tools` (flat keys)
- Optional override file via `AGENTSYNC_CONFIG_PATH`.

### Generated outputs

Outputs are defined per tool in source `tools/*.yaml` (path configurable via source settings).
Files prefixed with `_` (for example `_TEMPLATE.yaml`) are ignored during sync.

Enabled/disabled tool outputs are controlled by each file's `enabled` flag in `tools/*.yaml`.

## Commands

Run from repo root.

Full sync:

```bash
.ai/system/sync.sh
```

Preview only:

```bash
.ai/system/sync.sh --dry-run
```

Filter tools:

```bash
.ai/system/sync.sh --only claude,copilot
.ai/system/sync.sh --skip gemini
```

Install git hooks:

```bash
.ai/system/setup_hooks.sh
```

Installed hooks invoke `agentsync sync` (or `.ai/system/sync.sh` as fallback).

Validation helper:

```bash
.ai/system/check.sh
```

## `tools/*.yaml` Schema

Minimal:

```yaml
name: "Tool Name"
enabled: true
targets:
  agents:
    dest: ".tool/AGENTS.md"
  rules:
    dest: ".tool/rules"
  skills:
    dest: ".tool/skills"
```

All target types:

- `targets.agents` — identity file (AGENTS.md → tool-specific name)
- `targets.rules` — always-on constraints (per-file or merged)
- `targets.skills` — on-demand workflows (directory per skill)
- `targets.commands` — custom slash commands (.md files)
- `targets.subagents` — subagent personas (.md files)
- `targets.settings` — permissions/config (file copy, requires `source`)
- `targets.mcp` — MCP server configs (file copy, requires `source`)
- `targets.hooks` — event hooks (file copy, requires `source`)

Supported optional fields:

- `targets.agents.source`: override AGENTS source file
- `targets.rules.source`: override rules source directory
- `targets.rules.extension`: rename rule extension (example: `.mdc`, `.instructions.md`)
- `targets.rules.header`: prepend text to each rule file
- `targets.rules.include`: include glob for source rule file names
- `targets.rules.exclude`: exclude glob for source rule file names
- `targets.rules.append_imports`: append `@rules/...` lines into agents file
- `targets.rules.merge_to_file`: merge all rules into a single output file (e.g., Aider)
- `targets.rules.inline_into_agents`: append lightweight rule references (name + title) into agents file instead of syncing rules as separate files (Codex, Amp, Devin, Gemini)
- `targets.rules.prepend_agents`: prepend AGENTS.md content before merged rules in single-file output (Aider, Zed, Continue)
- `targets.skills.inline_into_agents`: append lightweight skill index (name + description) into agents file instead of syncing skills as directories (Junie, Cline, Amazon Q, Augment, Tabnine, Aider, Zed, Continue)
- `targets.skills.source`: override skills source directory
- `targets.skills.include`: include glob for skill folder names
- `targets.skills.exclude`: exclude glob for skill folder names
- `targets.commands.extension`: rename command file extension
- `targets.subagents.extension`: rename agent file extension (e.g., `.agent.md`)
- `targets.settings.source`: source file path (required)
- `targets.mcp.source`: source file path (required)
- `targets.hooks.source`: source file path (required)
- `post_sync`: shell command run after successful sync of that tool
  - by default disabled for safety; enable explicitly with `AGENTSYNC_ALLOW_POST_SYNC=true`

Reference template: `.ai/src/tools/_TEMPLATE.yaml`

## Sync Behavior

For each `tools/*.yaml` file:

1. Read `name`, `enabled`, and target paths.
   - `enabled` is required and must be a boolean scalar (`true/false`, `yes/no`, `on/off`, `1/0`).
2. If disabled, clean existing generated paths for that tool.
3. Apply CLI filters (`--only`, `--skip`).
4. Sync `agents` file (or as `00-context.md` for directory-based tools without separate agents support).
5. Sync `rules` with optional extension/header/filtering and differential cleanup.
   - If `inline_into_agents`: append lightweight rule references (name + title) to agents file instead.
   - If `merge_to_file` + `prepend_agents`: prepend AGENTS.md content before merged rules.
6. Sync `skills` directories with filtering and differential cleanup.
   - If `inline_into_agents`: append lightweight skill index (name + description) to agents file instead.
7. Sync `commands` (if configured).
8. Sync `subagents` (if configured, with optional extension rename).
9. Copy `settings` file (if configured, requires `source`).
10. Copy `mcp` file (if configured, requires `source`).
11. Copy `hooks` file (if configured, requires `source`).
12. Run optional `post_sync`.
13. After all tools, update generated block in `.gitignore`.

`post_sync` safety:

- default behavior skips post-sync commands
- set `AGENTSYNC_ALLOW_POST_SYNC=true` to allow execution in trusted repositories
- set `AGENTSYNC_SKIP_POST_SYNC=true` to force-disable post-sync (used by `check.sh`)

## `.gitignore` Integration

`sync.sh` rewrites the block between:

- `# --- AI SYNC GENERATED START ---`
- `# --- AI SYNC GENERATED END ---`

It inserts generated paths for all enabled tools and keeps the rest of `.gitignore` intact.

## Files in This Directory

```
.ai/system/
├── config.yaml           # Global source path mapping
├── sync.sh               # Main sync entrypoint
├── setup_hooks.sh        # Installs post-merge and post-checkout hooks
├── check.sh              # Verification helper
├── lib/
│   ├── files.sh          # Copy/sync/filter operations
│   ├── yaml.sh           # Lightweight YAML parser
│   ├── gitignore.sh      # Generated block updater
│   ├── logging.sh        # Logging utilities for sync engine
│   ├── cli_colors.sh     # CLI color helpers
│   ├── resolve.sh        # Path resolution (engine root, system dir)
│   ├── init.sh           # agentsync init command
│   ├── list.sh           # agentsync list command
│   ├── generate.sh       # agentsync generate command
│   └── update.sh         # agentsync update + update check
├── templates/            # Starter templates for init
│   ├── AGENTS.md
│   ├── rules/
│   ├── skills/
│   ├── commands/
│   ├── agents/
│   ├── settings/
│   └── mcp/
└── prompts/
    └── generate.md       # Prompt for agentsync generate
```

## Add a New Tool

1. Copy `.ai/src/tools/_TEMPLATE.yaml` to `.ai/src/tools/<tool>.yaml`.
2. Fill `name`, set `enabled: true`, and configure all target destinations.
3. Add optional transforms (`extension`, `header`, `include/exclude`) only if needed.
4. Run `.ai/system/sync.sh --only <tool>`.
5. Verify output and rerun full `.ai/system/sync.sh`.
