---
name: agentsync
description: When creating or editing AgentSync configuration — rules, skills, AGENTS.md, or tool configs.
---

# Working with AgentSync

## When to use

When the user asks to add, edit, or organize AI agent instructions managed by AgentSync.

## Structure

```
.ai/
├── src/                    # Source of truth. Edit ONLY here.
│   ├── AGENTS.md           # Agent identity: role, approach, principles
│   ├── rules/              # Rules — always-on constraints (one topic per file)
│   ├── skills/             # Skills — on-demand step-by-step recipes
│   │   └── <name>/SKILL.md
│   └── tools/              # Tool configs (claude.yaml, cursor.yaml, etc.)
└── system/                 # Sync engine. Do not edit.
```

After editing, run `agentsync sync` to distribute to all tools.

## Writing AGENTS.md

This is the agent's identity — who it is and how it works. Keep it:
- **Focused** — Describe the role, approach, and principles. Not a rulebook.
- **Universal** — This goes to every tool. Don't include tool-specific syntax.
- **Actionable** — Every sentence should change how the agent behaves.

## Writing Rules

Rules are always-on constraints. One file per topic in `.ai/src/rules/`.

Guidelines:
- **One concern per file** — `testing.md`, `security.md`, `architecture.md`. Not `everything.md`.
- **Imperative and specific** — "Use `snake_case` for database columns" not "Follow naming conventions".
- **Constraints, not tutorials** — Rules say what to do and what not to do. They don't explain concepts.
- **Short** — Each rule file should be scannable in 30 seconds. If it's too long, split it.

Example structure:
```markdown
# Testing Rules

## Mandatory
- Write tests for business logic and error paths.
- Use Given/When/Then structure.
- Mock I/O boundaries (network, database, file system).

## Anti-Patterns
- Don't test framework internals.
- Don't share mutable state between tests.
```

## Writing Skills

Skills are on-demand recipes. Each skill is a directory with a `SKILL.md` file.

Guidelines:
- **Frontmatter required** — `name` and `description` fields. The description tells the agent *when* to use this skill.
- **Step-by-step** — Numbered steps the agent follows in order.
- **Concrete** — Include actual commands, file paths, and expected outputs.
- **Self-contained** — Each skill should work without reading other skills.

Example:
```markdown
---
name: deploy
description: When deploying the application to staging or production.
---
# Deploy
## Steps
1. Run tests: `npm test`
2. Build: `npm run build`
3. ...
```

## Adding a New Tool

1. Copy `.ai/src/tools/_TEMPLATE.yaml` to `.ai/src/tools/<tool>.yaml`.
2. Set `name`, `enabled: true`, and configure `targets` (where files go).
3. Run `agentsync sync --only <tool>` to test.
