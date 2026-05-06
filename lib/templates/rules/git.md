# Git Rules

## Commits

- Match the project's existing commit style (check `git log --oneline -10`). If none is established, default to Conventional Commits: `<type>: <subject>` with `feat`, `fix`, `refactor`, `docs`, `test`, `chore`.
- One logical change per commit. Split unrelated work into separate commits.
- Subject in imperative mood, ≤72 chars. Body explains *why*, not *what* — skip the body when the subject says enough.

## Branches

- Use descriptive names: `feat/<slug>`, `fix/<slug>`, `refactor/<slug>`.
- Rebase onto the default branch before opening a PR.

## Pull Requests

- Link the related ticket or issue in the description.
- Coordinate before force-pushing a shared branch; prefer additive commits while others may be reviewing.
- Resolve hook or CI failures at the source rather than passing `--no-verify` — a green CI built on bypassed checks lies.

## Keep Out of History

- Generated artifacts, lockfile binaries, secrets, `.env*` files belong outside the repo.
- Reach for `.gitignore` to fence off environment-specific or generated output.
