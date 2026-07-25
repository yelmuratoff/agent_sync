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
5. **Transactional safety** — backup, restore, manifest, and cleanup behavior for mutating flows
6. **Security** — no `eval`, unsafe paths, leaked secrets, or unquoted user-controlled YAML values
7. **Test coverage** — are new behaviors and failure paths tested in bats?

Run `shellcheck -x -S warning -e SC1091` on any changed `.sh` files.

Report every issue found, including uncertain or low-severity findings. For each
finding, give the exact file and line, severity, confidence, impact, and a
concrete fix. If the code is solid, say so plainly.
