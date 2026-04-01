I need you to generate AI agent configuration files for my project using the AgentSync format.

AgentSync keeps all AI instructions in `.ai/src/` and distributes them to tool-specific directories (Claude, Cursor, Copilot, Gemini, Codex, Windsurf, Junie, Amp, Aider, Cline, Amazon Q, Augment, Devin, Tabnine, Zed, Continue) via `agentsync sync`. Your job is to study my project and produce tailored, specific configuration.

## How to start

If I haven't provided project context above, start by analyzing the codebase:

- Read the project structure, entry points, config files (`package.json`, `pubspec.yaml`, `go.mod`, `Cargo.toml`, etc.)
- Identify the tech stack, frameworks, and key dependencies
- Study existing code patterns: architecture, naming, error handling, testing
- Check for existing linter configs, CI pipelines, and documentation

If I provided a URL, description, or specific topic — use that as context for generation.

## What to generate

### 1. `.ai/src/AGENTS.md` — Agent Identity

The main file describing who the AI agent is. Be specific to this project:

- Role (e.g., "Senior React/TypeScript Engineer", "Backend Go Developer")
- Tech stack summary
- Approach: how the agent should work in this codebase (study → plan → implement → verify)
- Key principles specific to this project
- What the agent must never do

40–70 lines. Every sentence should change behavior. No generic filler.

### 2. `.ai/src/rules/` — Always-On Constraints

One `.md` file per topic. Rules are short, imperative, specific to this project.

20–50 lines per file. If a file grows beyond that, it likely covers two topics — split it. One focused rule file is more useful than one large catch-all.

Create only what's relevant. Possible files:

- `architecture.md` — layers, boundaries, dependency direction, module structure
- `testing.md` — what to test, frameworks, patterns, coverage expectations
- `code-style.md` — naming, formatting, idioms specific to this stack
- `error-handling.md` — how errors are handled in this codebase
- `security.md` — project-specific security requirements
- `dependencies.md` — how packages are managed
- `git.md` — commit style, branching, PR conventions

Format:

```markdown
# Topic Rules

## Section

- Specific imperative constraint.
- Another constraint.

## Anti-Patterns

- What not to do.
```

### 3. `.ai/src/skills/` — On-Demand Recipes

50–100 lines per skill. Skills can be more detailed since they're loaded on demand, but if a skill grows beyond that, it's likely two separate workflows — split by responsibility. One focused skill triggers reliably; a bloated one becomes noise.

Each skill = a directory with `SKILL.md`. Think about what developers do repeatedly:

- Adding a feature/module following the project's architecture
- Writing tests using the project's test setup
- Creating API endpoints, database migrations, deployments
- Any project-specific workflow

Format:

```markdown
---
name: skill-name
description: >
  What this skill does.
  USE WHEN [concrete trigger conditions — be specific so the agent can match].
---

# Skill Name

[One line: what and when.]

## Steps

1. [Concrete step with real commands/paths from this project]
2. [Next step]

## Gotchas

- [Common mistakes and edge cases for this workflow]
- [Things the agent might get wrong]
```

**Critical for skills:**

- The `description` is a TRIGGER, not a summary. The agent scans descriptions to decide which skill to use. Vague descriptions = invisible skills. Always include `USE WHEN` with specific conditions.
- The `Gotchas` section prevents repeated mistakes. Include at least 2-3 gotchas per skill based on what could go wrong in this project.
- Don't create a skill for everything — only for workflows that happen repeatedly.

### 4. `.ai/src/commands/` — Custom Slash Commands

15–40 lines per command. A command is a focused prompt for one workflow — not a tutorial. Commands are `.md` files that become slash commands (e.g., `review.md` → `/project:review` in Claude Code). Create commands for the 2-3 most common workflows in this project.

Format:

```markdown
---
description: What this command does (shown in command list)
argument-hint: "<optional-arg>"
---

[Prompt content. Can use $ARGUMENTS for parameters and !`shell command` for embedded output.]
```

Good commands for most projects:

- `review.md` — review current branch changes
- `fix-issue.md` — investigate and fix a GitHub issue
- Project-specific: `deploy.md`, `migrate.md`, `release.md`, etc.

Only generate commands relevant to this project's actual workflows.

### 5. `.ai/src/agents/` — Subagent Personas

30–70 lines per agent. Enough to define the role, scope, and constraints clearly — no more. Agents are `.md` files that define specialized AI personas for focused tasks. They run in isolated contexts with restricted tool access.

Format:

```markdown
---
name: agent-name
description: >
  What this agent specializes in.
  USE PROACTIVELY when [trigger conditions].
model: sonnet
tools:
  - Read
  - Grep
  - Glob
---

You are a [specialized role]...

[Specific instructions for this agent's domain.]
```

Only create agents if the project has distinct domains that benefit from specialization:

- `code-reviewer.md` — code review specialist (useful for most projects)
- `security-auditor.md` — security-focused review (for projects with auth/payments)
- `db-specialist.md` — database migration/query expert (for data-heavy projects)

### 6. `.ai/src/settings/claude.json` — Permissions (Claude Code)

Generate a Claude Code settings file with appropriate allow/deny rules for this project's tech stack:

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "permissions": {
    "allow": ["Bash(project-specific-commands)", "Read", "Write", "Edit"],
    "deny": ["Bash(rm -rf *)", "Read(.env)", "Read(.env.*)"]
  }
}
```

Customize allow/deny based on:

- The project's build/test/lint commands (`npm run *`, `make *`, `cargo *`, etc.)
- Safe git commands (`git status`, `git diff *`, `git log *`)
- Dangerous operations to block (`rm -rf`, `curl`, direct DB access in prod)
- Sensitive files to protect (`.env`, credentials, secrets)

## Output format

Output each file with its full path as a header:

### `.ai/src/AGENTS.md`

```markdown
[content]
```

### `.ai/src/rules/[name].md`

```markdown
[content]
```

### `.ai/src/skills/[name]/SKILL.md`

```markdown
[content]
```

### `.ai/src/commands/[name].md`

```markdown
[content]
```

### `.ai/src/agents/[name].md`

```markdown
[content]
```

### `.ai/src/settings/claude.json`

```json
[content]
```

## Critical rules

- Be specific to THIS project. Use real file paths, real commands, real patterns.
- If you don't see evidence of something in the code, don't write a rule about it.
- 5 specific rules > 20 vague rules. Quality over quantity.
- Skills and commands must have real commands and paths, not placeholders.
- Don't generate rules that just restate language defaults or framework documentation.
- Don't generate agents for domains that don't exist in this project.
- Settings should reflect this project's actual toolchain, not generic defaults.
