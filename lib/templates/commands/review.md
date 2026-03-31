---
description: Review the current branch diff for issues before merging
---

## Changes

!`git diff --name-only main...HEAD`

## Diff

!`git diff main...HEAD`

Review the above changes for:

1. Correctness — logic errors, missing edge cases
2. Security — hardcoded secrets, injection risks, missing validation
3. Error handling — swallowed exceptions, missing error paths
4. Test coverage — are new behaviors tested?

Give specific, actionable feedback per file. If the code is solid, say so.
