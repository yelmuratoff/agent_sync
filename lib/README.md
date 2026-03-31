# AgentSync Manual

`.ai/` is the authoring workspace for AgentSync (`agent_sync`) and all shared AI behavior in this repository.

## What to Edit

Edit:

- `.ai/src/AGENTS.md`
- `.ai/src/rules/*.md`
- `.ai/src/skills/*/SKILL.md`
- `.ai/src/tools/*.yaml`

Do not edit generated targets directly:

- `.agent/*`
- `.claude/*`
- `.gemini/*`
- `.github/copilot-instructions.md`
- `.github/instructions/*`
- `.github/skills/*`

## Directory Layout

```
.ai/
├── src/                    # Source of truth
│   ├── AGENTS.md
│   ├── rules/
│   ├── skills/
│   └── tools/
├── system/                 # Sync engine scripts
│   ├── sync.sh
│   ├── setup_hooks.sh
│   ├── check.sh
│   ├── config.yaml
│   └── lib/
├── docs/                   # Internal notes
└── tasks/                  # Task drafts / work items
```

## Authoring Model

### 1. `AGENTS.md` (Identity)

Use for:

- mindset
- decision principles
- quality bar
- response style

Avoid:

- large code snippets
- tool-specific file-path details

### 2. `rules/*.md` (Always-on Constraints)

Use for:

- strict boundaries
- conventions
- forbidden patterns
- architecture constraints

Conventions:

- one topic per file
- concise text
- no long implementation examples

### 3. `skills/*/SKILL.md` (On-demand Recipes)

Use for:

- step-by-step implementation workflows
- commands
- examples and templates

Typical skill format:

```markdown
---
name: skill-name
description: When this skill should be used.
---

# Skill Title

## When to use

## Steps
```

## Sync Workflow

From repo root:

```bash
.ai/system/sync.sh
```

Useful flags:

```bash
.ai/system/sync.sh --dry-run
.ai/system/sync.sh --only claude,copilot
.ai/system/sync.sh --skip gemini
```

Install hooks once:

```bash
.ai/system/setup_hooks.sh
```

This auto-runs sync after `git pull` (post-merge) and after `git checkout`.

## Notes

- `sync.sh` also updates the generated block in `.gitignore`.
- `check.sh` is available for sync verification workflows.
- Technical details and tool YAML schema are documented in `.ai/system/README.md`.
