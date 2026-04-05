---
name: review
description: >
  Perform a structured code review on AgentSync changes.
  USE WHEN reviewing code, reviewing PRs, checking diffs, or asked to find issues in changes.
---

# Code Review

Review changes to the AgentSync codebase for correctness, portability, and maintainability.

## Steps

1. Read the full diff. Understand the scope before commenting.
2. Review in priority order:
   - **Portability** — Will this work on macOS, Linux, AND Git Bash on Windows?
   - **Correctness** — Logic errors, missing edge cases, unquoted variables.
   - **Idempotency** — Does `agentsync sync` still produce identical output on repeated runs?
   - **Error handling** — Are failures handled with proper exit codes and log messages?
   - **YAML parser safety** — No `eval`, no unquoted expansions from user-controlled YAML.
   - **Test coverage** — Are new behaviors covered in bats tests?
3. For each issue:
   - Point to the exact file and line.
   - Explain *why* it's a problem.
   - Suggest a fix when possible.
   - Mark as **blocking** or **suggestion**.
4. If the code is solid, say so.

## AgentSync-Specific Checks

- New tool support must include a `.yaml` config AND bats tests.
- Shell scripts must pass `shellcheck -x -S warning -e SC1091`.
- No external dependencies (yq, jq, python, node).
- Variables must be quoted. `$var` → `"$var"`.
- No GNU-specific flags in `sed`, `grep`, `readlink`.

## Gotchas

- Don't nitpick style — focus on correctness and portability.
- Check the full PR, not just the latest commit.
- `example/` output dirs are regenerated — don't review their diffs.
