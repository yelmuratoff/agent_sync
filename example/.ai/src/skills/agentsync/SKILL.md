---
name: agentsync
description: >
  Create or edit AgentSync configuration — rules, skills, commands, agents, settings, MCP, or tool configs.
  USE WHEN adding rules, creating skills, writing commands, defining agents, editing permissions, configuring tools, or setting up .ai/ directory.
---

# Working with AgentSync

Create and maintain AI agent instructions in the AgentSync format.

## Structure

```
.ai/src/                        # Source of truth. Edit ONLY here.
├── AGENTS.md                   # Agent identity: role, approach, principles
├── rules/                      # Always-on constraints (one file per topic)
│   ├── core.md
│   └── testing.md
├── skills/                     # On-demand recipes (one directory per skill)
│   └── deploy/
│       └── SKILL.md
├── commands/                   # Custom slash commands (.md files)
│   ├── review.md
│   └── fix-issue.md
├── agents/                     # Subagent personas (.md files)
│   └── code-reviewer.md
├── settings/                   # Tool-specific permissions (JSON)
│   └── claude.json
├── mcp/                        # MCP server configs (JSON)
│   └── claude.json
├── hooks/                      # Event hooks (JSON)
│   ├── cursor.json
│   └── codex.json
└── tools/                      # Tool configs (claude.yaml, cursor.yaml, etc.)
```

After editing, run `agentsync sync` to distribute to all tools.

## Writing AGENTS.md

The agent's identity. Every sentence should change behavior.

- **Be specific** — "Senior React/TypeScript Engineer" not "software engineer".
- **Include the stack** — The agent needs to know what it's working with.
- **Actionable principles** — "Prefer composition over inheritance" not "Write good code".
- **What NOT to do** — Constraints are often more useful than instructions.
- Under 60 lines. No generic filler.

## Writing Rules

Always-on constraints. One file per topic in `.ai/src/rules/`.

- **One concern per file** — `testing.md`, `security.md`. Not `everything.md`.
- **Imperative and specific** — "Use `snake_case` for DB columns" not "Follow naming conventions".
- **Constraints, not tutorials** — Say what to do and what not to do. Don't explain concepts.
- **Scannable in 30 seconds** — If too long, split it.

## Writing Skills — The Most Important Part

Skills are the highest-leverage configuration. A skill is a directory with a `SKILL.md`.

### The description is a TRIGGER, not a summary

The agent scans every skill description at startup. Vague = invisible.

Bad: `description: "Helps with testing"`
Good: `description: "Write unit and integration tests for new features. USE WHEN adding tests, writing test cases, or asked to verify behavior."`

Always include `USE WHEN` with concrete trigger conditions.

### Frontmatter fields

```yaml
---
name: skill-name # Required. Lowercase, kebab-case.
description: > # Required. Trigger description with USE WHEN clause.
  What this skill does.
  USE WHEN [concrete trigger conditions].


# Optional fields (tool-specific, passed through by agentsync):
# context: fork                 # Run in isolated subagent (Claude Code)
# allowed-tools: [Read, Grep]   # Limit available tools (Claude Code)
# paths: ["src/api/**"]         # Only activate for matching paths
---
```

### Structure of a good skill

```markdown
---
name: example
description: >
  [What it does]. USE WHEN [triggers].
---

# Skill Name

[One line: what this skill does and when.]

## Steps

1. [Concrete numbered steps]
2. [With real commands and paths]

## Gotchas

- [Every mistake the agent has made using this skill]
- [Edge cases and common pitfalls]
```

### The Gotchas section

This is the highest-signal content. Every time the agent makes a mistake, add it to Gotchas. This section prevents the same error from happening twice.

### Rule of Three

Don't create a skill for everything. If you've done something three times manually, then create a skill.

## Writing Commands

Custom slash commands. Each `.md` file in `.ai/src/commands/` becomes a command (e.g., `review.md` → `/project:review`).

```markdown
---
description: What this command does (shown in command list)
argument-hint: "<optional-arg>"
---

[Prompt content with instructions for the AI.]
```

Key features:

- `$ARGUMENTS` — replaced with text after the command name.
- `` !`shell command` `` — runs a shell command and embeds output into the prompt.
- Keep commands focused — one workflow per command.
- Good commands: `review`, `fix-issue`, `deploy`, `migrate`.

## Writing Agents (Subagent Personas)

Specialized AI personas in `.ai/src/agents/`. Each `.md` file defines an agent with its own system prompt and tool restrictions.

```markdown
---
name: code-reviewer
description: >
  Expert code reviewer. USE PROACTIVELY when reviewing PRs or validating implementations.
model: sonnet # Cheaper model for focused tasks
tools: [Read, Grep, Glob] # Restrict to read-only tools
---

You are a senior code reviewer...
```

Guidelines:

- Restrict `tools` to what the agent actually needs. Read-only agents shouldn't have Write.
- Use `model: sonnet` or `model: haiku` for focused tasks to save cost.
- Only create agents for distinct specializations — don't duplicate what skills already do.

## Settings & Permissions

Tool-specific settings in `.ai/src/settings/`. Each file is named after the tool and copied directly.

Example `claude.json`:

```json
{
  "permissions": {
    "allow": ["Bash(npm run *)", "Read", "Write", "Edit"],
    "deny": ["Bash(rm -rf *)", "Read(.env)"]
  }
}
```

## MCP Configs

MCP server configurations in `.ai/src/mcp/`. Each file is named after the tool.

Example `claude.json`:

```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["-y", "@anthropic/mcp-playwright"]
    }
  }
}
```

## Inline Options

For tools without separate rules/skills directories, use inline options:

- **`inline_into_agents: true`** (rules) — appends lightweight rule REFERENCES (name + title) to the agents file instead of syncing rules as separate files. Used by: Codex, Gemini.
- **`inline_into_agents: true`** (skills) — appends lightweight skill INDEX (name + description) to the agents file instead of syncing skills as directories. Used by: Junie, Cline, Amazon Q, Augment, Aider, Zed, Continue.
- **`prepend_agents: true`** (rules with `merge_to_file`) — prepends AGENTS.md content before merged rules in a single output file. Used by: Aider, Zed, Continue.
- **`00-context.md` pattern** — for directory-based tools without separate agents support, AGENTS.md is copied as `00-context.md` inside the rules directory. Used by: Cline, Amazon Q, Augment.

## Adding a New Tool

1. Copy `.ai/src/tools/_TEMPLATE.yaml` to `.ai/src/tools/<tool>.yaml`.
2. Set `name`, `enabled: true`, and configure `targets`.
3. Run `agentsync sync --only <tool>` to test.

## Gotchas

- Always edit files in `.ai/src/`, never in generated directories (`.claude/`, `.cursor/`, etc.).
- Run `agentsync sync` after every change to distribute updates.
- Tool-specific frontmatter fields (like `context: fork`) are passed through as-is — agentsync doesn't validate them.
- Don't create overlapping skills — if two skills could trigger on the same task, merge them or make descriptions mutually exclusive.
- Commands and agents only work in tools that support them (Claude, Gemini for commands; Claude, Copilot for agents).
- Settings and MCP files are per-tool — each tool has its own format.
