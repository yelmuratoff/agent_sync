I need you to generate AI agent configuration files for my project using the AgentSync format.

AgentSync keeps all AI instructions in `.ai/src/` and distributes them to tool-specific directories (Claude, Cursor, Copilot, Gemini, Codex, Windsurf, Junie, Aider, Cline, Amazon Q, Augment, Zed, Continue, Antigravity) via `agentsync sync`. Your job is to study my project and produce tailored, specific configuration.

## How to start

If I haven't provided project context above, start by analyzing the codebase:

- Read the project structure, entry points, config files (`package.json`, `pubspec.yaml`, `go.mod`, `Cargo.toml`, etc.)
- Identify the tech stack, frameworks, and key dependencies
- Study existing code patterns: architecture, naming, error handling, testing
- Check for existing linter configs, CI pipelines, and documentation

If I provided a URL, description, or specific topic — use that as context for generation.

## Universal principles (apply to every artifact below)

These come from the agentskills.io best-practices guide and Anthropic prompt-engineering guidance. They apply to AGENTS.md, rules, skills, commands, and agents alike — not just one section.

- **Add what the agent lacks; omit what it knows.** The agent already knows what HTTP is, how `git` works, and what DRY means. Useful content is project-specific: schema quirks, naming conventions, workarounds for known bugs, the team's preferred library when several would work. If the answer to "would the agent get this wrong without this instruction?" is no, cut it.
- **Procedures over declarations.** Teach how to approach a class of problems, not the answer to one specific instance. "Read the schema, then join on the `_id` foreign key convention" generalizes; "join `orders` to `customers` on `customer_id`" doesn't.
- **Defaults, not menus.** Pick one tool/library/approach and mention alternatives briefly. "Use `pdfplumber`; fall back to `pdf2image` for scanned PDFs" beats listing four equal options.
- **Match specificity to fragility.** Be prescriptive on fragile sequence-sensitive ops ("run exactly: `python migrate.py --verify --backup`"). Be descriptive on flexible work ("look for SQL injection, weak auth, race conditions") and let the agent's judgment fill in.
- **Rule of three for skills.** Don't create a skill until you've manually done the workflow at least three times. Earlier than that, you don't yet know its shape — and a poorly-scoped skill that loads on every task is worse than no skill.
- **Soften aggressive language.** Modern Claude (Opus 4.6+) over-complies with `MUST` / `NEVER` / `ALWAYS` / `CRITICAL`. Prefer "use when…", "do not", "prefer X". Save emphasis for the genuinely fragile rules.

## What to generate

### 1. `.ai/src/AGENTS.md` — Agent Identity

The main file describing who the AI agent is. Be specific to this project:

- Role (e.g., "Senior React/TypeScript Engineer", "Backend Go Developer")
- Tech stack summary — include what NOT to use when there's a real risk of the agent reaching for it (e.g., "no Redux", "no styled-components")
- What the product optimizes for — 2–4 lines of business context that shape implementation tradeoffs (e.g., "B2B analytics dashboard, primary goal: reduce time-to-insight"). Skip marketing copy and origin stories.
- Approach: how the agent should work in this codebase (study → plan → implement → verify)
- Commands — the actual install/dev/build/lint/test commands the project uses. Only include what's real and current.
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
- `ui.md` — for frontend projects: design-system primitives, spacing rhythm, typography hierarchy, required interactive states (hover/focus/disabled), accessibility expectations
- `placement.md` — where new files/components go, when to extract a shared abstraction vs. edit in place, naming patterns. Stops repo drift in mature codebases.
- `safe-changes.md` — what not to modify casually (public API routes, DB schema, auth flows, shared component contracts). Preserves backward compatibility and forces the agent to flag risky edits.

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

Each skill = a directory with `SKILL.md`. Skills follow the open [agentskills.io](https://agentskills.io) format. Hard limits: `name` ≤64 chars (lowercase letters/digits/hyphens, must match folder name); `description` ≤1024 chars; `SKILL.md` body ≤500 lines / ≤5000 tokens. Move detail beyond that into `references/` (docs read on demand), `scripts/` (executable code), or `assets/` (templates).

Think about what developers do repeatedly in this project:

- Adding a feature/module following the project's architecture
- Writing tests using the project's test setup
- Creating API endpoints, database migrations, deployments
- Any project-specific workflow

Format:

```markdown
---
name: skill-name
description: One imperative sentence on what the skill does + concrete trigger conditions, including phrasings the user might use without naming the domain. Stay under 1024 chars.
---

# Skill Name

[One line: what and when.]

## Bundled references (load on demand)        # Optional, only if you have references/

- `references/X.md` — read when [concrete trigger condition]

## Steps

1. [Concrete step with real commands/paths from this project]
2. [Next step]

## Gotchas

- [Common mistakes and edge cases for this workflow]
- [Things the agent might get wrong]
```

**Critical for skills:**

- The `description` is a TRIGGER. Discovery is the only thing the agent sees at startup, so vague = invisible. Make it imperative ("Use this skill when…"), pushy (list cases where the user doesn't name the domain — "even when phrased as 'this is broken' or 'почему падает'"), and keyword-rich. Stay under 1024 chars.
- `Gotchas` is the single highest-leverage section — concrete corrections to wrong assumptions ("the `users` table uses soft deletes; queries must include `WHERE deleted_at IS NULL`"), not generic advice. Include 2-3 based on what could actually go wrong in this project; update it every time the agent makes a mistake using the skill.
- **Aim for 50–150 lines** when the workflow is simple. Cap at 500 lines / 5000 tokens hard. Beyond that, move detail to `references/<topic>.md` and load it with an explicit trigger ("read `references/X.md` when Y") — not a vague "see references/".
- Apply the Universal principles above (add-what-agent-lacks, procedures-over-declarations, defaults-not-menus, match-specificity-to-fragility) — they matter most for skills.

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
- Don't restate language defaults, framework documentation, or general programming wisdom — the agent already knows.
- Don't create skills for workflows you can't show happen 3+ times in this codebase.
- Don't create agents for domains that don't exist here.
- Skills and commands must have real commands and paths, not placeholders.
- Settings should reflect this project's actual toolchain, not generic defaults.
- Soften `MUST`/`NEVER`/`ALWAYS`/`CRITICAL` to `use when`/`do not`/`prefer` — modern Claude over-complies with aggressive language.
