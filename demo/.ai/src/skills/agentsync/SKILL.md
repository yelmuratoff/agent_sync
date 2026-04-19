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

## Scaffolding new content

Use `agentsync add <kind> <name>` to create a new file with the correct frontmatter and placement:

- `agentsync add rule <name>` — creates `.ai/src/rules/<name>.md`
- `agentsync add skill <name>` — creates `.ai/src/skills/<name>/SKILL.md`
- `agentsync add command <name>` — creates `.ai/src/commands/<name>.md`
- `agentsync add subagent <name>` — creates `.ai/src/agents/<name>.md`

The command refuses to overwrite existing files; pass `--force` (or `-f`) to replace them. Names must contain only letters, digits, hyphens, and underscores — no path separators, no `..`, no leading `.` or `-`.

## Writing AGENTS.md

The agent's identity. Every sentence should change behavior.

- **Be specific** — "Senior React/TypeScript Engineer" not "software engineer".
- **Include the stack** — The agent needs to know what it's working with.
- **Actionable principles** — "Prefer composition over inheritance" not "Write good code".
- **What NOT to do** — Constraints are often more useful than instructions.
- 40–70 lines. No generic filler.

## Writing Rules

Always-on constraints. One file per topic in `.ai/src/rules/`.

- **One concern per file** — `testing.md`, `security.md`. Not `everything.md`.
- **Imperative and specific** — "Use `snake_case` for DB columns" not "Follow naming conventions".
- **Constraints, not tutorials** — Say what to do and what not to do. Don't explain concepts.
- **20–50 lines per file** — If it grows beyond that, split by topic. Multiple small focused files beat one large catch-all.

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

### Size

50–100 lines per skill. Skills are loaded on demand so can be more detailed than rules, but if a skill grows beyond that, it's likely two separate workflows — split by responsibility.

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

## Updating and Resolving Upstream Drift

When you run `agentsync update`, the CLI snapshots the install-dir tool catalog
before pulling the new release, then compares it against the newly-pulled catalog
field-by-field. For every upstream change to a field you have overridden, the update
prints a warning and writes the list to `.ai/.pending-resolutions.yaml`:

```yaml
schema: 1
from_version: "0.7.0"
to_version: "0.8.0"
conflicts:
  - tool: "claude"
    field: "targets.rules.dest"
    base_before: ".claude/rules"
    base_after: ".claude/rules-v2"
    your_override: ".claude/my-rules"
```

- `agentsync resolve` reads this queue on startup and flags the affected fields
  with `⚡`. Walking through every override (not a subset with `resolve <tool>`)
  clears the queue automatically.
- Pass `--strict` to `agentsync update` to exit non-zero on any conflict — useful
  in CI to block a merge until someone reviews upstream changes.
- The file is non-authoritative: delete it any time if you prefer to ignore the
  warnings. Your overrides are untouched until you explicitly adopt a base value
  via `agentsync resolve`.

## Simplifying Redundant Overrides

After `agentsync customize <tool> --full`, an override carries the entire base
template verbatim. Over time those redundant fields pin stale values and silently
block upstream updates — if base moves forward, the redundant override wins and
you stay on the old value.

`agentsync simplify` walks every user override and drops fields that already
match the current base, leaving only the ones that actually diverge.

```
agentsync simplify              # dry-run every override
agentsync simplify cursor       # dry-run just one tool
agentsync simplify --apply      # persist changes
agentsync simplify --apply -y   # persist + auto-delete emptied files
```

- Dry-run by default — prints a preview of fields that would be removed and
  fields that would stay. Pass `--apply` to write.
- If every overridden field matches base, the entire override file is
  redundant. With `--apply -y` the file is deleted automatically; in an
  interactive shell without `-y` you're prompted.
- Idempotent: running with `--apply` twice in a row is a no-op the second time.
- Comments inside a user override are not preserved when a nearby field is
  removed — the line-level YAML mutator strips the key and any indented
  comments below it. If you rely on inline documentation, keep a separate
  note or use `agentsync show <tool>` to re-derive intent.

## Gotchas

- Always edit files in `.ai/src/`, never in generated directories (`.claude/`, `.cursor/`, etc.).
- Run `agentsync sync` after every change to distribute updates.
- Tool-specific frontmatter fields (like `context: fork`) are passed through as-is — agentsync doesn't validate them.
- Don't create overlapping skills — if two skills could trigger on the same task, merge them or make descriptions mutually exclusive.
- Commands and agents only work in tools that support them (Claude, Gemini for commands; Claude, Copilot for agents).
- Settings and MCP files are per-tool — each tool has its own format.
