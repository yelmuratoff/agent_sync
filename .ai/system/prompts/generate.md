You are helping me configure AI agent instructions for my project using AgentSync.

AgentSync stores all AI instructions in `.ai/src/` and distributes them to tool-specific directories (Claude, Cursor, Copilot, Gemini, Codex) via `agentsync sync`.

## Your Task

Analyze this project's codebase and generate tailored content for the following files. Study the code, architecture, dependencies, conventions, and patterns before writing anything.

## What to Generate

### 1. `.ai/src/AGENTS.md` — Agent Identity

This is the main file describing who the AI agent is for this project. Write it specifically for this codebase:
- What role should the agent play? (e.g., "Senior React Engineer", "Backend Go Developer")
- What's the project's tech stack?
- What approach should the agent follow when working in this codebase?
- What principles matter most for this project?
- What should the agent never do in this project?

Keep it under 60 lines. Every sentence should change how the agent behaves. No generic advice.

### 2. `.ai/src/rules/` — Always-On Constraints

Create one `.md` file per concern. Rules are short, imperative, and specific to this project. Examples of good rule files:
- `architecture.md` — layer boundaries, dependency direction, module structure
- `testing.md` — what to test, how to test, what framework/style to use
- `code-style.md` — naming, formatting, patterns specific to this project
- `security.md` — project-specific security requirements
- `error-handling.md` — how errors are handled in this codebase
- `dependencies.md` — package management conventions

Only create rules that are relevant to this project. Don't generate rules for things that don't apply.

Each rule file format:
```markdown
# Topic Rules

## Section
- Specific, imperative constraint.
- Another constraint.

## Anti-Patterns
- What not to do.
```

### 3. `.ai/src/skills/` — On-Demand Recipes

Create skill directories for common workflows in this project. Each skill is a directory with a `SKILL.md` file.

Think about what developers do repeatedly in this project:
- Adding a new feature/module (following the project's architecture)
- Writing tests (using the project's test setup)
- Creating API endpoints (if applicable)
- Database migrations (if applicable)
- Deployment steps (if applicable)

Each SKILL.md format:
```markdown
---
name: skill-name
description: One sentence describing when to use this skill.
---

# Skill Name

## When to use
[When this skill applies]

## Steps
1. [Concrete step with actual commands/file paths from this project]
2. [Next step]
...
```

## Output Format

Output each file with its path as a header:

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

## Important

- Be specific to THIS project. Reference actual file paths, commands, frameworks, and patterns you see.
- Don't generate generic advice. If you can't find evidence of a pattern in the code, don't write a rule about it.
- Keep rules short and scannable. Prefer 5 specific rules over 20 vague ones.
- Skills should include real commands and paths from this project, not placeholders.
