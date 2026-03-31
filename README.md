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

AgentSync is a CLI tool that synchronizes AI agent instructions from a single source (`.ai/src/`) into tool-specific formats for **17 AI tools**: Claude Code, GitHub Copilot, Cursor, Gemini CLI, OpenAI Codex, Windsurf, JetBrains Junie, Amp, Cline, Devin, Augment Code, Amazon Q, Tabnine, Zed, Continue, Aider, and more.

Each AI tool expects instructions in its own format and directory (`.claude/`, `.github/`, `.cursor/`, `.windsurf/`...). AgentSync lets you write them once and distribute to all tools with a single command.

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Project Structure](#project-structure)
- [What Each Part Does](#what-each-part-does)
- [CLI Commands](#cli-commands)
- [Tool Configuration](#tool-configuration)
- [Tool YAML Schema](#tool-yaml-schema)
- [Supported Tools](#supported-tools)
- [Format Conversions](#format-conversions)
- [Adding a New Tool](#adding-a-new-tool)
- [Git Hooks](#git-hooks)
- [Gitignore](#gitignore)
- [How Sync Works](#how-sync-works)
- [Path Overrides](#path-overrides)
- [Migrating from v1](#migrating-from-v1)
- [Uninstall](#uninstall)

## Installation

Requirements: `git`, `bash`.

```bash
curl -fsSL https://raw.githubusercontent.com/yelmuratoff/agent/main/install.sh | bash
```

What the installer does:

1. Clones the repository to `~/.agentsync/`
2. Creates a symlink `agentsync` in `/usr/local/bin/` (falls back to `~/.local/bin/`)
3. Adds `AGENTSYNC_HOME` to your shell config (`~/.zshrc` or `~/.bashrc`)

Restart your terminal or run `source ~/.zshrc` after installation. Running the installer again updates via `git pull`.

## Quick Start

```bash
cd your-project
agentsync init                      # Create .ai/ structure with starter templates
agentsync generate | pbcopy         # (Optional) Generate project-specific config via AI
agentsync sync                      # Distribute to all tools
```

After `sync`, tool-specific directories appear (`.claude/`, `.cursor/`, `.github/`, `.windsurf/`, etc.), each with instructions in that tool's expected format.

## Project Structure

AgentSync supports two source layouts:

**Structured (default, created by `init`):**

```
.ai/
├── src/                        # Source of truth. Edit ONLY here.
│   ├── AGENTS.md               # Agent identity: role, approach, principles
│   ├── rules/                  # Rules — always-on constraints
│   │   ├── core.md
│   │   └── git.md
│   ├── skills/                 # Skills — on-demand step-by-step recipes
│   │   ├── commit/SKILL.md
│   │   ├── review/SKILL.md
│   │   └── ...
│   ├── commands/               # Custom slash commands
│   │   ├── review.md
│   │   └── fix-issue.md
│   ├── agents/                 # Subagent personas
│   │   └── code-reviewer.md
│   ├── settings/               # Tool-specific settings (JSON)
│   │   └── claude.json
│   ├── mcp/                    # MCP server configs (JSON)
│   │   ├── claude.json
│   │   └── cursor.json
│   ├── hooks/                  # Event hooks (JSON)
│   │   ├── cursor.json
│   │   └── codex.json
│   └── tools/                  # Tool YAML configurations
│       ├── claude.yaml
│       ├── cursor.yaml
│       └── _TEMPLATE.yaml
```

> **Note:** `init` no longer copies the sync engine into the project. The engine runs from the global `~/.agentsync/` installation.

**Flat (auto-detected):** `.ai/AGENTS.md`, `.ai/rules/`, `.ai/skills/`, `.ai/tools/`

## What Each Part Does

| Source        | Purpose                                                                                                                                                                                                           | Tools that use it                                           |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| **AGENTS.md** | Agent identity — role, approach, principles. Copied as-is (renamed per tool: `CLAUDE.md`, `GEMINI.md`, `guidelines.md`).                                                                                          | All                                                         |
| **rules/**    | Always-on constraints. One file per topic. Auto-converted per tool: `.mdc` (Cursor), `.instructions.md` (Copilot), trigger frontmatter (Windsurf).                                                                | All                                                         |
| **skills/**   | On-demand recipes. Each skill = directory with `SKILL.md`. Frontmatter triggers: `USE WHEN [conditions]`. `Gotchas` section prevents repeated mistakes. Inlined as index for tools without native skills support. | All                                                         |
| **commands/** | Custom slash commands. `review.md` → `/project:review`. Support `$ARGUMENTS` and `` !`shell` `` syntax. Auto-converted to TOML for Gemini.                                                                        | Claude, Gemini, Copilot (as `.prompt.md`)                   |
| **agents/**   | Subagent personas. Isolated context, restricted tools. Frontmatter: `model`, `tools`, `readonly`. Auto-converted to TOML for Codex.                                                                               | Claude, Cursor, Copilot (`.agent.md`), Gemini, Codex (TOML) |
| **settings/** | Permissions & config. Per-tool JSON files (`claude.json`). Controls allow/deny rules. Claude hooks also go here.                                                                                                  | Claude                                                      |
| **mcp/**      | MCP server configs. Per-tool JSON files. Define external tool servers.                                                                                                                                            | Claude, Cursor                                              |
| **hooks/**    | Event hooks. Per-tool JSON files. Scripts that run before/after tool actions (file edits, shell commands, etc.).                                                                                                  | Cursor, Codex                                               |
| **tools/**    | YAML configs — define where and how files are synced per tool.                                                                                                                                                    | —                                                           |

## CLI Commands

```
agentsync <command> [options]
```

| Command              | Alias | Description                                                 |
| -------------------- | ----- | ----------------------------------------------------------- |
| `init [dir]`         |       | Create `.ai/` structure with starter templates              |
| `sync`               |       | Sync to all enabled tools (`--only`, `--skip`, `--dry-run`) |
| `check`              |       | Verify outputs match source (CI-friendly, exit code 0/1)    |
| `generate [context]` | `gen` | Print AI prompt for project-specific config generation      |
| `setup-hooks`        |       | Install git hooks for auto-sync on pull/checkout            |
| `list`               | `ls`  | Show configured tools and status                            |
| `update`             |       | Self-update via git pull (auto-check every 24h)             |
| `version`            | `-v`  | Print version                                               |
| `help`               | `-h`  | Show help                                                   |

### Sync options

```bash
agentsync sync                        # All enabled tools
agentsync sync --only claude,cursor   # Only specified tools
agentsync sync --skip gemini          # All except specified
agentsync sync --dry-run              # Preview without writing
```

### Generate

```bash
agentsync generate                    # AI analyzes codebase
agentsync generate | pbcopy           # Copy to clipboard (macOS)
agentsync generate "React + Next.js"  # With context
```

Outputs a prompt for any AI (Claude, ChatGPT, Gemini) to generate tailored AGENTS.md, rules, skills, commands, agents, and settings.

## Tool Configuration

Each tool = one YAML file in `.ai/src/tools/`. Filename = tool identifier for `--only`/`--skip`. Files starting with `_` are ignored.

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
  commands:
    dest: ".claude/commands"
  subagents:
    dest: ".claude/agents"
  settings:
    source: ".ai/src/settings/claude.json"
    dest: ".claude/settings.json"
  mcp:
    source: ".ai/src/mcp/claude.json"
    dest: ".claude/.mcp.json"
```

## Tool YAML Schema

```yaml
name: "Tool Name"
enabled: true

targets:
  agents:
    dest: ".tool/AGENTS.md"
    # source: ".ai/src/custom.md"

  rules:
    dest: ".tool/rules"
    # source: ".ai/src/my-rules"
    # extension: ".mdc"
    # header: "---\nkey: value\n---"
    # include: "flutter-*.md"
    # exclude: "secret-*.md"
    # append_imports: true
    # merge_to_file: true
    # inline_into_agents: true

  skills:
    dest: ".tool/skills"
    # source: ".ai/src/my-skills"
    # include: "flutter*"
    # exclude: "python*"
    # inline_into_agents: true

  commands:
    dest: ".tool/commands"
    # extension: ".prompt.md"
    # format: "toml"

  subagents:
    dest: ".tool/agents"
    # extension: ".agent.md"
    # format: "toml"

  settings:
    source: ".ai/src/settings/tool.json"
    dest: ".tool/settings.json"

  mcp:
    source: ".ai/src/mcp/tool.json"
    dest: ".tool/.mcp.json"

  hooks:
    source: ".ai/src/hooks/tool.json"
    dest: ".tool/hooks.json"

# post_sync: "npx prettier --write .tool/**/*.mdc"
```

### Key Fields

| Field                         | Purpose                                                                                                                               |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `extension`                   | Rename file extension (`.mdc`, `.instructions.md`, `.agent.md`, `.prompt.md`)                                                         |
| `header`                      | Prepend text to each file (YAML frontmatter for Cursor, Windsurf, Copilot)                                                            |
| `append_imports`              | Append `@rules/*` import lines to AGENTS file (Claude)                                                                                |
| `merge_to_file`               | Merge all rules into a single file (Aider, Zed, Continue)                                                                             |
| `inline_into_agents` (rules)  | Append lightweight rule REFERENCES (name + title) into AGENTS file (Codex, Amp, Devin, Gemini)                                        |
| `inline_into_agents` (skills) | Append lightweight skill INDEX (name + description) into AGENTS file (Junie, Cline, Amazon Q, Augment, Tabnine, Aider, Zed, Continue) |
| `prepend_agents`              | Prepend AGENTS.md content before merged rules (Aider, Zed, Continue)                                                                  |
| `format: "toml"`              | Auto-convert MD→TOML (Gemini commands, Codex agents)                                                                                  |
| `source` (settings/mcp/hooks) | Required — per-tool source file path                                                                                                  |

## Supported Tools

| Tool                | Config          | Syncs                                                                                          |
| ------------------- | --------------- | ---------------------------------------------------------------------------------------------- |
| **Claude Code**     | `claude.yaml`   | CLAUDE.md, rules, skills, commands, agents, settings.json, .mcp.json                           |
| **GitHub Copilot**  | `copilot.yaml`  | copilot-instructions.md, .instructions.md rules, skills, .prompt.md commands, .agent.md agents |
| **Cursor**          | `cursor.yaml`   | AGENTS.md, .mdc rules, skills, agents, mcp.json, hooks.json                                    |
| **Gemini CLI**      | `gemini.yaml`   | GEMINI.md (+inlined rules), skills, commands (MD→TOML), agents                                 |
| **OpenAI Codex**    | `codex.yaml`    | AGENTS.md (+inlined rules), skills, agents (MD→TOML), hooks.json                               |
| **Windsurf**        | `windsurf.yaml` | AGENTS.md, rules (trigger frontmatter), skills                                                 |
| **JetBrains Junie** | `junie.yaml`    | guidelines.md, guidelines/, +inlined skills index                                              |
| **Amp**             | `amp.yaml`      | AGENTS.md (+inlined rules), skills                                                             |
| **Aider**           | `aider.yaml`    | CONVENTIONS.md (prepend AGENTS.md + merged rules), +inlined skills index                       |
| **Cline**           | `cline.yaml`    | 00-context.md, .clinerules/, +inlined skills index                                             |
| **Amazon Q**        | `amazonq.yaml`  | 00-context.md, .amazonq/rules/, +inlined skills index                                          |
| **Augment Code**    | `augment.yaml`  | 00-context.md, .augment/rules/, +inlined skills index                                          |
| **Devin**           | `devin.yaml`    | AGENTS.md (+inlined rules), skills                                                             |
| **Tabnine**         | `tabnine.yaml`  | 00-context.md, .tabnine/guidelines/, +inlined skills index                                     |
| **Zed**             | `zed.yaml`      | .rules (prepend AGENTS.md + merged rules), +inlined skills index                               |
| **Continue**        | `continue.yaml` | .continuerules (prepend AGENTS.md + merged rules), +inlined skills index                       |

## Format Conversions

AgentSync auto-converts between formats during sync:

| Source format  | Target format                                    | Used by                                                        |
| -------------- | ------------------------------------------------ | -------------------------------------------------------------- |
| Rules `.md`    | `.mdc` + YAML frontmatter                        | Cursor                                                         |
| Rules `.md`    | `.instructions.md` + `applyTo` header            | Copilot                                                        |
| Rules `.md`    | `.md` + `trigger: always_on` header              | Windsurf                                                       |
| Rules `.md`    | Single merged file                               | Aider, Zed, Continue                                           |
| Rules `.md`    | Inlined into AGENTS.md                           | Codex, Amp, Devin, Gemini                                      |
| Rules `.md`    | Inline references (name + title) in AGENTS.md    | Codex, Amp, Devin, Gemini                                      |
| Skills dirs    | Inline index (name + description) in AGENTS.md   | Junie, Cline, Amazon Q, Augment, Tabnine, Aider, Zed, Continue |
| AGENTS.md      | Copied as `00-context.md` in rules directory     | Cline, Amazon Q, Augment, Tabnine                              |
| AGENTS.md      | Prepended before merged rules                    | Aider, Zed, Continue                                           |
| Commands `.md` | `.toml` (prompt field, `!{}` syntax, `{{args}}`) | Gemini CLI                                                     |
| Commands `.md` | `.prompt.md`                                     | Copilot                                                        |
| Agents `.md`   | `.agent.md`                                      | Copilot                                                        |
| Agents `.md`   | `.toml` (developer_instructions field)           | Codex                                                          |

You write everything in Markdown. AgentSync handles the rest.

## Adding a New Tool

```bash
cp .ai/src/tools/_TEMPLATE.yaml .ai/src/tools/newtool.yaml
# Edit newtool.yaml, then:
agentsync sync --only newtool
```

## Git Hooks

```bash
agentsync setup-hooks
```

Installs `post-merge` and `post-checkout` hooks. `agentsync sync` runs automatically on `git pull` and `git checkout`. Safe to run multiple times.

## Gitignore

`agentsync sync` auto-manages a block in `.gitignore` between `AI SYNC GENERATED START/END` markers. Generated files are gitignored — only `.ai/src/` and `.ai/system/` need to be committed.

## How Sync Works

1. Reads `config.yaml` for default source paths.
2. Auto-detects structured (`.ai/src/`) or flat (`.ai/`) layout.
3. For each tool YAML:
   - Copies AGENTS.md → tool-specific name (or as `00-context.md` for directory-based tools)
   - Syncs rules with extension/header/merge transforms
   - If `inline_into_agents` (rules): appends lightweight rule references (name + title) to agents file
   - If `prepend_agents` (rules): prepends AGENTS.md content before merged rules
   - Syncs skills directories (or inlines skill index into agents file if `inline_into_agents`)
   - Syncs commands (with optional MD→TOML conversion)
   - Syncs agents (with optional extension rename or MD→TOML)
   - Copies settings, MCP, and hooks files
   - Runs optional `post_sync` command
4. Updates `.gitignore`
5. Disabled tools get their generated files cleaned up automatically.

## Path Overrides

Create `agent_sync.yaml` in the project root to override source paths:

```yaml
source:
  agents: ".ai/src/AGENTS.md"
  rules: ".ai/src/rules"
  skills: ".ai/src/skills"
  tools: ".ai/src/tools"
```

## Migrating from v1

**New source directories** (optional — add only what you need):
`commands/`, `agents/`, `settings/`, `mcp/`

**Tool config changes:**

- Gemini rules: `.gemini/prompts` → removed (Gemini uses GEMINI.md hierarchy)
- Codex: `.codex/AGENTS.md` → `AGENTS.md` (project root)

**New tools:** windsurf, junie, amp, aider, cline, amazonq, augment, devin, tabnine, zed, continue

**New target types:** `commands`, `subagents`, `settings`, `mcp`, `hooks` — all opt-in.

**New inline features:**

- `inline_into_agents` for rules: appends lightweight rule references to agents file (Codex, Amp, Devin, Gemini)
- `inline_into_agents` for skills: appends skill index to agents file (Junie, Cline, Amazon Q, Augment, Tabnine, Aider, Zed, Continue)
- `prepend_agents` for merged rules: prepends AGENTS.md before merged content (Aider, Zed, Continue)
- `00-context.md` pattern: AGENTS.md copied as first file in rules dir (Cline, Amazon Q, Augment, Tabnine)

**Init changes:** `init` no longer copies the engine into the project `.ai/system/`. The engine runs from `~/.agentsync/`.

```bash
# Get latest templates:
mkdir /tmp/agentsync-v2 && agentsync init /tmp/agentsync-v2
```

## Uninstall

```bash
# Global
rm -rf ~/.agentsync && rm -f /usr/local/bin/agentsync
# Remove AGENTSYNC_HOME from ~/.zshrc

# Per project
rm -rf .ai/
# Remove AI SYNC GENERATED block from .gitignore
```

---

<div align="center">
  <a href="https://github.com/yelmuratoff/agent/graphs/contributors">
    <img src="https://contrib.rocks/image?repo=yelmuratoff/agent" />
  </a>
</div>
