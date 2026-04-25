---
name: commit
description: Create a well-structured git commit for staged or unstaged changes — analyze the diff, match the project's existing commit style, write a clear message, and create the commit. Use this skill when the user asks to commit, save changes, check in code, write a commit message, prepare changes for push, or wrap up a piece of work — even when they don't say "commit" explicitly (e.g. "let's save this", "ship it", "сохрани изменения").
---

# Commit

Write a commit message that follows the project's conventions and clearly explains what changed and why.

## Steps

1. Run `git diff --cached` (or `git diff` if nothing is staged) to see all changes.
2. Run `git log --oneline -5` to match the project's existing commit style.
3. Analyze the changes:
   - What was added, changed, or removed?
   - Is this a feature, bug fix, refactor, docs update, or chore?
   - What is the *motivation* behind the change?
4. Write the commit message:
   - **First line**: imperative mood, under 72 chars (e.g., `fix: prevent duplicate API calls on rapid tap`).
   - **Body** (if needed): blank line, then explain *why*, not *what*.
   - Match the project's commit style (conventional commits, prefixes, etc.).
5. Stage only relevant files. Don't `git add .` blindly — exclude generated files, secrets, unrelated changes.
6. Create the commit.

## Commit Prefixes (conventional commits)

- `feat:` — new functionality
- `fix:` — bug fix
- `refactor:` — restructuring without behavior change
- `docs:` — documentation only
- `test:` — adding or fixing tests
- `chore:` — maintenance (dependencies, CI, config)

## Gotchas

- Don't amend the previous commit unless explicitly asked — create a new commit instead.
- Don't include unrelated changes in the same commit. One logical change per commit.
- Don't commit `.env`, credentials, or generated lock files unless the project expects it.
- If a pre-commit hook fails, fix the issue and create a NEW commit — don't use `--no-verify`.
