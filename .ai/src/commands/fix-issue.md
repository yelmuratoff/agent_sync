---
description: Investigate and fix a GitHub issue
argument-hint: "<issue-number>"
---

Look at issue #$ARGUMENTS in this repo.

!`gh issue view $ARGUMENTS`

1. Understand the bug from the issue description and comments.
2. Trace it to the root cause — check `lib/sync.sh`, `lib/helpers/*.sh`, `bin/agentsync.sh`, and tool YAML configs.
3. Fix with the smallest correct change. Ensure portability (macOS + Linux + Git Bash).
4. Run `shellcheck -x -S warning -e SC1091` on changed scripts.
5. Write or update a bats test in `tests/` that would have caught this bug.
6. Run `bats tests/` to verify all tests pass.
