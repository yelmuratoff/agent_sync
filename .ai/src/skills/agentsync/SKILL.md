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

## Claude Code: settings.json Reference

Edit `.ai/src/settings/claude.json` — synced to `.claude/settings.json`. Top-level fields:

- `model` — `"sonnet"`, `"opus"`, or `"haiku"`. Sets the default for the project.
- `includeCoAuthoredBy` — adds `Co-Authored-By: Claude` to commits Claude makes.
- `env` — environment variables exposed to Claude Code (`{ "DEBUG": "true" }`).
- `permissions` — `{ allow, ask, deny, defaultMode, additionalDirectories }`. Modes: `default`, `acceptEdits`, `plan`, `bypassPermissions`.
- `enableAllProjectMcpServers` / `enabledMcpjsonServers` / `disabledMcpjsonServers` — gate which `.mcp.json` servers load.
- `statusLine` — `{ "type": "command", "command": "your-script.sh" }` renders a custom status line.
- `outputStyle` — name of an output style (`engineer`, `explanatory`, `learning`, or a custom one in `.claude/output-styles/`).
- `hooks` — event handlers (see below).

### Hooks across tools

Four tools have native hooks APIs. AgentSync syncs each to its canonical location:

| Tool           | Source in `.ai/src/`                         | Destination                | Event naming                                                                                                          |
| -------------- | -------------------------------------------- | -------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Claude Code    | `settings/claude.json` (under `"hooks"` key) | `.claude/settings.json`    | `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `SessionStart`, `Stop`, `SubagentStop`, `Notification`, `PreCompact` |
| Cursor         | `hooks/cursor.json`                          | `.cursor/hooks.json`       | `beforeShellExecution`, `beforeMCPExecution`, `beforeReadFile`, `afterFileEdit`, `beforeSubmitPrompt`, `stop`         |
| GitHub Copilot | `hooks/copilot.json`                         | `.github/hooks/hooks.json` | `sessionStart`, `sessionEnd`, `userPromptSubmitted`, `preToolUse`, `postToolUse`, `errorOccurred`                     |
| OpenAI Codex   | `hooks/codex.json`                           | `.codex/hooks.json`        | `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Stop`, `agent-turn-complete`                                        |
| Windsurf       | `hooks/windsurf.json`                        | `.windsurf/hooks.json`     | Cascade lifecycle events (see [docs](https://docs.windsurf.com/windsurf/cascade/hooks))                               |

Each tool's JSON schema is subtly different — AgentSync pass-through copies the file, it doesn't translate. Write the file per the target tool's spec.

### Claude Code hooks (inside settings.json)

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": ".claude/hooks/pre-bash.sh" }]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [{ "type": "command", "command": ".claude/hooks/format.sh" }]
      }
    ]
  }
}
```

Events: `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `SessionStart`, `Stop`, `SubagentStop`, `Notification`, `PreCompact`. Matchers are regex on tool names. Hooks return non-zero to block the action.

## Claude Code: .mcp.json Reference

Edit `.ai/src/mcp/claude.json` — synced to `.claude/.mcp.json`. Three transport types: `stdio`, `sse`, `http`.

```json
{
  "mcpServers": {
    "github": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": { "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}" }
    },
    "context7": {
      "type": "http",
      "url": "https://mcp.context7.com/mcp",
      "headers": { "Authorization": "Bearer ${CONTEXT7_API_KEY}" }
    }
  }
}
```

Use `${VAR}` for env-var expansion. Never inline secrets — keep them in shell env or a secret manager.

## Per-Rule Frontmatter Override

A rule file in `.ai/src/rules/<name>.md` may carry its own YAML frontmatter — sync **merges** it with the tool's default header (declared via `targets.rules.header` in the tool YAML). Source keys win on conflict; the tool header only fills in keys you didn't set.

This unblocks per-rule control:

- **Cursor**: override `globs` / `alwaysApply` / `description` per rule.
- **Copilot**: scope a rule with `applyTo: "**/*.ts"`.
- **Windsurf**: switch `trigger: model_decision` (or `glob` / `manual`) for specific rules.

Example — `.ai/src/rules/typescript.md`:

```markdown
---
globs: "**/*.ts"
description: "TypeScript-only conventions"
---
# TypeScript Rules
...
```

After sync to Cursor, the destination keeps `globs: "**/*.ts"` and `description`, plus inherits `alwaysApply: true` from the tool default.

## Gotchas

- Always edit in `.ai/src/`, never in output directories — they're overwritten by sync.
- Skill descriptions are TRIGGERS — vague descriptions make skills invisible. Always include `USE WHEN`.
- The YAML parser is custom and minimal — supports `key: value` and dot-notation only. No arrays, no multiline blocks.
- Tool-specific frontmatter fields (`context: fork`, `allowed-tools`) pass through as-is — agentsync doesn't validate them.
- Running `agentsync sync` is idempotent. Running it twice must produce identical output.
