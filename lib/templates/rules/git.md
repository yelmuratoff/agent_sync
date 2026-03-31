# Git Rules

## Commits

- Write commit messages in imperative mood: "Add feature", not "Added feature".
- First line: concise summary under 72 characters.
- If more context is needed, add a blank line then a body explaining *why*, not *what*.
- One logical change per commit. Don't mix unrelated changes.

## Branches

- Use descriptive branch names: `feat/user-auth`, `fix/login-crash`, `refactor/api-client`.
- Keep branches short-lived. Merge or rebase frequently against the main branch.

## Pull Requests

- Keep PRs focused on one objective. Split unrelated work into separate PRs.
- Include context: what changed, why, and how to verify.
- Don't force-push to shared branches without coordination.

## History

- Don't commit generated files, build artifacts, or secrets.
- Use `.gitignore` to exclude environment-specific and generated files.
