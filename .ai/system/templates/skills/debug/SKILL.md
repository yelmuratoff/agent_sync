---
name: debug
description: When investigating a bug, error, or unexpected behavior.
---

# Debug

## When to use

When the user reports a bug, error message, unexpected behavior, or failing test.

## Steps

1. **Reproduce** — Understand exactly what happens vs. what should happen. Get the error message, stack trace, or steps to reproduce.
2. **Locate** — Narrow down where the problem is:
   - Read the error message and stack trace carefully — they usually point to the exact location.
   - Search the codebase for relevant keywords (error messages, function names, variable names).
   - Trace the data flow from input to the point of failure.
3. **Understand** — Before fixing, understand *why* it fails:
   - What assumption is being violated?
   - When was it introduced? (`git log`, `git blame` can help.)
   - Is this a logic error, a data problem, a race condition, or a missing edge case?
4. **Fix** — Make the smallest change that correctly addresses the root cause.
   - Don't patch symptoms. Fix the actual problem.
   - If the fix is in a different layer than expected, that's fine — follow the root cause.
5. **Verify** — Confirm the fix resolves the issue:
   - Write or update a test that would have caught this bug.
   - Run the existing test suite to check for regressions.
6. **Explain** — Briefly describe what caused the bug and why the fix is correct.

## Anti-Patterns

- Don't add try-catch around the error to silence it.
- Don't fix the symptom without understanding the cause.
- Don't make speculative changes ("maybe this will fix it").
- Don't change multiple things at once — isolate the fix.
