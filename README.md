<div align="center">
  <img src="https://github.com/yelmuratoff/agent/blob/main/assets/agent_sync.png?raw=true" width="400">

  <p>
    <a href="https://github.com/yelmuratoff/agent">
      <img src="https://img.shields.io/badge/shell-bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white" alt="Built with Bash">
    </a>
    <a href="https://opensource.org/licenses/MIT">
      <img src="https://img.shields.io/badge/license-mit-4EAA25?style=for-the-badge" alt="License">
    </a>
    <a href="https://github.com/yelmuratoff/agent">
      <img src="https://img.shields.io/github/stars/yelmuratoff/agent?style=for-the-badge&logo=github&color=4EAA25" alt="GitHub stars">
    </a>
  </p>
</div>

## What is AgentSync

AgentSync is a CLI tool that synchronizes AI agent instructions from a single source (`.ai/src/`) into tool-specific formats for Claude, Copilot, Cursor, Gemini, Codex, and others.

Each AI tool expects instructions in its own format and directory (`.claude/`, `.github/`, `.cursor/`, `.gemini/`...). AgentSync lets you write them once and distribute to all tools with a single command.

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Project Structure](#project-structure)
- [CLI Commands](#cli-commands)
- [Tool Configuration](#tool-configuration)
- [Tool YAML Schema](#tool-yaml-schema)
- [Supported Tools](#supported-tools)
- [Adding a New Tool](#adding-a-new-tool)
- [Git Hooks](#git-hooks)
- [Gitignore](#gitignore)
- [How Sync Works](#how-sync-works)
- [Path Overrides](#path-overrides)
- [Uninstall](#uninstall)

## Installation

Requirements: `git`, `bash`.

```bash
curl -fsSL https://raw.githubusercontent.com/yelmuratoff/agent/main/install.sh | bash
```

What the installer does:

1. Clones the repository to `~/.agentsync/`
2. Creates a symlink `agentsync` in `/usr/local/bin/` (falls back to `~/.local/bin/` if `/usr/local/bin` is not writable)
3. Adds `AGENTSYNC_HOME` to your shell config (`~/.zshrc` or `~/.bashrc`)

Restart your terminal or run `source ~/.zshrc` after installation.

Running the installer again updates the existing installation via `git pull`.

## Quick Start

```bash
# 1. Navigate to your project
cd your-project

# 2. Create the .ai/ structure with starter templates
agentsync init

# 3. (Optional) Generate project-specific rules using any AI
agentsync generate | pbcopy
# Paste into Claude, ChatGPT, Gemini, etc. — it will analyze your project
# and generate tailored AGENTS.md, rules, and skills

# 4. Edit .ai/src/AGENTS.md — customize your agent's identity
# 5. Edit .ai/src/rules/ — add project-specific constraints

# 6. Distribute instructions to all tools
agentsync sync
```

After `sync`, directories like `.claude/`, `.cursor/`, `.github/`, `.gemini/`, `.codex/` will appear in your project, each containing instructions in that tool's expected format.

## Project Structure

AgentSync supports two source layouts:

**Structured (default, created by `init`):**

```
.ai/
├── src/                        # Source of truth. Edit ONLY here.
│   ├── AGENTS.md               # Agent identity: role, approach, principles
│   ├── rules/                  # Rules — always-on constraints
│   │   ├── core.md
│   │   ├── testing.md
│   │   └── ...
│   ├── skills/                 # Skills — on-demand step-by-step recipes
│   │   ├── commit/
│   │   │   └── SKILL.md
│   │   └── ...
│   ├── commands/               # Custom slash commands (.md)
│   │   ├── review.md
│   │   └── fix-issue.md
│   ├── agents/                 # Subagent personas (.md)
│   │   └── code-reviewer.md
│   ├── settings/               # Tool-specific settings (JSON)
│   │   └── claude.json
│   ├── mcp/                    # MCP server configs (JSON)
│   │   ├── claude.json
│   │   └── cursor.json
│   └── tools/                  # Tool configurations
│       ├── claude.yaml
│       ├── copilot.yaml
│       ├── cursor.yaml
│       ├── gemini.yaml
│       ├── codex.yaml
│       └── _TEMPLATE.yaml      # Template for adding new tools
└── system/                     # Sync engine. Do not edit.
    ├── sync.sh
    ├── check.sh
    ├── setup_hooks.sh
    ├── config.yaml
    ├── lib/
    ├── templates/
    └── prompts/
```

**Flat (auto-detected):**

```
.ai/
├── AGENTS.md
├── rules/
├── skills/
└── tools/
```

### What Each Part Does

**AGENTS.md** — the main file. Describes who the agent is, how it thinks, and how it approaches work. Copied as-is to each tool (renamed according to the tool config: `CLAUDE.md`, `GEMINI.md`, etc.).

**rules/** — rule files. One file per topic (architecture, testing, security, etc.). Applied at all times. Some tools require specific formats: Cursor expects `.mdc` extension with a YAML header, Copilot expects `.instructions.md`. AgentSync converts automatically based on each tool's config.

**skills/** — step-by-step recipes. Each skill is a directory containing a `SKILL.md` file. Used by the agent on demand when a task matches the skill's description. Each `SKILL.md` has frontmatter:

```markdown
---
name: commit
description: >
  Create a well-structured git commit message for staged changes.
  USE WHEN committing code, writing commit messages, or preparing changes for push.
---

# Commit

Write a commit message that follows the project's conventions.

## Steps

1. Run `git diff --cached` to see changes.
2. ...

## Gotchas

- Don't amend the previous commit unless explicitly asked.
- ...
```

> **Tip:** The `description` is a trigger, not a summary. The agent scans descriptions to decide which skill to activate. Always include `USE WHEN` with specific conditions. The `Gotchas` section prevents repeated mistakes.

**commands/** — custom slash commands. Each `.md` file becomes a slash command in supported tools (e.g., `review.md` → `/project:review` in Claude Code). Commands support `$ARGUMENTS` for parameters and `` !`shell command` `` syntax for embedding shell output.

**agents/** — subagent personas. Each `.md` file defines a specialized agent with its own instructions, model, and tool access. Agents are spawned in isolated contexts for focused tasks like code review or security audit. Frontmatter fields (`model`, `tools`) are tool-specific and passed through.

**settings/** — tool-specific permission and configuration files. Each file is named after the tool (`claude.json`, etc.) and copied directly to the tool's settings location. Settings control what the AI can and can't do (allowed/denied commands, file access).

**mcp/** — MCP (Model Context Protocol) server configurations. Each file is named after the tool and copied to the tool's MCP config location. Define external tool servers that the AI can use.

**tools/** — YAML configurations. Define where and how files are copied for each tool. See [Tool YAML Schema](#tool-yaml-schema) for details.

## CLI Commands

```
agentsync <command> [options]
```

### `init`

```bash
agentsync init [directory]
```

Creates the `.ai/` structure in the specified directory (defaults to current directory). Generates starter templates:

- **AGENTS.md** — agent identity
- **Rules:** `core.md`, `git.md`
- **Skills:** `commit`, `review`, `refactor`, `debug`, `agentsync`
- **Commands:** `review`, `fix-issue`
- **Agents:** `code-reviewer`
- **Settings:** Claude permissions (`settings/claude.json`)
- **MCP:** empty configs for Claude and Cursor
- **Tool configs** for all supported tools

If `.ai/src/` already exists, nothing is overwritten. Also copies the sync engine into `.ai/system/`, so `sync` works without a global installation.

### `sync`

```bash
agentsync sync [options]
```

Reads `.ai/src/` and distributes its contents to tool directories according to configs in `.ai/src/tools/*.yaml`.

Options:

| Option           | Description                                                                                                                 |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `--only <tools>` | Sync only the specified tools (comma-separated). Names are yaml filenames without extension: `claude`, `cursor`, `copilot`. |
| `--skip <tools>` | Skip the specified tools.                                                                                                   |
| `--dry-run`      | Show what would be copied without making any changes.                                                                       |

Examples:

```bash
agentsync sync                        # All enabled tools
agentsync sync --only claude,cursor   # Only Claude and Cursor
agentsync sync --skip gemini          # All except Gemini
agentsync sync --dry-run              # Preview changes
```

### `check`

```bash
agentsync check
```

Verifies that generated files match the current contents of `.ai/src/`. Useful for CI — exit code 0 means everything is in sync, exit code 1 means there is drift.

How it works: copies the project to a temp directory, runs `sync`, compares the result against the original with `diff`. Does not modify your project.

### `generate`

```bash
agentsync generate [context]    # or: agentsync gen
```

Prints a prompt to stdout that you can paste into any AI assistant (Claude, ChatGPT, Gemini, etc.). The AI will analyze your project and generate tailored `AGENTS.md`, rules, and skills in the correct AgentSync format.

Examples:

```bash
agentsync generate                  # Basic prompt — AI will analyze the codebase
agentsync generate | pbcopy         # Copy to clipboard (macOS)
agentsync generate Flutter + Dart, BLoC, Clean Architecture
agentsync generate "React SPA with Next.js, Prisma ORM, Jest"
```

When context is provided, it's prepended to the prompt so the AI knows your stack before analyzing code.

### `setup-hooks`

```bash
agentsync setup-hooks
```

Installs `post-merge` and `post-checkout` git hooks. After this, `agentsync sync` runs automatically on `git pull` and `git checkout`. Existing hooks are not overwritten — the AgentSync block is appended to the end of the hook file.

Safe to run multiple times — if the block already exists, it is not duplicated.

### `list`

```bash
agentsync list      # or: agentsync ls
```

Shows all configured tools and their status (enabled/disabled). Reads `.ai/src/tools/*.yaml` in the current directory.

### `update`

```bash
agentsync update
```

Updates AgentSync to the latest version via `git pull`. Shows a changelog of what changed between your version and the latest.

AgentSync automatically checks for updates once every 24 hours when you run any command. To disable: `export AGENTSYNC_NO_UPDATE_CHECK=1`.

### `version`, `help`

```bash
agentsync version   # or --version, -v
agentsync help      # or --help, -h
```

## Tool Configuration

Each tool is described in a separate YAML file in `.ai/src/tools/`. The filename determines the tool identifier (used with `--only`/`--skip`). Files starting with `_` are ignored (e.g. `_TEMPLATE.yaml`).

Example — `.ai/src/tools/claude.yaml`:

```yaml
name: "Claude Code"
enabled: true

targets:
  agents:
    dest: ".claude/CLAUDE.md"
  rules:
    dest: ".claude/rules"
    append_imports: true
  skills:
    dest: ".claude/skills"
```

This means:

- `AGENTS.md` → copy to `.claude/CLAUDE.md`
- `rules/*.md` → copy to `.claude/rules/`
- Append `@rules/...` imports to the end of `.claude/CLAUDE.md`
- `skills/*/` → copy to `.claude/skills/`

## Tool YAML Schema

Full schema with all options:

```yaml
# Required fields
name: "Tool Name" # Display name (shown in logs and list)
enabled: true # true/false — enable/disable sync for this tool

targets:
  agents:
    dest: ".tool/AGENTS.md" # Where to copy AGENTS.md
    # source: ".ai/src/custom.md"    # Override source (default: .ai/src/AGENTS.md)

  rules:
    dest: ".tool/rules" # Where to copy rules
    # source: ".ai/src/my-rules"     # Override source directory
    # extension: ".mdc"              # Change file extension (default: .md)
    # header: "---\nkey: value\n---" # Prepend header to each rule file
    # include: "flutter-*.md"        # Only copy matching files (bash glob)
    # exclude: "secret-*.md"         # Skip matching files
    # append_imports: true           # Append @rules/* imports to AGENTS file
    # merge_to_file: true            # Merge all rules into dest as a single file

  skills:
    dest: ".tool/skills" # Where to copy skills
    # source: ".ai/src/my-skills"    # Override source directory
    # include: "flutter*"            # Filter by skill directory name
    # exclude: "python*"             # Exclude by name

  # commands:
  #   dest: ".tool/commands"           # Where to copy custom commands
  #   # extension: ".cmd.md"           # Optional extension change

  # subagents:
  #   dest: ".tool/agents"             # Where to copy subagent personas
  #   # extension: ".agent.md"         # Optional extension change (e.g., Copilot)

  # settings:
  #   source: ".ai/src/settings/tool.json"  # Source file (per-tool)
  #   dest: ".tool/settings.json"            # Where to copy

  # mcp:
  #   source: ".ai/src/mcp/tool.json"       # Source file (per-tool)
  #   dest: ".tool/.mcp.json"               # Where to copy

# post_sync: "npx prettier --write .tool/**/*.mdc"  # Command to run after sync
```

### Field Details

**`source`** — overrides the default source path for any target (`agents`, `rules`, `skills`). Useful when a tool needs a different AGENTS file or a subset of rules from a custom directory.

**`extension`** — replaces the file extension on rule files. For example, `extension: ".mdc"` renames `core.md` to `core.mdc`. Required for Cursor, which expects `.mdc` files.

**`header`** — a string prepended to the beginning of each rule file. Supports `\n` for line breaks. Cursor requires YAML frontmatter:

```yaml
header: "---\nglobs: '**/*'\nalwaysApply: true\n---"
```

This prepends to each rule file:

```
---
globs: '**/*'
alwaysApply: true
---
```

**`append_imports`** — when `true`, lines like `@rules/core.md`, `@rules/testing.md` are appended to the end of the AGENTS file. Currently used by Claude Code to import rules. Any tool that supports this syntax can use it.

**`merge_to_file`** — when `true`, all rule files are concatenated into a single output file instead of being copied as individual files. The `dest` path is treated as a file path, not a directory. Used by Aider, which expects a single `CONVENTIONS.md`.

**`include` / `exclude`** — bash glob patterns for filtering. Applied to filenames (for rules) or directory names (for skills).

**`post_sync`** — a command to run after syncing this tool. Disabled by default. To enable, set the environment variable `AGENTSYNC_ALLOW_POST_SYNC=true`.

## Supported Tools

| Tool            | Config          | Output                         | Notes                                                              |
| --------------- | --------------- | ------------------------------ | ------------------------------------------------------------------ |
| Claude Code     | `claude.yaml`   | `.claude/`                     | Full: CLAUDE.md, rules, skills, commands, agents, settings, mcp    |
| GitHub Copilot  | `copilot.yaml`  | `.github/`                     | instructions, skills, prompts (`.prompt.md`), agents (`.agent.md`) |
| Cursor          | `cursor.yaml`   | `.cursor/`                     | Rules as `.mdc`, mcp.json                                          |
| Gemini CLI      | `gemini.yaml`   | `.gemini/`                     | GEMINI.md, skills                                                  |
| OpenAI Codex    | `codex.yaml`    | `AGENTS.md`, `.agents/skills/` | AGENTS.md at project root                                          |
| Windsurf        | `windsurf.yaml` | `.windsurf/`                   | AGENTS.md, rules (`trigger` frontmatter), skills                   |
| JetBrains Junie | `junie.yaml`    | `.junie/`                      | guidelines.md, guidelines/                                         |
| Amp             | `amp.yaml`      | `AGENTS.md`, `.agents/skills/` | AGENTS.md at project root                                          |
| Aider           | `aider.yaml`    | `CONVENTIONS.md`               | All rules merged into single file                                  |
| Cline           | `cline.yaml`    | `.clinerules/`                 | Rules directory                                                    |
| Amazon Q        | `amazonq.yaml`  | `.amazonq/rules/`              | Rules directory                                                    |
| Augment Code    | `augment.yaml`  | `.augment/rules/`              | Rules directory                                                    |
| Devin           | `devin.yaml`    | `AGENTS.md`, `.devin/skills/`  | AGENTS.md at project root                                          |
| Tabnine         | `tabnine.yaml`  | `.tabnine/guidelines/`         | Rules as guidelines                                                |
| Zed             | `zed.yaml`      | `.rules`                       | Rules merged into single file                                      |
| Continue        | `continue.yaml` | `.continuerules`               | Rules merged into single file                                      |

Any tool can be added — see [Adding a New Tool](#adding-a-new-tool).

## Adding a New Tool

1. Copy the template:

```bash
cp .ai/src/tools/_TEMPLATE.yaml .ai/src/tools/newtool.yaml
```

2. Edit `newtool.yaml`:

```yaml
name: "New Tool"
enabled: true

targets:
  agents:
    dest: ".newtool/instructions.md"
  rules:
    dest: ".newtool/rules"
  skills:
    dest: ".newtool/skills"
```

3. Run sync:

```bash
agentsync sync --only newtool
```

The tool identifier for `--only`/`--skip` is the filename without `.yaml`.

## Git Hooks

```bash
agentsync setup-hooks
```

Installs two hooks:

- **post-merge** — runs after `git pull` / `git merge`
- **post-checkout** — runs after `git checkout` / `git switch`

Both invoke `agentsync sync`. This ensures generated files always match the source when switching branches or pulling changes.

If hooks are already installed, running `setup-hooks` again does not duplicate them.

## Gitignore

`agentsync sync` automatically manages a block in `.gitignore`:

```gitignore
# --- AI SYNC GENERATED START ---
# Automatically generated by .ai/system/sync.sh
# Do not edit this block manually.
.claude/CLAUDE.md
.claude/rules/
.claude/skills/
.cursor/AGENTS.md
.cursor/rules/
...
# --- AI SYNC GENERATED END ---
```

The block is rebuilt on every `sync` based on enabled tools. Everything outside the `START`/`END` markers is left untouched.

Generated files are gitignored because they are derived from `.ai/src/`. Only `.ai/src/` and `.ai/system/` need to be committed. Any developer can regenerate the outputs by running `agentsync sync`.

## How Sync Works

1. Reads `config.yaml` for default paths to AGENTS.md, rules, skills, and tools.
2. Auto-detects the source layout: both `.ai/src/AGENTS.md` (structured) and `.ai/AGENTS.md` (flat) are supported.
3. If `agent_sync.yaml` exists in the project root, paths can be overridden (see [Path Overrides](#path-overrides)).
4. For each `*.yaml` in the tools directory (excluding `_*` files):
   - Checks `enabled: true/false`
   - Checks CLI filters (`--only`, `--skip`)
   - Copies AGENTS.md to `targets.agents.dest`
   - Copies rules to `targets.rules.dest`, applying `extension`, `header`, `include`/`exclude`
   - If `append_imports: true`, appends `@rules/*` lines to the end of the AGENTS file
   - Copies skills to `targets.skills.dest`, applying `include`/`exclude`
   - If `post_sync` is set and `AGENTSYNC_ALLOW_POST_SYNC=true`, runs the command
5. Updates `.gitignore`
6. Prints summary: `Synced N/N tools`

Cleanup: when a tool is disabled (`enabled: false`), its generated directories are automatically removed. When filters (`include`/`exclude`) change, stale files in target directories are deleted.

## Path Overrides

Create `agent_sync.yaml` in the project root:

```yaml
source:
  agents: ".ai/src/AGENTS.md"
  rules: ".ai/src/rules"
  skills: ".ai/src/skills"
  tools: ".ai/src/tools"
```

Or in flat format:

```yaml
agents: ".ai/AGENTS.md"
rules: ".ai/rules"
skills: ".ai/skills"
tools: ".ai/tools"
```

Use this if your project layout differs from the default.

## Migrating from v1

If you used AgentSync v1 (before commands, agents, settings, and MCP support), here's what changed:

**New source directories** (optional — add only what you need):

```
.ai/src/
├── commands/       # NEW: custom slash commands
├── agents/         # NEW: subagent personas
├── settings/       # NEW: tool-specific permissions (JSON)
└── mcp/            # NEW: MCP server configs (JSON)
```

**Tool config changes:**

| v1                                      | v2                            | Action                      |
| --------------------------------------- | ----------------------------- | --------------------------- |
| `gemini.yaml` rules → `.gemini/prompts` | rules → `.gemini/rules`       | Update `targets.rules.dest` |
| `codex.yaml` rules → `.codex/prompts`   | rules → `.codex/instructions` | Update `targets.rules.dest` |

**New tools** — add configs if you use them: `windsurf.yaml`, `junie.yaml`, `amp.yaml`, `aider.yaml`.

**New target types** in tool YAML: `commands`, `subagents`, `settings`, `mcp`. Existing configs continue to work — new targets are opt-in.

To get the latest starter templates, run `agentsync init` in a temp directory and copy what you need:

```bash
mkdir /tmp/agentsync-v2 && agentsync init /tmp/agentsync-v2
# Copy new tool configs, commands, agents from /tmp/agentsync-v2/.ai/src/
```

## Uninstall

### Remove global installation

```bash
rm -rf ~/.agentsync
rm -f /usr/local/bin/agentsync      # or ~/.local/bin/agentsync
```

Remove the `export AGENTSYNC_HOME=...` line from `~/.zshrc` or `~/.bashrc`.

### Remove from a project

Delete `.ai/` and all generated directories:

```bash
rm -rf .ai/ .claude/ .cursor/ .codex/ .gemini/ .github/copilot-instructions.md .github/instructions/ .github/skills/
```

Remove the `AI SYNC GENERATED` block from `.gitignore`.

---

<div align="center">
  <a href="https://github.com/yelmuratoff/agent/graphs/contributors">
    <img src="https://contrib.rocks/image?repo=yelmuratoff/agent" />
  </a>
</div>
