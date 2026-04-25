---
name: agentsync
description: Create or edit AgentSync configuration — AGENTS.md, rules, skills, commands, subagents, settings, MCP servers, hooks, or per-tool configs. Use this skill when adding a rule, creating or scaffolding a skill, writing a slash command, defining a subagent persona, editing permissions, configuring an MCP server, setting up the `.ai/src/` directory, or running `agentsync sync` / `add` / `customize` / `resolve` / `simplify` — even when the user does not name "AgentSync" explicitly but is editing files in `.ai/src/`, `.claude/`, `.cursor/`, or another tool-config directory.
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

Skills are the highest-leverage configuration. AgentSync skills follow the open [agentskills.io](https://agentskills.io) format — a portable standard supported by Claude Code, Codex, Cursor, Copilot, Gemini CLI, OpenCode, and ~30 other agents. Validate any skill with `skills-ref validate <path>`.

### How skills load: progressive disclosure

Agents load skills in three stages, so design with each stage in mind:

1. **Discovery (~100 tokens, all skills):** the agent reads only `name` + `description` of every available skill at startup, deciding which might be relevant.
2. **Activation (≤5000 tokens, one skill):** when a task matches a description, the agent reads the full `SKILL.md` body.
3. **Resources (on demand):** files in `references/`, `scripts/`, and `assets/` load only when `SKILL.md` instructs the agent to read them.

**Implication:** keep `SKILL.md` lean. Move detail behind explicit triggers like *"Read `references/X.md` when the input is a multi-page PDF."*

### Skill directory layout

```
my-skill/
├── SKILL.md          # Required: frontmatter + instructions
├── references/       # Optional: docs read on demand (REFERENCE.md, etc.)
├── scripts/          # Optional: executable code (Python/Bash/JS) the agent runs
├── assets/           # Optional: templates, schemas, images
└── ...
```

Use **relative paths** from the skill root (`references/foo.md`, `scripts/bar.py`) and keep references **one level deep**.

### Frontmatter fields

```yaml
---
name: skill-name # Required. Must match the parent directory name.
description: One imperative sentence on what the skill does + concrete trigger conditions.
# Optional:
license: MIT
compatibility: Requires Python 3.12+ and uv
metadata:
  author: your-team
  version: "1.0"
allowed-tools: Bash(git:*) Read Grep   # Experimental; tool-specific.
---
```

**`name` constraints (hard):**

- 1–64 characters
- Lowercase letters, digits, and hyphens only — no `_`, no uppercase, no Unicode
- No leading or trailing hyphen, no consecutive `--`
- Must equal the parent directory name (`my-skill/SKILL.md` ↔ `name: my-skill`)

**`description` constraints (hard):**

- 1–1024 characters
- Must convey *both* what the skill does *and* when to use it

### Writing the description (the trigger)

The description is the only thing the agent sees during discovery. Vague = invisible.

- **Imperative phrasing.** "Use this skill when…" beats "This skill does…". The agent is deciding whether to act.
- **Focus on user intent, not internal mechanics.** Describe what the user is trying to achieve, not the steps the skill takes.
- **Be pushy.** Explicitly list contexts where the skill applies, *including ones where the user doesn't name the domain* ("even when phrased as 'this is broken' or 'почему падает'").
- **Pack relevant keywords** the user might say or type, including alternate phrasings.
- **Concise but full.** A few sentences usually beats one. Stay under 1024 chars.

Bad: `description: Helps with testing.`
Good: `description: Write or fix tests for a feature, bug, or regression — unit, integration, or end-to-end. Use this skill when the user adds tests, asks why a test fails, requests coverage, or describes verifying behaviour — even when "test" is implied (e.g. "make sure this works", "should we cover this case").`

For a deeper trigger-tuning workflow (eval queries, train/validation split, iterating the description), see [agentskills.io/skill-creation/optimizing-descriptions](https://agentskills.io/skill-creation/optimizing-descriptions).

### Structure of a good skill

```markdown
---
name: example-skill
description: <imperative + trigger conditions, 1–1024 chars>
---

# Skill Name

One line: what this skill does and when to invoke it.

## Bundled references (load on demand)        # Optional, only if you have references/

- `references/X.md` — read when [concrete trigger condition]
- `references/Y.md` — read when [concrete trigger condition]

## Steps                                       # The core procedure

1. Concrete numbered steps with real commands and paths.
2. Use imperative verbs.

## Output format / template                    # Optional, when format matters

\`\`\`
<concrete template the agent should fill in>
\`\`\`

## Gotchas                                     # The highest-signal section

- Every mistake the agent has made using this skill.
- Concrete corrections to wrong assumptions ("the `users` table uses soft deletes; queries must include `WHERE deleted_at IS NULL`").
- Edge cases and common pitfalls.
```

### Calibration principles (best practices)

These come straight from the [agentskills.io best-practices guide](https://agentskills.io/skill-creation/best-practices). Internalise them.

- **Add what the agent lacks; omit what it knows.** Don't explain what a PDF is, what HTTP does, or how `git` works. Jump straight to project-specific conventions, non-obvious edge cases, and the particular tools or APIs to use.
- **Procedures over declarations.** Teach *how to approach* a class of problems, not the answer to one specific instance. The procedure should generalise even when individual details are concrete.
- **Defaults, not menus.** Pick one tool/library/approach and mention alternatives briefly. "Use `pdfplumber`; fall back to `pdf2image` for scanned PDFs" beats listing four equal options.
- **Match specificity to fragility.** Be prescriptive on fragile, sequence-sensitive operations ("run exactly: `python migrate.py --verify --backup`"). Be descriptive on flexible work ("look for SQL injection, weak auth, race conditions") and let the agent's judgment fill in.
- **Aim for moderate detail.** Concise stepwise guidance with a working example beats exhaustive documentation. When you're tempted to cover every edge case, ask whether the agent can handle most by judgment.
- **Design coherent units.** A skill should encapsulate one workflow that composes well with others. Too narrow → many skills load for one task. Too broad → can't be activated precisely.

### Patterns for effective instructions

Pick the ones that fit your task; not every skill needs all.

- **Gotchas section.** Concrete corrections, not generic advice. Update every time the agent makes a mistake using the skill — this is the single highest-leverage section to maintain.
- **Output templates.** When format matters, show a concrete template the agent fills in — pattern matching beats prose description. Inline for short templates; in `assets/` for long or conditional ones.
- **Checklists.** Multi-step workflows with dependencies benefit from an explicit progress list (`- [ ] Step 1: …`) so the agent tracks state and doesn't skip steps.
- **Validation loops.** "Do X → run validator → fix issues → repeat until validation passes." More reliable than asking the agent to "double-check".
- **Plan-validate-execute.** For batch or destructive operations: extract source-of-truth → produce a plan in a structured file → run a validator script that checks the plan against the source → only then execute. The validation script's error messages should give the agent enough to self-correct.
- **Bundled scripts.** If you notice the agent reinventing the same logic across runs (chart-builder, parser, validator), write the script once in `scripts/` and have `SKILL.md` invoke it.

### Size budget

- Hard recommendation: **`SKILL.md` ≤ 500 lines and ≤ 5000 tokens.** This is the body the agent loads on activation and shares context with everything else.
- Soft target for sleek skills: 50–150 lines if the workflow is simple. Don't pad to fill space.
- **When you legitimately need more,** move detail to `references/<topic>.md` and reference it with a concrete load-trigger ("read `references/X.md` when Y"). Don't dump it inline.

### Rule of three

Don't create a skill for everything. If you've done something three times manually and want it consistent next time, *then* create a skill. Earlier than that, you don't yet know the shape.

### Iteration

Skills improve through real execution, not introspection.

1. **Refine with traces.** Run the skill on real tasks. Read execution traces — not just final outputs. Wasted steps and unproductive branches usually mean an instruction is too vague, doesn't apply, or presents too many options without a default.
2. **Add gotchas as you go.** Every correction you make in a real session is a candidate gotcha. Save it before you forget.
3. **For high-stakes skills, run evals.** Define test cases (`evals/evals.json`), run with-skill vs. without-skill, grade outputs against assertions, compare. See [agentskills.io/skill-creation/evaluating-skills](https://agentskills.io/skill-creation/evaluating-skills).

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
