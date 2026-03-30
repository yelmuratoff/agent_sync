I need you to generate AI agent configuration files for my project using the AgentSync format.

AgentSync keeps all AI instructions in `.ai/src/` and distributes them to tool-specific directories (Claude, Cursor, Copilot, Gemini, Codex) via `agentsync sync`. Your job is to study my project and produce tailored, specific configuration.

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

Under 60 lines. Every sentence should change behavior. No generic filler.

### 2. `.ai/src/rules/` — Always-On Constraints

One `.md` file per topic. Rules are short, imperative, specific to this project.

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

## Critical rules

- Be specific to THIS project. Use real file paths, real commands, real patterns.
- If you don't see evidence of something in the code, don't write a rule about it.
- 5 specific rules > 20 vague rules. Quality over quantity.
- Skills must have real commands and paths, not placeholders.
- Don't generate rules that just restate language defaults or framework documentation.
