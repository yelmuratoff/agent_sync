---
name: refactor
description: >
  Restructure AgentSync Bash scripts without changing behavior.
  USE WHEN refactoring, cleaning up code, reducing duplication, improving naming, or simplifying shell logic.
---

# Refactor

Safely restructure AgentSync's Bash code while preserving existing behavior.

## Steps

1. **Verify tests exist** — Run `bats tests/` to confirm current behavior passes before touching anything.
2. **Name the problem** — What exactly is wrong? Duplicated logic? Oversized function? Poor naming? Tangled helpers?
3. **Plan the change** — Small, safe steps. Each step keeps `agentsync sync` producing identical output.
4. **One change at a time** — Extract a helper, rename a function, simplify a conditional — one per commit.
5. **Run tests after each step** — `bats tests/` must pass. If it fails, you changed behavior.
6. **Run ShellCheck** — `shellcheck -x -S warning -e SC1091` on all changed files.
7. **Verify idempotency** — Run `agentsync sync` in `example/`, then run `agentsync check` to confirm no drift.

## Common Refactors

- **Extract helper** — Move repeated logic from `lib/sync.sh` into `lib/helpers/<name>.sh`. Source it in `sync.sh`.
- **Simplify sync logic** — The `sync_tool` function in `lib/sync.sh` is large. Extract tool-specific handlers when they grow.
- **Consolidate YAML access** — Use `parse_yaml_value` consistently; don't reimplement parsing inline.

## Gotchas

- Don't extract abstractions used only once — duplication is fine at small scale.
- Don't rename exported functions without checking all callers (sync.sh, check.sh, agentsync.sh).
- Don't refactor and add features in the same commit.
- Keep Bash portable — refactored code must work on macOS, Linux, and Git Bash on Windows.
- The `example/` output is the integration test — always re-sync and check after refactoring.
