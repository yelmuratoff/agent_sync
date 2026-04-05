---
name: agentsync
description: >
  Create or edit AgentSync configuration — rules, skills, commands, agents, settings, MCP, or tool configs.
  USE WHEN adding rules, creating skills, writing commands, defining agents, editing permissions, configuring tools, or setting up .ai/ directory.
---

# Working with AgentSync Configuration

Edit AI agent instructions in `.ai/src/`. After changes, run `agentsync sync` to distribute.

## Structure

```
.ai/src/
├── AGENTS.md                   # Agent identity (40–70 lines)
├── rules/                      # Always-on constraints (one .md per topic, 20–50 lines)
├── skills/                     # On-demand recipes (one dir per skill, 50–100 lines)
│   └── <name>/SKILL.md
├── commands/                   # Slash commands (.md files, 15–40 lines)
├── agents/                     # Subagent personas (.md files, 30–70 lines)
├── settings/                   # Tool permissions (JSON)
│   └── claude.json
├── mcp/                        # MCP server configs (JSON)
├── hooks/                      # Event hooks (JSON)
└── tools/                      # Tool sync configs (YAML)
    └── <tool>.yaml
```

## Steps

1. Identify what to create/edit — rule, skill, command, agent, or tool config.
2. Edit files only in `.ai/src/`. Never edit generated dirs (`.claude/`, `.cursor/`, etc.).
3. Follow format conventions:
   - Rules: imperative, one topic per file, 20–50 lines.
   - Skills: must have `description` with `USE WHEN` trigger clause, include `## Gotchas`.
   - Commands: frontmatter with `description`, use `$ARGUMENTS` and `` !`cmd` `` for dynamic content.
   - Agents: frontmatter with `name`, `description`, `model`, `tools` list.
   - Tools: copy `_TEMPLATE.yaml`, set `name`, `enabled`, and `targets`.
4. Run `agentsync sync` to distribute, or `agentsync sync --only <tool>` to test one tool.
5. Run `agentsync check` to verify outputs are in sync.

## Adding a New Tool

1. Copy `.ai/src/tools/_TEMPLATE.yaml` to `.ai/src/tools/<tool>.yaml`.
2. Set `name`, `enabled: true`, configure `targets` with `dest` paths.
3. Run `agentsync sync --only <tool>`.
4. Add bats tests in `tests/sync.bats` and `tests/sync_options.bats`.

## Gotchas

- Always edit in `.ai/src/`, never in output directories — they're overwritten by sync.
- Skill descriptions are TRIGGERS — vague descriptions make skills invisible. Always include `USE WHEN`.
- The YAML parser is custom and minimal — supports `key: value` and dot-notation only. No arrays, no multiline blocks.
- Tool-specific frontmatter fields (`context: fork`, `allowed-tools`) pass through as-is — agentsync doesn't validate them.
- Running `agentsync sync` is idempotent. Running it twice must produce identical output.
