---
name: "content"
description: >-
  One imperative sentence on what this skill does + concrete trigger conditions. Be pushy — list contexts including ones where the user doesn't name the domain ("even when phrased as 'X' or 'Y'"). Pack relevant keywords. Stay under 1024 characters.
---

# {{NAME}}

[One line: what this skill does and when the agent should invoke it.]

## Bundled references (load on demand)

[Optional. Only include if you've created `references/` files. Each line states a CONCRETE trigger condition, not a vague "see references/".]

- `references/X.md` — read when [concrete trigger condition]

## Steps

1. [Concrete first step — real commands, real paths.]
2. [Next step.]
3. [Final step — what "done" looks like.]

## Gotchas

[The single highest-leverage section. Concrete corrections to wrong assumptions, not generic advice.]

- [Mistake the agent has made using this skill.]
- [Edge case or non-obvious project-specific fact.]

<!--
AgentSync skills follow agentskills.io. Hard limits enforced by spec:
  - `name`: ≤64 chars, lowercase a-z/digits/hyphens only, must match folder name.
  - `description`: ≤1024 chars.
  - SKILL.md body: ≤500 lines / ≤5000 tokens. Move detail to references/.
Optional subdirectories:
  - references/  docs the agent loads on demand
  - scripts/     executable code (Python/Bash/JS) the agent runs
  - assets/      templates, schemas, images
Validate with `skills-ref validate <path>`.
Delete this comment after editing.
-->
