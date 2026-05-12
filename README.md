<div align="center">
  <img src="https://github.com/yelmuratoff/agent/blob/main/assets/agent_sync.png?raw=true" width="400">

  <h3>One source → 14 AI tools. Stop copy-pasting rules.</h3>

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

## The problem

Every AI coding tool wants instructions in its own format and directory: `.claude/CLAUDE.md`, `.cursor/rules/*.mdc`, `.github/instructions/*.instructions.md`, `AGENTS.md`, `.windsurf/rules/`...

Use more than one tool — or work on a team where different people use different tools? You end up maintaining the same rules in 5+ formats. They drift. They go stale. You copy-paste forever.

## The solution

AgentSync syncs from a single source (`.ai/src/`) into **14 AI tools**: Claude Code, GitHub Copilot, Cursor, Gemini CLI, OpenAI Codex, Windsurf, JetBrains Junie, Aider, Cline, Augment Code, Amazon Q, Zed, Continue, Google Antigravity.

Write once → `agentsync sync` → every tool gets instructions in its native format.

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

## Why not just...?

- **...symlink the files?** Tools demand different extensions (`.mdc`, `.instructions.md`), different frontmatter, different nesting. Symlinks can't transform content — AgentSync does.
- **...a shell script per tool?** You'd be writing the same copy / rename / header-injection logic 14 times. AgentSync is that script, declarative (YAML), already tested on macOS, Linux, and Windows (Git Bash).
- **...stick to the one tool I use today?** Teammates pick different ones. Your future self might too. A single source file future-proofs you.
- **Zero runtime dependencies.** Pure Bash. No Node, Python, `yq`, or `jq`. Install with one `curl | bash`.

<details>
<summary><strong>Table of contents</strong></summary>

- [The problem](#the-problem)
- [The solution](#the-solution)
- [Why not just...?](#why-not-just)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Project Structure](#project-structure)
- [What Each Part Does](#what-each-part-does)
- [CLI Commands](#cli-commands)
  - [Sync options](#sync-options)
  - [Generate](#generate)
- [Tool Configuration](#tool-configuration)
- [Tool YAML Schema](#tool-yaml-schema)
  - [Key Fields](#key-fields)
- [Supported Tools](#supported-tools)
- [Format Conversions](#format-conversions)
- [Adding a New Tool](#adding-a-new-tool)
- [Git Hooks](#git-hooks)
- [Gitignore](#gitignore)
- [How Sync Works](#how-sync-works)
- [Customization workflow](#customization-workflow)
- [How Resources Resolve](#how-resources-resolve)
- [Migrating from the 0.10 flat layout](#migrating-from-the-010-flat-layout)
- [Path Overrides](#path-overrides)
- [Migrating Existing Configurations](#migrating-existing-configurations)
  - [Step-by-step](#step-by-step)
  - [What gets overwritten](#what-gets-overwritten)
  - [Drift detection](#drift-detection)
  - [`agentsync adopt` — promote an IDE edit back into source](#agentsync-adopt--promote-an-ide-edit-back-into-source)
  - [Disabling sync for specific tools](#disabling-sync-for-specific-tools)
- [Development](#development)
- [Uninstall](#uninstall)

</details>

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
agentsync init                        # 1. Interactive wizard in a TTY; auto-detect elsewhere
agentsync enable claude cursor        # 2. Turn on the tools you use (prints where to edit)
agentsync add mcp github --command …  # 3. (Optional) wire up shared MCP servers
agentsync generate | pbcopy           # 4. (Optional) AI-generate a project-specific config
agentsync sync                        # 5. Distribute to all enabled tools
```

**What each step does:**

1. **`agentsync init`** — Scaffolds the `.ai/` directory. In a terminal it opens a short wizard to pick which tools and content sections you want; in scripts/CI it runs silently using auto-detection (`.claude/`, `.cursor/`, `CLAUDE.md`, ...) and sensible defaults. Only the payloads you opt into get scaffolded — other tools use shipped base templates at sync time. Useful flags: `--tools claude,cursor` (explicit list), `--content agents,rules` (narrow content), `--no-detect` (blank slate), `--yes` (accept defaults), `--dry-run` (preview). Safe to run twice — if `.ai/src/` already exists, it skips.

2. **`agentsync enable <tool>`** — Adds the tool to `tools.enabled` _and_ scaffolds editable copies of its settings / hooks at `.ai/src/tools/<tool>/`, then prints the exact file path to edit plus the shared MCP path. Pass `--no-scaffold` to skip materializing files; pass `--yes` to accept the TTY confirm non-interactively.

3. **`agentsync add mcp <server>`** — Writes an MCP server entry into the shared `.ai/src/mcp.json`. On the next `sync`, every enabled tool gets the same server map — no copy-pasting across five JSON files. Use `agentsync customize <tool> mcp` only when a tool needs a divergent map.

4. **`agentsync generate`** — Prints a detailed prompt that you paste into any AI (Claude, ChatGPT, Gemini). The AI analyzes your project description and generates a complete `.ai/src/` config tailored to your stack: project-specific AGENTS.md, rules, skills, commands, agents, and settings. Pass optional context: `agentsync generate "React + Next.js + Prisma"`. Use `| pbcopy` (macOS) or `| xclip` (Linux) to copy to clipboard.

5. **`agentsync sync`** — Reads each enabled tool's config (user override + shipped base — see [How Resources Resolve](#how-resources-resolve)), then copies and transforms your source files into tool-specific formats. Rules get renamed (`.mdc` for Cursor, `.instructions.md` for Copilot), frontmatter headers are added, commands are converted to TOML for Gemini, agents get the right extensions, and settings/MCP/hooks are placed where each tool expects them. Also updates `.gitignore` to exclude generated files.

After `sync`, tool-specific directories appear (`.claude/`, `.cursor/`, `.github/`, `.windsurf/`, etc.), each with instructions in that tool's expected format.

> **Important:** `agentsync sync` **overwrites** generated tool directories entirely. If you already have custom rules, skills, commands, settings, or MCP configs in `.claude/`, `.cursor/`, `.github/`, etc., move them into `.ai/src/` first. See [Migrating Existing Configurations](#migrating-existing-configurations).

## Project Structure

AgentSync supports two source layouts:

**Structured (default, created by `init`):**

```
.ai/
├── agent_sync.yaml             # project config (tools.enabled, version pin, paths)
└── src/                        # Source of truth. Edit ONLY here.
    ├── AGENTS.md               # Agent identity: role, approach, principles
    ├── rules/                  # Rules — always-on constraints
    │   ├── core.md
    │   └── git.md
    ├── skills/                 # (optional) on-demand step-by-step recipes
    │   └── .../SKILL.md
    ├── commands/               # (optional) custom slash commands
    ├── agents/                 # (optional) subagent personas
    ├── mcp.json                # (optional) shared MCP servers, applied to every tool
    └── tools/                  # (optional) per-tool overrides
        ├── claude.yaml         #   tool YAML (same file as before 0.11)
        └── claude/             #   per-tool payload dir (NEW in 0.11)
            ├── settings.json   #     settings override
            ├── hooks.json      #     hooks override
            └── mcp.json        #     per-tool MCP override (shadows mcp.json above)
```

> **Note:** `init` is minimal. `mcp.json` and every file under `tools/<tool>/` are _overrides_ — they appear only when you opt in via `agentsync enable`, `agentsync customize`, or `agentsync add mcp`. Missing overrides fall back to shipped base templates automatically — see [How Resources Resolve](#how-resources-resolve) and [Customization workflow](#customization-workflow).

**Flat (auto-detected):** `.ai/AGENTS.md`, `.ai/rules/`, `.ai/skills/`, `.ai/tools/`

## What Each Part Does

| Source        | Purpose                                                                                                                                                                                                                                                                                                                                       | Tools that use it                                           |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| **AGENTS.md** | Agent identity — role, approach, principles. Copied as-is (renamed per tool: `CLAUDE.md`, `GEMINI.md`, `guidelines.md`).                                                                                                                                                                                                                      | All                                                         |
| **rules/**    | Always-on constraints. One file per topic. Auto-converted per tool: `.mdc` (Cursor), `.instructions.md` (Copilot), trigger frontmatter (Windsurf).                                                                                                                                                                                            | All                                                         |
| **skills/**   | On-demand recipes in the open [agentskills.io](https://agentskills.io) format. Each skill = directory with `SKILL.md` + optional `references/`, `scripts/`, `assets/`. Description is the trigger (imperative + pushy + ≤1024 chars). `Gotchas` section prevents repeated mistakes. Inlined as index for tools without native skills support. | All                                                         |
| **commands/** | Custom slash commands. `review.md` → `/project:review`. Support `$ARGUMENTS` and `` !`shell` `` syntax. Auto-converted to TOML for Gemini.                                                                                                                                                                                                    | Claude, Gemini, Copilot (as `.prompt.md`)                   |
| **agents/**   | Subagent personas. Isolated context, restricted tools. Frontmatter: `model`, `tools`, `readonly`. Auto-converted to TOML for Codex.                                                                                                                                                                                                           | Claude, Cursor, Copilot (`.agent.md`), Gemini, Codex (TOML) |
| **settings/** | Permissions & config. Per-tool JSON files (`claude.json`). Controls allow/deny rules. Claude hooks also go here.                                                                                                                                                                                                                              | Claude                                                      |
| **mcp/**      | MCP server configs. Per-tool JSON files. Define external tool servers.                                                                                                                                                                                                                                                                        | Claude, Cursor, Windsurf                                    |
| **hooks/**    | Event hooks. Per-tool JSON files. Scripts that run before/after tool actions (file edits, shell commands, etc.).                                                                                                                                                                                                                              | Cursor, Codex, Copilot                                      |
| **tools/**    | YAML configs — define where and how files are synced per tool.                                                                                                                                                                                                                                                                                | —                                                           |

## CLI Commands

```
agentsync <command> [options]
```

| Command              | Alias | Description                                                            |
| -------------------- | ----- | ---------------------------------------------------------------------- |
| `init [dir]`         |       | Create `.ai/` structure with starter templates                         |
| `sync`               |       | Sync to all enabled tools (`--only`, `--skip`, `--dry-run`, `--force`) |
| `check`              |       | Verify outputs match source (CI-friendly, exit code 0/1)               |
| `refresh`            |       | Pull new template files into existing `.ai/src/` (three-way diff)      |
| `adopt <dest>`       |       | Promote a manual edit in a generated file back into `.ai/src/`         |
| `doctor`             |       | Validate setup and surface drift / config warnings                     |
| `generate [context]` | `gen` | Print AI prompt for project-specific config generation                 |
| `setup-hooks`        |       | Install git hooks for auto-sync on pull/checkout                       |
| `list`               | `ls`  | Show configured tools and status                                       |
| `update`             |       | Self-update via git pull (auto-check every 24h)                        |
| `version`            | `-v`  | Print version                                                          |
| `help`               | `-h`  | Show help                                                              |

### Sync options

```bash
agentsync sync                        # All enabled tools
agentsync sync --only claude,cursor   # Only specified tools
agentsync sync --skip gemini          # All except specified
agentsync sync --dry-run              # Preview without writing
agentsync sync --force                # Overwrite even if dest files were edited manually
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

| Tool                   | Config             | Syncs                                                                                                      |
| ---------------------- | ------------------ | ---------------------------------------------------------------------------------------------------------- |
| **Claude Code**        | `claude.yaml`      | CLAUDE.md, rules, skills, commands, agents, settings.json, .mcp.json                                       |
| **GitHub Copilot**     | `copilot.yaml`     | copilot-instructions.md, .instructions.md rules, skills, .prompt.md commands, .agent.md agents, hooks.json |
| **Cursor**             | `cursor.yaml`      | AGENTS.md, .mdc rules, skills, agents, mcp.json, hooks.json                                                |
| **Gemini CLI**         | `gemini.yaml`      | GEMINI.md (+inlined rules), skills, commands (MD→TOML), agents                                             |
| **OpenAI Codex**       | `codex.yaml`       | AGENTS.md (+inlined rules), skills, agents (MD→TOML), hooks.json                                           |
| **Windsurf**           | `windsurf.yaml`    | AGENTS.md, rules (trigger frontmatter), skills, mcp_config.json                                            |
| **JetBrains Junie**    | `junie.yaml`       | guidelines.md, rules/, +inlined skills index                                                               |
| **Cline**              | `cline.yaml`       | 00-context.md, .clinerules/, +inlined skills index                                                         |
| **Amazon Q**           | `amazonq.yaml`     | 00-context.md, .amazonq/rules/, +inlined skills index                                                      |
| **Zed**                | `zed.yaml`         | .rules (prepend AGENTS.md + merged rules), +inlined skills index                                           |
| **Google Antigravity** | `antigravity.yaml` | GEMINI.md, rules (trigger frontmatter), skills, workflows (commands)                                       |

## Format Conversions

AgentSync auto-converts between formats during sync:

| Source format  | Target format                                    | Used by                                               |
| -------------- | ------------------------------------------------ | ----------------------------------------------------- |
| Rules `.md`    | `.mdc` + YAML frontmatter                        | Cursor                                                |
| Rules `.md`    | `.instructions.md` + `applyTo` header            | Copilot                                               |
| Rules `.md`    | `.md` + `trigger: always_on` header              | Windsurf                                              |
| Rules `.md`    | Single merged file                               | Zed                                                   |
| Rules `.md`    | Inlined into AGENTS.md                           | Codex, Gemini                                         |
| Rules `.md`    | Inline references (name + title) in AGENTS.md    | Codex, Gemini                                         |
| Skills dirs    | Inline index (name + description) in AGENTS.md   | Junie, Cline, Amazon Q, Zed                           |
| AGENTS.md      | Copied as `00-context.md` in rules directory     | Cline, Amazon Q                                       |
| AGENTS.md      | Prepended before merged rules                    | Zed                                                   |
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
   - Resolves settings / MCP / hooks per the base + override rules below
   - Runs optional `post_sync` command
4. Updates `.gitignore`
5. Disabled tools get their generated files cleaned up automatically.

## Customization workflow

Three commands cover every customization, each with a single responsibility.

```
┌───────────────────────────────────────────────────────────────────────────────┐
│  agentsync enable <tool>                                                      │
│    → adds tool to tools.enabled                                               │
│    → scaffolds .ai/src/tools/<tool>/{settings,hooks}.<ext> from base          │
│    → prints the exact file path to edit                                       │
│                                                                               │
│  agentsync add mcp <server> [--command|--url ...]                             │
│    → creates / updates the shared .ai/src/mcp.json                            │
│    → applied to every enabled tool on next sync                               │
│                                                                               │
│  agentsync customize <tool> <resource>                                        │
│    → for the rare case you need a per-tool override that differs from         │
│      the shared MCP map, or to materialize a payload enable --no-scaffold     │
│      skipped (`customize cursor hooks`)                                       │
└───────────────────────────────────────────────────────────────────────────────┘
```

**Mental model:**

- `enable` is the entry point. One command turns a tool on _and_ gives you the file to edit.
- Shared MCP is the default. `add mcp` writes to `.ai/src/mcp.json` which every tool picks up — no per-tool duplication.
- `customize` is the escape hatch. Use it only when you need a per-tool override that diverges from the shared source, or when `enable --no-scaffold` skipped materializing a file you later want.

All three write to **`.ai/src/tools/<tool>/`** (per-tool) or **`.ai/src/mcp.json`** (shared). Nothing is scattered across `.ai/src/hooks/`, `.ai/src/mcp/`, `.ai/src/settings/` — the old flat layout is kept around for backward compatibility (see [migrate](#migrating-from-the-0-10-flat-layout)).

## How Resources Resolve

Every payload resource — tool YAML, hooks, MCP config, settings — follows the same layered lookup. Nothing is cloned into every project by default; overrides are opt-in and merge on top of a shipped base.

```
┌─ 1. Per-tool override ─────────┐   ┌─ 2. Shared MCP (mcp only) ──────┐   ┌─ 3. Shipped base ──────────────────────┐
│ .ai/src/tools/<tool>/          │   │ .ai/src/mcp.json                │   │ <install-dir>/lib/templates/<resource>/│
│   <resource>.<ext>             │►► │ (applies to every tool)         │►► │   <tool>.<ext>                         │
└────────────────────────────────┘   └─────────────────────────────────┘   └────────────────────────────────────────┘

     per-tool wins   →   shared fills in (for MCP)   →   base fills in otherwise
```

| Resource  | Base path                             | Per-tool override                     | Shared override    |
| --------- | ------------------------------------- | ------------------------------------- | ------------------ |
| tool YAML | `lib/templates/tools/<tool>.yaml`     | `.ai/src/tools/<tool>.yaml`           | —                  |
| hooks     | `lib/templates/hooks/<tool>.json`     | `.ai/src/tools/<tool>/hooks.json`     | —                  |
| mcp       | `lib/templates/mcp/<tool>.json`       | `.ai/src/tools/<tool>/mcp.json`       | `.ai/src/mcp.json` |
| settings  | `lib/templates/settings/<tool>.<ext>` | `.ai/src/tools/<tool>/settings.<ext>` | —                  |

The legacy flat-layout overrides (`.ai/src/hooks/<tool>.<ext>`, `.ai/src/mcp/<tool>.<ext>`, `.ai/src/settings/<tool>.<ext>`) from 0.10 and earlier are still read and still win over base, but print a one-shot deprecation warning. Run `agentsync migrate --apply` to move them. Legacy paths will be removed in 0.12.

**Why it matters:**

- **Lean by default.** `agentsync init` creates `.ai/agent_sync.yaml`, `AGENTS.md`, and your chosen content sections — no pre-written hooks / MCP / settings for 14 tools you don't use.
- **Updates flow through.** Because the base lives in the install dir, `agentsync update` improves every project that hasn't locked the file in as an override.
- **Shared MCP is shared.** One `.ai/src/mcp.json` reaches every enabled tool — no copy-pasting the same server map into five JSON files.
- **Opt in per tool.** Need to edit Cursor's hooks? `agentsync customize cursor hooks` copies the current base into `.ai/src/tools/cursor/hooks.json`. Delete the file later to resume inheriting.
- **Safe hooks.** `customize <tool> hooks` prints the base content first and requires `--yes` in non-interactive mode — you never scaffold executable intent silently.
- **`simplify` prunes noise.** Scaffolded payloads that are still byte-identical to base are flagged by `agentsync simplify` and removed with `--apply`, so you don't accidentally pin yesterday's defaults forever.

## Migrating from the 0.10 flat layout

Projects upgraded from 0.10 keep working without intervention — the resolver still reads `.ai/src/{hooks,mcp,settings}/<tool>.<ext>`. When you are ready to move them into the canonical per-tool layout:

```bash
agentsync migrate             # dry-run; prints the planned moves
agentsync migrate --apply     # performs the moves; consolidates identical MCP files
agentsync migrate --apply -y  # non-interactive — accepts MCP consolidation by default
```

`migrate` moves each legacy file to `.ai/src/tools/<tool>/<resource>.<ext>`. When every `.ai/src/mcp/*.json` is byte-identical, it offers to collapse them into the shared `.ai/src/mcp.json`; if they differ, they migrate per-tool. Existing files at the target are never overwritten — such collisions are skipped with a warning so you resolve them by hand. Empty source directories are cleaned up on success.

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

### Drift detection

After every successful sync, AgentSync writes `.ai/.sync-manifest` — one line per generated file with its SHA-256 hash. **Commit it to git.** On the next sync, every destination is compared against the manifest:

- File untouched → sync rewrites silently (idempotent).
- File deleted manually → sync rewrites silently.
- File **edited** since last sync → sync **aborts** with the list of edited paths and your unsynced changes are preserved.

```text
[ERROR] Manual edits detected in 1 destination file(s) since last sync:
      .claude/rules/core.md

  These files would be silently overwritten. Choose one:
    • Move your edits into .ai/src/, then re-run sync
    • Re-run with --force to discard the edits and rewrite from source
```

`agentsync check` and `agentsync doctor` both surface drift, so CI catches a forgotten manifest commit before merge.

### `agentsync adopt` — promote an IDE edit back into source

Quickly iterating in Claude Code or Cursor and edited a generated file directly? Skip the manual `cp + sync --force` dance:

```bash
agentsync adopt .claude/rules/core.md            # interactive, with diff preview
agentsync adopt --dry-run .claude/rules/core.md  # show plan, write nothing
agentsync adopt --yes .claude/rules/core.md      # non-interactive (CI / scripts)
```

Resolves the destination back to its source file (`.ai/src/rules/core.md`), copies the edited content, and refreshes the manifest entry — the next `sync` is drift-free.

**Refused targets** (the round-trip would corrupt your source):

- Tools that inject a frontmatter header (`cursor` rules) — adopting would propagate the cursor-specific header to every other tool.
- Tools that merge rules into a single file (`gemini`, `cline`) — multiple sources collapsed into one dest can't be split back.
- Tools that inline rules/skills into AGENTS.md (`codex`, `junie`).
- Format-converted outputs (`codex` subagents → TOML, `amazonq` subagents → JSON).

For these cases, edit `.ai/src/` directly. AgentSync tells you which file when it refuses.

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

## Development

Run the test suite from the repo root:

```bash
# Full suite in parallel (needs GNU parallel — `brew install parallel` or
# `apt-get install parallel`). ~2x the CPU count is the sweet spot because
# tests block on git/filesystem. On an 8-core Mac: jobs=16, ≈ 25-30s.
bats --jobs "$(( $(getconf _NPROCESSORS_ONLN) * 2 ))" tests/

# A single file, or a subset:
bats tests/sync.bats
```

CI runs `--jobs 4` on Linux and macOS; Windows falls back to serial because
GNU parallel isn't available under git-bash.

## Uninstall

```bash
# Global
rm -rf ~/.agentsync && rm -f /usr/local/bin/agentsync
# Remove AGENTSYNC_HOME from ~/.zshrc

# Per project
rm -rf .ai/
# Remove AI SYNC GENERATED block from .gitignore
```

<!-- ---

## Star history

<a href="https://star-history.com/#yelmuratoff/agent&Date">
  <img src="https://api.star-history.com/svg?repos=yelmuratoff/agent&type=Date" alt="Star History Chart">
</a>

<div align="center">
  <a href="https://github.com/yelmuratoff/agent/graphs/contributors">
    <img src="https://contrib.rocks/image?repo=yelmuratoff/agent" />
  </a>
</div> -->
