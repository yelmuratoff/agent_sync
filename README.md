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

Every AI coding tool expects instructions in its own format and directory — `.claude/CLAUDE.md`, `.cursor/rules/*.mdc`, `.github/instructions/*.instructions.md`, `AGENTS.md`, `.windsurf/rules/`... Managing them separately leads to drift, inconsistency, and wasted time when you use more than one tool (or your team does).

AgentSync is a CLI tool that synchronizes AI agent instructions from a single source (`.ai/src/`) into tool-specific formats for **14 AI tools**: Claude Code, GitHub Copilot, Cursor, Gemini CLI, OpenAI Codex, Windsurf, JetBrains Junie, Cline, Augment Code, Amazon Q, Zed, Continue, Aider, Google Antigravity, and more.

Write once → `agentsync sync` → every tool gets instructions in its native format.

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
- [Migrating Existing Configurations](#migrating-existing-configurations)
- [Uninstall](#uninstall)

## Installation

Requirements: `git`, `bash`. Works on **macOS** and **Linux** out of the box. On **Windows**, use [WSL](https://learn.microsoft.com/en-us/windows/wsl/install) or [Git Bash](https://gitforwindows.org/) (included with Git for Windows).

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
agentsync init                      # 1. Create .ai/ structure with starter templates
agentsync generate | pbcopy         # 2. (Optional) Generate project-specific config via AI
agentsync sync                      # 3. Distribute to all tools
```

**What each step does:**

1. **`agentsync init`** — Creates the `.ai/src/` directory with starter templates: `AGENTS.md` (agent identity), sample rules, skills, commands, agent personas, and tool YAML configs for all 14 supported tools. Safe to run only once — if `.ai/src/` already exists, it skips to avoid overwriting your content.

2. **`agentsync generate`** — Prints a detailed prompt that you paste into any AI (Claude, ChatGPT, Gemini). The AI analyzes your project description and generates a complete `.ai/src/` config tailored to your stack: project-specific AGENTS.md, rules, skills, commands, agents, and settings. Pass optional context: `agentsync generate "React + Next.js + Prisma"`. Use `| pbcopy` (macOS) or `| xclip` (Linux) to copy to clipboard.

3. **`agentsync sync`** — Reads each tool YAML config from `.ai/src/tools/`, then copies and transforms your source files into tool-specific formats. Rules get renamed (`.mdc` for Cursor, `.instructions.md` for Copilot), frontmatter headers are added, commands are converted to TOML for Gemini, agents get the right extensions, and settings/MCP/hooks are placed where each tool expects them. Also updates `.gitignore` to exclude generated files.

After `sync`, tool-specific directories appear (`.claude/`, `.cursor/`, `.github/`, `.windsurf/`, etc.), each with instructions in that tool's expected format.

> **Important:** `agentsync sync` **overwrites** generated tool directories entirely. If you already have custom rules, skills, commands, settings, or MCP configs in `.claude/`, `.cursor/`, `.github/`, etc., move them into `.ai/src/` first. See [Migrating Existing Configurations](#migrating-existing-configurations).

**Example: one rule → every tool:**

```
.ai/src/rules/testing.md
    ↓ agentsync sync
├── .claude/rules/testing.md              # + @rules/testing.md import in CLAUDE.md
├── .cursor/rules/testing.mdc             # + globs/alwaysApply frontmatter
├── .github/instructions/testing.instructions.md  # + applyTo frontmatter
├── .windsurf/rules/testing.md            # + trigger: always_on frontmatter
├── .junie/rules/testing.md
├── .amazonq/rules/testing.md
├── AGENTS.md                             # inlined rule reference (Codex)
└── CONVENTIONS.md                        # merged into single file (Aider)
```

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
| **mcp/**      | MCP server configs. Per-tool JSON files. Define external tool servers.                                                                                                                                            | Claude, Cursor, Windsurf                                    |
| **hooks/**    | Event hooks. Per-tool JSON files. Scripts that run before/after tool actions (file edits, shell commands, etc.).                                                                                                  | Cursor, Codex, Copilot                                      |
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
agentsync generate                    # Generate bootstrap prompt
agentsync generate | pbcopy           # Copy to clipboard (macOS)
agentsync generate "React + Next.js"  # With project context
```

Works like `claude /init` — generates a prompt that you paste into any AI (Claude, ChatGPT, Gemini). The AI analyzes your codebase description and creates a complete `.ai/src/` config: AGENTS.md, rules, skills, commands, and agents tailored to your project's stack and conventions.

## Tool Configuration

Each tool = one YAML file in `.ai/src/tools/`. Filename = tool identifier for `--only`/`--skip`. Files starting with `_` are ignored.

Example — `.ai/src/tools/claude.yaml`:

```yaml
name: "Claude Code"
enabled: true

targets:
  agents:
    dest: "CLAUDE.md"
  rules:
    dest: ".claude/rules"
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
    dest: ".mcp.json"
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

| Field                         | Purpose                                                                                                                      |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `extension`                   | Rename file extension (`.mdc`, `.instructions.md`, `.agent.md`, `.prompt.md`)                                                |
| `header`                      | Prepend text to each file (YAML frontmatter for Cursor, Windsurf, Copilot)                                                   |
| `append_imports`              | Append `@rules/*` import lines to AGENTS file (Claude)                                                                       |
| `merge_to_file`               | Merge all rules into a single file (Aider, Zed, Continue)                                                                    |
| `inline_into_agents` (rules)  | Append lightweight rule REFERENCES (name + title) into AGENTS file (Codex, Gemini)                                           |
| `inline_into_agents` (skills) | Append lightweight skill INDEX (name + description) into AGENTS file (Junie, Cline, Amazon Q, Augment, Aider, Zed, Continue) |
| `prepend_agents`              | Prepend AGENTS.md content before merged rules (Aider, Zed, Continue)                                                         |
| `format: "toml"`              | Auto-convert MD→TOML (Gemini commands, Codex agents)                                                                         |
| `source` (settings/mcp/hooks) | Required — per-tool source file path                                                                                         |

## Supported Tools

| Tool                | Config          | Syncs                                                                                                      |
| ------------------- | --------------- | ---------------------------------------------------------------------------------------------------------- |
| **Claude Code**     | `claude.yaml`   | CLAUDE.md, rules, skills, commands, agents, settings.json, .mcp.json                                       |
| **GitHub Copilot**  | `copilot.yaml`  | copilot-instructions.md, .instructions.md rules, skills, .prompt.md commands, .agent.md agents, hooks.json |
| **Cursor**          | `cursor.yaml`   | AGENTS.md, .mdc rules, skills, agents, mcp.json, hooks.json                                                |
| **Gemini CLI**      | `gemini.yaml`   | GEMINI.md (+inlined rules), skills, commands (MD→TOML), agents                                             |
| **OpenAI Codex**    | `codex.yaml`    | AGENTS.md (+inlined rules), skills, agents (MD→TOML), hooks.json                                           |
| **Windsurf**        | `windsurf.yaml` | AGENTS.md, rules (trigger frontmatter), skills, mcp_config.json                                            |
| **JetBrains Junie** | `junie.yaml`    | guidelines.md, rules/, +inlined skills index                                                               |
| **Aider**           | `aider.yaml`    | CONVENTIONS.md (prepend AGENTS.md + merged rules), +inlined skills index                                   |
| **Cline**           | `cline.yaml`    | 00-context.md, .clinerules/, +inlined skills index                                                         |
| **Amazon Q**        | `amazonq.yaml`  | 00-context.md, .amazonq/rules/, +inlined skills index                                                      |
| **Augment Code**    | `augment.yaml`  | 00-context.md, .augment/rules/, +inlined skills index                                                      |
| **Zed**             | `zed.yaml`      | .rules (prepend AGENTS.md + merged rules), +inlined skills index                                           |
| **Continue**        | `continue.yaml` | .continuerules (prepend AGENTS.md + merged rules), +inlined skills index                                   |

## Format Conversions

AgentSync auto-converts between formats during sync:

| Source format  | Target format                                    | Used by                                               |
| -------------- | ------------------------------------------------ | ----------------------------------------------------- |
| Rules `.md`    | `.mdc` + YAML frontmatter                        | Cursor                                                |
| Rules `.md`    | `.instructions.md` + `applyTo` header            | Copilot                                               |
| Rules `.md`    | `.md` + `trigger: always_on` header              | Windsurf                                              |
| Rules `.md`    | Single merged file                               | Aider, Zed, Continue                                  |
| Rules `.md`    | Inlined into AGENTS.md                           | Codex, Gemini                                         |
| Rules `.md`    | Inline references (name + title) in AGENTS.md    | Codex, Gemini                                         |
| Skills dirs    | Inline index (name + description) in AGENTS.md   | Junie, Cline, Amazon Q, Augment, Aider, Zed, Continue |
| AGENTS.md      | Copied as `00-context.md` in rules directory     | Cline, Amazon Q, Augment                              |
| AGENTS.md      | Prepended before merged rules                    | Aider, Zed, Continue                                  |
| Commands `.md` | `.toml` (prompt field, `!{}` syntax, `{{args}}`) | Gemini CLI                                            |
| Commands `.md` | `.prompt.md`                                     | Copilot                                               |
| Agents `.md`   | `.agent.md`                                      | Copilot                                               |
| Agents `.md`   | `.toml` (developer_instructions field)           | Codex                                                 |

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

`agentsync sync` auto-manages a block in `.gitignore` between `AI SYNC GENERATED START/END` markers. Generated files are gitignored — only `.ai/src/` needs to be committed.

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

## Migrating Existing Configurations

If you already have tool-specific configs (`.claude/rules/`, `.cursor/rules/`, custom `settings.json`, etc.), **move them into `.ai/src/` before running `agentsync sync`**. Sync treats generated directories as fully managed — any files not present in the source will be overwritten or removed.

### Step-by-step

1. **Run `agentsync init`** to create the `.ai/src/` structure (skips files that already exist).

2. **Move your rules** from tool-specific directories into `.ai/src/rules/`:

   ```bash
   # Example: you had custom Cursor rules
   mv .cursor/rules/my-api-conventions.mdc .ai/src/rules/my-api-conventions.md
   # Remove Cursor-specific frontmatter (---/globs/alwaysApply) — AgentSync adds it automatically

   # Example: you had custom Claude rules
   mv .claude/rules/testing.md .ai/src/rules/testing.md
   ```

3. **Move your skills** into `.ai/src/skills/`:

   ```bash
   mv .claude/skills/my-skill/ .ai/src/skills/my-skill/
   ```

4. **Move your commands** into `.ai/src/commands/`:

   ```bash
   mv .claude/commands/deploy.md .ai/src/commands/deploy.md
   ```

5. **Move your agents** into `.ai/src/agents/`:

   ```bash
   mv .claude/agents/security-auditor.md .ai/src/agents/security-auditor.md
   ```

6. **Move settings, MCP, and hooks** into `.ai/src/settings/`, `.ai/src/mcp/`, `.ai/src/hooks/`:

   ```bash
   mv .claude/settings.json .ai/src/settings/claude.json
   mv .mcp.json .ai/src/mcp/claude.json
   mv .cursor/mcp.json .ai/src/mcp/cursor.json
   ```

7. **Run sync** and verify:

   ```bash
   agentsync sync --dry-run   # Preview what will be generated
   agentsync sync              # Apply
   ```

### What gets overwritten

| Target                                                           | Behavior                                                                                                                                  |
| ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| **Rules directories** (`.claude/rules/`, `.cursor/rules/`, etc.) | Files matching the synced extension (`.md`, `.mdc`, `.instructions.md`) are managed by sync. Files not present in source are **removed**. |
| **AGENTS/CLAUDE.md/GEMINI.md**                                   | **Fully replaced** from `.ai/src/AGENTS.md` on every sync.                                                                                |
| **settings.json, .mcp.json, hooks.json**                         | **Fully replaced** from their respective source files.                                                                                    |
| **Skills, commands, agents directories**                         | Synced contents replace existing files. Extra files are **removed**.                                                                      |
| **.gitignore**                                                   | Only the `AI SYNC GENERATED START/END` block is managed. Your other entries are safe.                                                     |

### Disabling sync for specific tools

If you want to keep managing a tool manually, disable it in its YAML config:

```yaml
# .ai/src/tools/cursor.yaml
enabled: false
```

Or exclude it at sync time:

```bash
agentsync sync --skip cursor
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
