<div align="center">
  <img src="https://github.com/yelmuratoff/agent_sync/blob/main/assets/agent_sync.png?raw=true" width="400">

  <p><strong>Write AI agent instructions once. Sync to every tool.</strong></p>

  <p>
    <a href="https://github.com/yelmuratoff/agent_sync">
      <img src="https://img.shields.io/badge/shell-bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white" alt="Built with Bash">
    </a>
    <a href="https://opensource.org/licenses/MIT">
      <img src="https://img.shields.io/badge/license-mit-4EAA25?style=for-the-badge" alt="License">
    </a>
    <a href="https://github.com/yelmuratoff/agent_sync">
      <img src="https://img.shields.io/github/stars/yelmuratoff/agent_sync?style=for-the-badge&logo=github&color=4EAA25" alt="GitHub stars">
    </a>
  </p>
</div>

## What is AgentSync?

AgentSync keeps your AI agent instructions in **one place** and syncs them to every tool you use — Claude, Copilot, Cursor, Gemini, Codex, and more.

**The problem**: Each AI tool wants instructions in a different format and location (`.claude/`, `.github/`, `.cursor/`, `.gemini/`...). Keeping them in sync manually is painful.

**The solution**: Write once in `.ai/src/`, run `agentsync sync`, done.

## Quick Start

### Install (one command)

```bash
curl -fsSL https://raw.githubusercontent.com/yelmuratoff/agent_sync/main/agent/install.sh | bash
```

This installs the `agentsync` CLI globally. Requirements: `git` and `bash`.

### Set up your project

```bash
cd your-project
agentsync init
```

This creates the `.ai/` structure with starter templates:

```text
.ai/
├── src/
│   ├── AGENTS.md           ← Agent identity & mindset
│   ├── rules/              ← Always-on constraints
│   │   └── core.md
│   ├── skills/             ← On-demand recipes
│   │   └── example/SKILL.md
│   └── tools/              ← Which tools to sync to
│       ├── claude.yaml
│       ├── copilot.yaml
│       ├── cursor.yaml
│       ├── gemini.yaml
│       └── codex.yaml
└── system/                 ← Sync engine (don't edit)
```

### Sync

```bash
agentsync sync
```

That's it. Your instructions are now distributed to all enabled tools.

## CLI Reference

```
agentsync <command> [options]

Commands:
  init           Create .ai/ structure in current project
  sync           Sync instructions to all enabled tools
  check          Verify outputs are in sync with source
  setup-hooks    Install git hooks for automatic sync
  list           Show configured tools and their status
  version        Print version
  help           Show help

Sync Options:
  --only <tools>    Sync only these tools (comma-separated)
  --skip <tools>    Skip these tools (comma-separated)
  --dry-run         Preview changes without writing
```

### Examples

```bash
# Initialize a new project
agentsync init

# Sync all enabled tools
agentsync sync

# Preview what would change
agentsync sync --dry-run

# Sync only Claude and Cursor
agentsync sync --only claude,cursor

# Sync everything except Gemini
agentsync sync --skip gemini

# Check if outputs are up to date
agentsync check

# Install git hooks (auto-sync on pull/checkout)
agentsync setup-hooks

# See which tools are configured
agentsync list
```

## How It Works

### Source of Truth

You edit **only** `.ai/src/`. Everything else is generated.

| You write | Tools get |
|-----------|-----------|
| `.ai/src/AGENTS.md` | `.claude/CLAUDE.md`, `.cursor/AGENTS.md`, `.github/copilot-instructions.md`, ... |
| `.ai/src/rules/*.md` | `.claude/rules/`, `.cursor/rules/*.mdc`, `.github/instructions/`, ... |
| `.ai/src/skills/*/SKILL.md` | `.claude/skills/`, `.cursor/skills/`, ... |

### Tool Configurations

Each tool has a YAML config in `.ai/src/tools/`:

```yaml
# .ai/src/tools/claude.yaml
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

See `.ai/src/tools/_TEMPLATE.yaml` for all available options (extensions, headers, filters, etc.).

### Supported Tools

| Tool | Config file | What's generated |
|------|-------------|------------------|
| Claude Code | `claude.yaml` | `.claude/CLAUDE.md`, `.claude/rules/`, `.claude/skills/` |
| GitHub Copilot | `copilot.yaml` | `.github/copilot-instructions.md`, `.github/instructions/`, `.github/skills/` |
| Cursor | `cursor.yaml` | `.cursor/AGENTS.md`, `.cursor/rules/*.mdc`, `.cursor/skills/` |
| Gemini CLI | `gemini.yaml` | `.gemini/GEMINI.md`, `.gemini/prompts/`, `.gemini/skills/` |
| OpenAI Codex | `codex.yaml` | `.codex/AGENTS.md`, `.codex/prompts/`, `.codex/skills/` |

Add your own tools by copying `_TEMPLATE.yaml`.

## Git Hooks (Recommended)

```bash
agentsync setup-hooks
```

Installs `post-merge` and `post-checkout` hooks. Your instructions auto-sync whenever you `git pull` or switch branches.

## Gitignore

`agentsync sync` automatically manages a block in `.gitignore` for generated files:

```
# --- AI SYNC GENERATED START ---
# Automatically generated by .ai/system/sync.sh
.claude/CLAUDE.md
.claude/rules/
.claude/skills/
...
# --- AI SYNC GENERATED END ---
```

## Uninstall

```bash
rm -rf ~/.agentsync && rm -f /usr/local/bin/agentsync
```

## Documentation

- Authoring guide: `.ai/README.md`
- Sync engine & YAML schema: `.ai/system/README.md`

---

<div align="center">
  <p>Made with ❤️ for devs</p>
  <a href="https://github.com/yelmuratoff/agent_sync/graphs/contributors">
    <img src="https://contrib.rocks/image?repo=yelmuratoff/agent_sync" />
  </a>
</div>
