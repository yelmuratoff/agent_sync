# Git Rules

One logical change per commit, imperative mood, generated dirs stay out of history.

## Commits

- Use conventional prefixes: `feat:`, `fix:`, `refactor:`, `test:`, `chore:`, `docs:`.
- Imperative mood: "Add feature", not "Added feature".
- First line ≤72 characters. Body explains *why*; skip the body when the subject says enough.
- Split tool-config changes and sync-engine changes into separate commits.

## Branches

- Descriptive names: `feat/add-zed-support`, `fix/yaml-parser-quoting`, `refactor/split-sync-helpers`.
- Short-lived. Rebase onto `main` before merging.

## Keep Out of History

- Generated output (`.claude/`, `.cursor/`, `.github/copilot-instructions.md`, `example/` outputs) regenerates via `agentsync sync` — leave it ignored.
- Treat `example/` output dirs as ephemeral; regenerate rather than commit.
- Environment-specific files (`.env`, credentials, `.DS_Store`) stay outside the repo.

## Pull Requests

- Keep PRs focused on one logical change — tool config, sync engine, and tests can ride together when they belong to the same change.
- Include "how to test": which `bats` files to run.
- Resolve hook or CI failures at the source rather than bypassing them — a green CI built on `--no-verify` lies.
- Prefer additive commits while a branch is under review; coordinate before force-pushing a shared branch.
