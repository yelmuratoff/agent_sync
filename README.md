<div align="center">
  <img src="https://github.com/yelmuratoff/agent_sync/blob/main/assets/agent_sync.png?raw=true" width="400">

  <p><strong>Configuration sync workspace/library for centralizing AI agent instructions</strong></p>

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

## What is AgentSync (`agent_sync`) Engine?

AgentSync is a configuration sync workspace/library that centralizes AI agent instructions in one source and syncs them to tool-specific formats.

## Table of Contents

- [Source of Truth](#source-of-truth)
- [Tool Targets](#tool-targets)
- [Workflow](#workflow)
- [Git Hooks](#git-hooks-recommended)
- [Gitignore Behavior](#gitignore-behavior)
- [Documentation Map](#documentation-map)

## Source of Truth

Edit only `.ai/src/`.
Do not edit generated tool folders directly (`.agent/`, `.claude/`, `.gemini/`, `.github/`).

```text
.ai/
├── src/                  # Authoring source (edit here)
│   ├── AGENTS.md
│   ├── rules/*.md
│   ├── skills/*/SKILL.md
│   └── tools/*.yaml        # Tool enable/disable + targets (edit here)
├── system/               # Sync engine
│   ├── sync.sh
│   ├── setup_hooks.sh
│   ├── check.sh
│   └── config.yaml
└── README.md             # Authoring guide
```

## Tool Targets

Enabled tools are defined in `.ai/src/tools/*.yaml`.

## Workflow

1. Edit source files in `.ai/src/`.
2. Run sync:

```bash
.ai/system/sync.sh
```

3. Optional preview:

```bash
.ai/system/sync.sh --dry-run
```

4. Optional partial sync:

```bash
.ai/system/sync.sh --only claude,copilot
.ai/system/sync.sh --skip gemini
```

## Git Hooks (Recommended)

Install once:

```bash
.ai/system/setup_hooks.sh
```

This installs `post-merge` and `post-checkout` hooks that run `.ai/system/sync.sh` automatically.

## Gitignore Behavior

`sync.sh` updates the block between:

- `# --- AI SYNC GENERATED START ---`
- `# --- AI SYNC GENERATED END ---`

This block is rebuilt from enabled tool targets in `.ai/src/tools/*.yaml`.

## Documentation Map

- Authoring rules and conventions: `.ai/README.md`
- Sync engine details and YAML schema: `.ai/system/README.md`

---

<div align="center">
  <p>Made with ❤️ for devs</p>
  <a href="https://github.com/yelmuratoff/agent_sync/graphs/contributors">
    <img src="https://contrib.rocks/image?repo=yelmuratoff/agent_sync" />
  </a>
</div>
