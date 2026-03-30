---
name: commit
description: When writing a git commit message for staged changes.
---

# Commit

## When to use

When the user asks to commit changes, or when you need to create a commit after completing work.

## Steps

1. Run `git diff --cached` (or `git diff` if nothing is staged) to see all changes.
2. Run `git log --oneline -5` to understand the recent commit style in this project.
3. Analyze the changes:
   - What was added, changed, or removed?
   - Is this a feature, bug fix, refactor, docs update, or chore?
   - What is the *motivation* behind the change?
4. Write the commit message:
   - **First line**: imperative mood, under 72 chars, describes the *what* (e.g., `fix: prevent duplicate API calls on rapid tap`).
   - **Body** (if needed): blank line, then explain *why* this change was made and any non-obvious decisions.
   - Match the project's existing commit style (conventional commits, prefixes, etc.).
5. Stage only relevant files — don't use `git add .` blindly. Exclude generated files, secrets, and unrelated changes.
6. Create the commit.

## Commit Prefixes (if the project uses conventional commits)

- `feat:` — new functionality
- `fix:` — bug fix
- `refactor:` — restructuring without behavior change
- `docs:` — documentation only
- `test:` — adding or fixing tests
- `chore:` — maintenance (dependencies, CI, config)
