---
description: Review the current branch diff for issues before merging
---

## Changed Files

!`git diff --name-only main...HEAD`

## Diff

!`git diff main...HEAD`

Review the above changes to AgentSync for:

1. **Portability** — macOS, Linux, and Git Bash on Windows. No GNU-specific flags.
2. **Correctness** — logic errors, unquoted variables, missing edge cases
3. **Idempotency** — will `agentsync sync` still produce identical output on repeated runs?
4. **Error handling** — proper exit codes, `log_error`/`log_warning` usage
5. **Security** — no `eval`, no unquoted user-controlled YAML values
6. **Test coverage** — are new behaviors tested in bats?

Run `shellcheck -x -S warning -e SC1091` on any changed `.sh` files.

Give specific, actionable feedback per file. If the code is solid, say so.
