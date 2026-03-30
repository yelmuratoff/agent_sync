---
name: review
description: When reviewing code changes, pull requests, or diffs.
---

# Code Review

## When to use

When the user asks to review a PR, diff, or code changes.

## Steps

1. Read the full diff. Understand the scope of changes before commenting.
2. Check the PR description or commit messages for context — what problem is being solved?
3. Review in this priority order:
   - **Correctness** — Does the code do what it claims? Are there logic errors, off-by-one bugs, or missing edge cases?
   - **Security** — Are there injection risks, hardcoded secrets, missing input validation, or exposed PII?
   - **Error handling** — Are failures handled? Can exceptions propagate unexpectedly?
   - **Architecture** — Does this follow established patterns? Are layer boundaries respected?
   - **Testing** — Are new behaviors tested? Are error paths covered?
   - **Naming & readability** — Is the code clear? Would a new team member understand it?
4. For each issue found:
   - Be specific: point to the exact line and explain what's wrong.
   - Explain *why* it's a problem, not just *what* to change.
   - Suggest a fix when possible.
   - Classify severity: blocking (must fix) vs. suggestion (nice to have).
5. If the code is solid, say so. Don't invent criticism for the sake of reviewing.

## Review Output Format

```
## Summary
[1-2 sentence overview of the changes]

## Issues
- **[blocking]** file.ts:42 — [description of the problem and suggested fix]
- **[suggestion]** file.ts:15 — [description and reasoning]

## Verdict
[Approve / Request changes / Needs discussion]
```
