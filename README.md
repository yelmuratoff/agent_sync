<div align="center">
  <img src="https://github.com/yelmuratoff/agent/blob/main/assets/agent_sync.png?raw=true" width="400">

  <h3>One source → 13 AI tools. Stop copy-pasting rules.</h3>

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

AgentSync syncs from a single source (`.ai/src/`) into **13 AI tools**: Claude Code, GitHub Copilot, Cursor, Gemini CLI, OpenAI Codex, Kimi Code, OpenCode, Windsurf, JetBrains Junie, Cline, Amazon Q, Zed, Google Antigravity.

Write once → `agentsync sync` → every tool gets instructions in its native format.

```
.ai/src/rules/testing.md
    ↓ agentsync sync
├── .claude/rules/testing.md              # + @rules/testing.md import in CLAUDE.md
├── .cursor/rules/testing.mdc             # + globs/alwaysApply frontmatter
├── .github/instructions/testing.instructions.md  # + applyTo frontmatter
├── .windsurf/rules/testing.md            # + trigger: always_on frontmatter
├── .amazonq/rules/testing.md
├── AGENTS.md                             # inlined rule reference (Codex, Gemini, Junie, Kimi, OpenCode)
└── .rules                                # merged into single file (Zed)
```

The frontmatter above is the always-on default. Give a rule `paths:` frontmatter (a list of globs) and AgentSync emits each tool's **scoped** trigger instead (`alwaysApply: false`, `applyTo: <globs>`, `trigger: glob`; Claude keeps `paths:`), so domain rules load only when matching files are touched — keeping the always-on context lean.

## Why not just...?

- **...symlink the files?** Tools demand different extensions (`.mdc`, `.instructions.md`), different frontmatter, different nesting. Symlinks can't transform content — AgentSync does.
- **...a shell script per tool?** You'd be writing the same copy / rename / header-injection logic 13 times. AgentSync is that script, declarative (YAML), already tested on macOS, Linux, and Windows (Git Bash).
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
- [Models and Providers Are Not Tools](#models-and-providers-are-not-tools)
- [Adding a New Tool](#adding-a-new-tool)
- [Automation](#automation)
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
- [Workspaces — nested AgentSync projects](#workspaces--nested-agentsync-projects)
- [Profiles — multiple config homes per tool](#profiles--multiple-config-homes-per-tool)
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

3. **`agentsync add mcp <server>`** — Writes an MCP server entry into the shared `.ai/src/mcp.json`. On the next `sync`, every enabled MCP target gets the server map in its native format. Put a divergent map at `.ai/src/tools/<tool>/mcp.json`; `agentsync customize <tool> mcp` scaffolds it when that target ships a copyable base.

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
    ├── rules/                  # Rules — always-on, or paths:-scoped (load on-demand)
    │   ├── core.md
    │   └── git.md
    ├── skills/                 # (optional) on-demand step-by-step recipes
    │   └── .../SKILL.md
    ├── commands/               # (optional) custom slash commands
    ├── agents/                 # (optional) subagent personas
    ├── mcp.json                # (optional) shared MCP servers for compatible targets
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
| **AGENTS.md** | Agent identity — role, approach, principles. Copied as-is (renamed per tool: `CLAUDE.md`, `GEMINI.md`, `.junie/AGENTS.md`, `00-context.md`).                                                                                                                                                                                                                      | All                                                         |
| **rules/**    | Always-on constraints by default. Add `paths:` frontmatter (a list of globs) to scope a domain rule so it loads only when matching files are touched — translated to each tool's native trigger (Claude keeps `paths:`, Cursor `globs`+`alwaysApply:false`, Copilot `applyTo`, Windsurf/Antigravity `trigger: glob`). One file per topic; keep the always-on set lean so individual rules aren't diluted. | All                                                         |
| **skills/**   | On-demand recipes in the open [agentskills.io](https://agentskills.io) format. Each skill = directory with `SKILL.md` + optional `references/`, `scripts/`, `assets/`. Description is the trigger (imperative + pushy + ≤1024 chars). `Gotchas` section prevents repeated mistakes. Inlined as index for tools without native skills support. | All                                                         |
| **commands/** | Custom slash commands. `review.md` → `/project:review`. Support `$ARGUMENTS` and `` !`shell` `` syntax. Auto-converted to TOML for Gemini. For tools without a native commands surface, AgentSync converts commands to generated skills or an inlined index. | Claude, Cursor, Copilot (`.prompt.md`), Gemini (TOML), Junie, Cline, Windsurf, Antigravity, OpenCode; Codex and Kimi Code (as skills); Amazon Q, Zed (inlined) |
| **agents/**   | Subagent personas. Isolated context, restricted tools. Frontmatter: `model`, `tools`, `readonly`. Converted when the target needs a different schema. | Claude, Cursor, Copilot (`.agent.md`), Gemini, Junie, Codex (TOML), Amazon Q (JSON), OpenCode (safe MD) |
| **settings/** | Permissions & config. Per-tool files (`claude.json`, `gemini.json`, `codex.toml`, `opencode.json`, `zed.json`). Controls allow/deny rules. Claude hooks also go here. | Claude, Gemini, Codex, OpenCode, Zed |
| **mcp.json**  | Shared canonical `mcpServers` map. Copied to compatible targets and converted into OpenCode's top-level `mcp` map. | Claude, Cursor, Windsurf, Junie, Amazon Q, Kimi Code, OpenCode |
| **hooks/**    | Event hooks and native project plugins. Per-tool overrides can be JSON or TypeScript. | Cursor, Copilot, Codex, Windsurf, OpenCode |
| **tools/**    | YAML configs — define where and how files are synced per tool.                                                                                                                                                                                                                                                                                | —                                                           |

## CLI Commands

```
agentsync <command> [options]
```

| Command                  | Alias | Description                                                                                    |
| ------------------------ | ----- | ---------------------------------------------------------------------------------------------- |
| `init [dir]`             |       | Create `.ai/` structure with starter templates                                                 |
| `sync`                   |       | Sync to all enabled tools (`--only`, `--skip`, `--profile`, `--dry-run`, `--force`, `--if-stale`, `--workspace`) |
| `check`                  |       | Verify outputs match source (CI-friendly, exit code 0/1)                                       |
| `enable <tools…>`        |       | Opt in to one or more tools (scaffolds editable settings/hooks payloads)                        |
| `disable <tools…>`       |       | Opt out of one or more tools                                                                    |
| `add <kind> <name>`      |       | Scaffold a `rule`, `skill`, `command`, `subagent`, or `mcp` server                              |
| `customize <tool> [res]` |       | Create a per-field override for a tool                                                          |
| `simplify [tool]`        |       | Remove override fields that match the base (`--apply`)                                          |
| `show <tool>`            |       | Show effective (merged) config for a tool                                                       |
| `diff [tool]`            |       | Show user overrides vs base defaults                                                            |
| `resolve`                |       | Interactively reconcile overrides with base values                                              |
| `refresh`                |       | Pull new template files into existing `.ai/src/` (three-way diff; `--status` to list declined) |
| `dedupe`                 |       | Interactively remove source files duplicated against a parent `.ai/src/`                       |
| `migrate`                |       | Move legacy flat-layout overrides into per-tool dirs; clean up pre-v0.6 `.agent/`              |
| `adopt <dest>`           |       | Promote a manual edit in a generated file back into `.ai/src/` (`--all` for every drifted file) |
| `profile <cmd>`          |       | Manage config-home profiles: `add`, `list`, `remove` (work/personal tool variants)             |
| `doctor`                 |       | Validate setup and surface drift / config warnings / cross-project advisories                  |
| `generate [context]`     | `gen` | Print AI prompt for project-specific config generation                                         |
| `setup-hooks`            |       | Install git hooks for auto-sync on pull/checkout (`--pre-commit` to add a pre-commit hook)      |
| `shell-init [zsh\|bash]` |       | Print a shell hook that auto-syncs the nearest project on directory change                      |
| `export`                 |       | Bundle `.ai/src/` into a shareable archive                                                      |
| `import <src>`           |       | Import config from a GitHub repo, archive, or directory                                         |
| `list`                   | `ls`  | Show configured tools and status                                                               |
| `update`                 |       | Self-update via git pull (runs a background update check on each interactive command)          |
| `upgrade-config`         |       | Re-pin `agentsync_version` in `agent_sync.yaml`                                                 |
| `release`                |       | Bump version, tag, and push (maintainer)                                                        |
| `version`                | `-v`  | Print version                                                                                  |
| `help`                   | `-h`  | Show help                                                                                      |

### Sync options

```bash
agentsync sync                        # All enabled tools
agentsync sync --only claude,cursor   # Only specified tools
agentsync sync --skip gemini          # All except specified
agentsync sync --profile hub          # Personal tools + the named profile (config-home variant)
agentsync sync --dry-run              # Preview without writing
agentsync sync --force                # Overwrite edited files and prune hand-added files in generated dirs
agentsync sync --workspace            # Run sync in every .ai/ below cwd (bottom-up alphabetical)
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
| `extension`                     | Rename file extension (`.mdc`, `.instructions.md`, `.agent.md`, `.prompt.md`)                                          |
| `header`                        | Prepend text to each file (YAML frontmatter for Cursor, Windsurf, Copilot)                                             |
| `append_imports`                | Append `@rules/*` import lines to AGENTS file (Claude)                                                                 |
| `merge_to_file`                 | Merge all rules into a single file (Zed)                                                                               |
| `inline_into_agents` (rules)    | Append lightweight rule REFERENCES (name + title) into AGENTS file (Codex, Gemini, Junie, Kimi Code, OpenCode)       |
| `inline_into_agents` (skills)   | Append lightweight skill INDEX (name + description) into AGENTS file (Cline, Amazon Q, Zed)                            |
| `as_skills` (commands)          | Emit each command as a generated skill at `<skills.dest>/command-<name>/SKILL.md` (Codex, Kimi Code)                  |
| `inline_into_agents` (commands) | Append a `## Commands` index (`` `/<name>` — description ``) into AGENTS file (Amazon Q, Zed)                          |
| `prepend_agents`                | Prepend AGENTS.md content before merged rules (Zed)                                                                    |
| `format: "toml"`                | Auto-convert MD→TOML (Gemini commands, Codex subagents)                                                                |
| `format: "amazonq_json"`        | Auto-convert subagent MD→Amazon Q CLI custom-agent JSON (Amazon Q subagents)                                           |
| `format: "opencode_md"`         | Convert portable subagent frontmatter to safe OpenCode Markdown (OpenCode subagents)                                  |
| `format: "opencode_json"`       | Compose canonical `mcpServers` into OpenCode's top-level `mcp` settings map                                            |
| `source` (settings/mcp/hooks)   | Optional declared source; canonical `.ai/src/tools/<tool>/<resource>.<ext>` overrides it automatically                 |

## Supported Tools

| Tool                   | Config             | Syncs                                                                                                      |
| ---------------------- | ------------------ | ---------------------------------------------------------------------------------------------------------- |
| **Claude Code**        | `claude.yaml`      | CLAUDE.md, rules, skills, commands, agents, settings.json, .mcp.json                                       |
| **GitHub Copilot**     | `copilot.yaml`     | copilot-instructions.md, .instructions.md rules, skills, .prompt.md commands, .agent.md agents, hooks.json |
| **Cursor**             | `cursor.yaml`      | AGENTS.md, .mdc rules, skills, commands, agents, mcp.json, hooks.json                                      |
| **Gemini CLI**         | `gemini.yaml`      | GEMINI.md (+inlined rules), skills, commands (MD→TOML), agents, settings.json                              |
| **OpenAI Codex**       | `codex.yaml`       | AGENTS.md (+inlined rules), skills, commands (as `command-*` skills), subagents (MD→TOML), hooks.json, config.toml |
| **Kimi Code**          | `kimi.yaml`        | .kimi-code/AGENTS.md (+inlined rules), skills, commands (as `command-*` skills), mcp.json                         |
| **OpenCode**           | `opencode.yaml`    | AGENTS.md (+inlined rules), skills, commands, subagents (safe MD), settings + converted MCP in opencode.json, agentsync.ts plugin |
| **Windsurf**           | `windsurf.yaml`    | AGENTS.md, rules (trigger frontmatter), skills, workflows (commands), mcp_config.json, hooks.json          |
| **JetBrains Junie**    | `junie.yaml`       | .junie/AGENTS.md (+inlined rules), skills, commands, agents, mcp.json                                      |
| **Cline**              | `cline.yaml`       | 00-context.md, .clinerules/, workflows (commands), +inlined skills index                                   |
| **Amazon Q**           | `amazonq.yaml`     | 00-context.md, .amazonq/rules/, +inlined skills index, +inlined commands index, mcp.json, cli-agents (MD→JSON) |
| **Zed**                | `zed.yaml`         | .rules (prepend AGENTS.md + merged rules), +inlined skills index, +inlined commands index, settings.json   |
| **Google Antigravity** | `antigravity.yaml` | GEMINI.md, .agents/rules (trigger frontmatter), .agents/skills, .agents/workflows (commands)               |

## Format Conversions

AgentSync auto-converts between formats during sync:

| Source format  | Target format                                    | Used by                     |
| -------------- | ------------------------------------------------ | --------------------------- |
| Rules `.md`    | `.mdc` + YAML frontmatter                        | Cursor                      |
| Rules `.md`    | `.instructions.md` + `applyTo` header            | Copilot                     |
| Rules `.md`    | `.md` + `trigger: always_on` header              | Windsurf                    |
| Rules `.md`    | Single merged file                               | Zed                         |
| Rules `.md`    | Inline references (name + title) in AGENTS.md    | Codex, Gemini, Junie, Kimi Code, OpenCode |
| Skills dirs    | Inline index (name + description) in AGENTS.md   | Cline, Amazon Q, Zed        |
| AGENTS.md      | Copied as `00-context.md` in rules directory     | Cline, Amazon Q             |
| AGENTS.md      | Prepended before merged rules                    | Zed                         |
| Commands `.md` | `.toml` (prompt field, `!{}` syntax, `{{args}}`) | Gemini CLI                  |
| Commands `.md` | `.prompt.md`                                     | Copilot                     |
| Agents `.md`   | `.agent.md`                                      | Copilot                     |
| Agents `.md`   | `.toml` (developer_instructions field)           | Codex                       |
| Agents `.md`   | `.json` (Amazon Q CLI custom-agent)              | Amazon Q                    |
| Agents `.md`   | Safe OpenCode Markdown (`mode` + permissions)    | OpenCode                    |
| MCP `mcpServers` | OpenCode top-level `mcp` (`local` / `remote`)  | OpenCode                    |

You write everything in Markdown. AgentSync handles the rest.

## Models and Providers Are Not Tools

AgentSync targets coding tools and their filesystem formats, not model vendors. Kimi and GLM models used through Claude Code, Cline, or OpenCode continue to use that tool's target; there is deliberately no `glm.yaml` or `zai.yaml`.

- **Kimi model in another tool:** configure the provider with [Kimi's official third-party-agent setup](https://www.kimi.com/code/docs/en/third-party-tools/other-coding-agents), then keep syncing the existing Claude/Cline/OpenCode target. Use the `kimi` target only for the standalone Kimi Code CLI.
- **GLM Coding Plan:** authenticate Z.AI using its official [Claude Code](https://docs.z.ai/devpack/tool/claude) or [OpenCode](https://docs.z.ai/devpack/tool/opencode) flow. Keep API keys in the provider's credential store or environment, never in `.ai/src/`.
- **OpenCode MCP:** shared `.ai/src/mcp.json` is converted into OpenCode's top-level `mcp` map. Use `.ai/src/tools/opencode/mcp.json` for a divergent canonical server map. Move any existing `mcp` field out of `.ai/src/tools/opencode/settings.json` before enabling canonical MCP; `sync` and `doctor` name both files when ownership is ambiguous.
- **OpenCode hooks:** customize `.ai/src/tools/opencode/hooks.ts`; AgentSync owns only `.opencode/plugins/agentsync.ts` and preserves sibling plugins. Custom tools under `.opencode/tools/`, other plugins, themes, TUI preferences, and credentials remain tool-owned.
- **Kimi hooks and agents:** Kimi Code exposes built-in agents but no project custom-agent surface. Its hooks live globally in `$KIMI_CODE_HOME/config.toml`, so AgentSync intentionally leaves that file untouched.

```bash
agentsync enable kimi opencode     # enable the standalone coding tools
agentsync sync

npx @z_ai/coding-helper           # configure GLM in an existing supported tool
opencode auth login               # choose Z.AI Coding Plan for OpenCode
```

## Adding a New Tool

```bash
cp .ai/src/tools/_TEMPLATE.yaml .ai/src/tools/newtool.yaml
# Edit newtool.yaml, then:
agentsync sync --only newtool
```

## Automation

Generated outputs regenerate from `.ai/src/`, so they go stale whenever you edit the source (or pull a teammate's change) and forget to re-sync. Three mechanisms keep them current without you remembering — pick whichever fits your workflow (they compose).

### Shell hook (most hands-off)

Add this to your `~/.zshrc` (or `~/.bashrc` with `bash`):

```bash
eval "$(agentsync shell-init zsh)"
```

This regenerates the hook from `agentsync` each session — the recommended form, since upgrades and fixes apply automatically without re-editing your rc (the same pattern as `direnv`, `starship`, and `zoxide`). The hook runs `agentsync sync --if-stale` when the current directory itself is an `.ai/` project root (including when a shell opens there). It does not walk up to a parent project while you navigate its descendants. The command is a no-op — and silent — when nothing changed. Set `AGENTSYNC_NO_AUTO_SYNC=1` to disable without removing the line.

Prefer to avoid the per-session `agentsync` call? Freeze a copy instead with `agentsync shell-init zsh >> ~/.zshrc`, but re-run it after each upgrade to pick up changes.

### Git hooks

```bash
agentsync setup-hooks                 # post-merge + post-checkout
agentsync setup-hooks --pre-commit    # also add a pre-commit hook
```

Runs `agentsync sync` automatically after `git pull` / `git checkout`, so pulling a teammate's `.ai/src/` change regenerates your outputs. `--pre-commit` adds a hook that runs `sync --if-stale` before each commit. Every hook is non-fatal: a failed sync warns but never blocks the git operation. Safe to run multiple times (the block is replaced in place).

### Manual / CI

```bash
agentsync sync --if-stale    # sync only if source changed since the last sync
agentsync check              # verify outputs match source (exit 0/1, CI gate)
```

`--if-stale` is the cheap probe the shell and pre-commit hooks build on; `check` is the authoritative drift gate for CI.

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
   - Syncs commands. Four modes pick the first that fits: native `dest` → `format: toml` → `as_skills` (writes `<skills.dest>/command-*/SKILL.md`) → `inline_into_agents` (appends `## Commands` index to AGENTS file)
   - Syncs subagents (with optional extension rename or MD→TOML)
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
│    → applied to every enabled tool with a compatible MCP target               │
│                                                                               │
│  agentsync customize <tool> <resource>                                        │
│    → for the rare case you need a per-tool override that differs from         │
│      the shared MCP map, or to materialize a payload enable --no-scaffold     │
│      skipped (`customize cursor hooks`)                                       │
└───────────────────────────────────────────────────────────────────────────────┘
```

**Mental model:**

- `enable` is the entry point. One command turns a tool on _and_ gives you the file to edit.
- Shared MCP is the default. `add mcp` writes canonical `mcpServers` to `.ai/src/mcp.json`; OpenCode converts that map and composes it with its settings atomically.
- `customize` is the escape hatch. Use it only when you need a per-tool override that diverges from the shared source, or when `enable --no-scaffold` skipped materializing a file you later want.

All three write to **`.ai/src/tools/<tool>/`** (per-tool) or **`.ai/src/mcp.json`** (shared). Nothing is scattered across `.ai/src/hooks/`, `.ai/src/mcp/`, `.ai/src/settings/` — the old flat layout is kept around for backward compatibility (see [migrate](#migrating-from-the-0-10-flat-layout)).

## How Resources Resolve

Every payload resource — tool YAML, hooks, MCP config, settings — follows the same layered lookup. Nothing is cloned into every project by default; overrides are opt-in and merge on top of a shipped base.

```
┌─ 1. Per-tool override ─────────┐   ┌─ 2. Shared MCP (mcp only) ──────┐   ┌─ 3. Shipped base ──────────────────────┐
│ .ai/src/tools/<tool>/          │   │ .ai/src/mcp.json                │   │ <install-dir>/lib/templates/<resource>/│
│   <resource>.<ext>             │►► │ (compatible MCP targets)        │►► │   <tool>.<ext>                         │
└────────────────────────────────┘   └─────────────────────────────────┘   └────────────────────────────────────────┘

     per-tool wins   →   shared fills in (for MCP)   →   base fills in otherwise
```

| Resource  | Base path                             | Per-tool override                     | Shared override    |
| --------- | ------------------------------------- | ------------------------------------- | ------------------ |
| tool YAML | `lib/templates/tools/<tool>.yaml`     | `.ai/src/tools/<tool>.yaml`           | —                  |
| hooks     | `lib/templates/hooks/<tool>.<ext>`    | `.ai/src/tools/<tool>/hooks.<ext>`    | —                  |
| mcp       | `lib/templates/mcp/<tool>.json`       | `.ai/src/tools/<tool>/mcp.json`       | `.ai/src/mcp.json` |
| settings  | `lib/templates/settings/<tool>.<ext>` | `.ai/src/tools/<tool>/settings.<ext>` | —                  |

The legacy flat-layout overrides (`.ai/src/hooks/<tool>.<ext>`, `.ai/src/mcp/<tool>.<ext>`, `.ai/src/settings/<tool>.<ext>`) from 0.10 and earlier are still read and still win over base, but print a one-shot deprecation warning. Run `agentsync migrate --apply` to move them into the canonical per-tool layout; the legacy paths may be dropped in a future release.

**Why it matters:**

- **Lean by default.** `agentsync init` creates `.ai/agent_sync.yaml`, `AGENTS.md`, and your chosen content sections — no pre-written hooks / MCP / settings for 13 tools you don't use.
- **Updates flow through.** Because the base lives in the install dir, `agentsync update` improves every project that hasn't locked the file in as an override.
- **Shared MCP is converted where schemas differ.** One `.ai/src/mcp.json` reaches every enabled MCP target. OpenCode's adapter validates local and remote transports, then atomically composes the result into `opencode.json`.
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

`migrate` also detects the pre-v0.6 monolithic `.agent/` (singular, no `s`) layout — a single directory holding `AGENTS.md`, `workflows/`, `rules/`, `skills/` without per-tool separation. The current engine doesn't recognise it, so a normal `sync` never cleans it up. Dry-run lists the contents; `--apply --yes` removes the directory. Detection runs alongside the flat-layout move logic, so a single `migrate --apply --yes` cleans up both in one pass.

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
agentsync adopt --all                            # adopt every drifted file at once
```

Resolves the destination back to its source file (`.ai/src/rules/core.md`), copies the edited content, and refreshes the manifest entry — the next `sync` is drift-free.

`--all` scans the manifest for every drifted (manually-edited) output and adopts them in one pass. Refused targets (below) are skipped and listed. If two edited outputs resolve to the same source with different content (e.g. `CLAUDE.md` and `GEMINI.md` both map back to `.ai/src/AGENTS.md`), both are skipped so neither silently clobbers the other — adopt one explicitly.

**Refused targets** (the round-trip would corrupt your source):

- Rules that get a frontmatter header (`cursor`, `copilot`, `windsurf`, `antigravity`) — adopting would push that tool's header into every other tool's rules.
- Rules merged into a single file (`zed`) — many sources collapsed into one dest can't be split back apart.
- Rules or skills inlined into AGENTS.md (rules: `codex`, `gemini`, `junie`, `kimi`, `opencode`; skills: `amazonq`, `cline`, `zed`).
- Format-converted output (`codex` subagents → TOML, `amazonq` subagents → JSON, `opencode` subagents → OpenCode Markdown).

For these, edit `.ai/src/` directly. AgentSync names the offending file when it refuses.

### Disabling sync for tools or categories

If you want to keep managing a tool manually, disable it in its YAML config:

```yaml
# .ai/src/tools/cursor.yaml
enabled: false
```

Or exclude it at sync time:

```bash
agentsync sync --skip cursor
```

To keep the tool enabled but omit one output category, set that target's
`enabled` flag to `false`. All other categories continue to sync normally:

```yaml
# .ai/src/tools/claude-hub.yaml
base: claude
targets:
  rules:
    enabled: false
```

This works for every entry under `targets:` and is useful when a `base:`
variant inherits a destination that another config should own.

## Workspaces — nested AgentSync projects

A parent project at `workspace/.ai/src/` with sub-projects below (`workspace/foo/.ai/src/`, `workspace/bar/.ai/src/`) is supported as a first-class workflow. Two patterns to manage shared content between the layers:

**Pattern A — declarative inheritance via `shared:`.** Each child project declares which categories it inherits from the parent. At sync time, AgentSync builds a transient shadow `.ai/src/` (child + parent fillers, child wins on collisions) and materialises the result into every enabled tool's output — works for tools without parent-loading (Codex, Cursor, JetBrains Junie) and tools with it (Claude Code) equally. Inherited files are never written into the child's `.ai/src/`; they live only in the shadow tree during a single sync run.

```yaml
# child/.ai/agent_sync.yaml
shared:
  path: "../"
  inherit: rules,skills,commands,agents
```

**Pattern B — interactive cleanup via `dedupe`.** When child and parent both have the same source file (a copy-paste duplicate), `dedupe` compares them by hash:

```bash
agentsync dedupe                  # walk up to nearest parent .ai/src/ (bounded by git boundary)
agentsync dedupe --against ../    # explicit parent path
agentsync dedupe --workspace      # bottom-up alphabetical fan-out across every nested .ai/
agentsync dedupe --yes            # non-interactive: delete identical-hash dupes, leave divergent
```

Identical-hash files become a `[d]elete / [k]eep / [v]iew` prompt; for shipped templates the deletion also writes a `template_overrides.declined` entry so `refresh` won't re-offer the file. Divergent files (same path, different content) show a diff and leave the decision to the human — dedupe never auto-resolves a divergence.

**Detection — `agentsync doctor`.** Doctor walks up to the nearest parent `.ai/src/` (same boundary as dedupe) and flags identical-hash duplicates as advisories and divergent files as info. Rules and skills marked with `category: governance` in their frontmatter are upgraded to advisories when divergent, with explicit "likely a mistake, not an override" framing. All cross-project findings are exit-code-0 advisories — visible during interactive runs, invisible to CI gates, so pre-commit hooks running `doctor` don't break on workspace techdebt.

**Workspace-wide sync.** `agentsync sync --workspace` runs `sync` in every AgentSync-managed `.ai/` below cwd, bottom-up alphabetical (deeper paths first; siblings sorted by `LC_ALL=C` for reproducibility). Continues past per-project failures; reports max exit code at the end. All other sync options (`--only`, `--skip`, `--profile`, `--dry-run`, `--force`) forward to each per-project invocation.

The walk-up logic stops at the start's git repository boundary, so a child project with its own `.git` never picks up an unrelated parent `.ai/src/` from above the boundary.

## Profiles — multiple config homes per tool

Sync from `$HOME` and juggle more than one account for the same tool — a work Claude and a personal Claude? A **profile** generates a second, self-contained config home (`~/.claude-hub/` next to your personal `~/.claude/`) whose content is the base `.ai/src/` plus profile-only extras. Shared rules stay shared; work-only rules and MCP servers live in the profile.

```bash
agentsync profile add hub                       # scaffold a "hub" profile for every enabled tool
agentsync profile add hub --tools claude,codex  # ...or just these tools
agentsync profile add hub --adopt               # pull an existing ~/.claude-hub/ into the profile first
agentsync profile list                          # show profiles, their tools, and config homes
agentsync profile remove hub                    # delete the config-home output and the profile
```

`profile add` writes three things: a thin variant tool `.ai/src/tools/<tool>-hub.yaml` that inherits everything from the base tool via `base:` and only overrides the dest paths, an overlay directory `.ai/profiles/hub/src/` for profile-only content (rules, skills, commands, agents, AGENTS.md — profile wins on collisions), and a `profiles:` block in `agent_sync.yaml`.

On sync, `agentsync sync` builds every `active` profile alongside your personal tools; `agentsync sync --profile hub` builds just that one. The per-profile overlay layers over the base — and over an active `shared:` overlay if you have one, so the two compose. Run the result with the tool's config-home variable, for example `CLAUDE_CONFIG_DIR=~/.claude-hub claude`. Profile outputs are gitignored and drift-protected like any other generated file.

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
