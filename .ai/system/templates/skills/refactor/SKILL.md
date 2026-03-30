---
name: refactor
description: When restructuring existing code without changing its behavior.
---

# Refactor

## When to use

When the user asks to refactor, clean up, or restructure code. Also when you identify code that's hard to change, duplicated, or poorly named — but only if the user asked for it.

## Steps

1. **Verify tests exist** — Before touching anything, confirm there are tests covering the code you're about to change. If tests are missing, write them first against the current behavior.
2. **Identify the problem** — Name exactly what's wrong:
   - Duplicated logic?
   - Function doing too many things?
   - Poor naming?
   - Tangled dependencies?
   - Wrong abstraction level?
3. **Plan the change** — Describe what you'll do before doing it. Refactoring should be a series of small, safe steps.
4. **Make one change at a time** — Each step should keep the code in a working state. Don't rewrite everything at once.
5. **Run tests after each step** — If tests fail, you changed behavior. Undo and try a smaller step.
6. **Stop when it's good enough** — Don't chase perfection. If the code is clear, tested, and easy to change, it's done.

## Red Flags (do NOT refactor these ways)

- Don't extract an abstraction used only once.
- Don't add design patterns just to demonstrate knowledge.
- Don't rename things across the entire codebase without the user asking.
- Don't change public APIs without understanding the downstream impact.
- Don't refactor and add features in the same change.
