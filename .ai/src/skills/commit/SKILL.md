---
name: commit
description: >
  Create a well-structured git commit message for staged changes.
  USE WHEN committing code, writing commit messages, or preparing changes for push.
---

# Commit

Write a commit message that follows the project's conventions.

## Steps

1. Run `git diff --cached` (or `git diff` if nothing is staged) to see all changes.
2. Run `git log --oneline -5` to match the project's existing commit style.
3. Analyze the changes:
   - What was added, changed, or removed?
   - Is this a feature, bug fix, refactor, docs update, or chore?
   - What is the *motivation* behind the change?
4. Write the commit message:
   - **First line**: `<prefix>: <summary>` under 72 chars.
   - Prefixes: `feat:`, `fix:`, `refactor:`, `test:`, `chore:`, `docs:`.
   - **Body** (if needed): blank line, then explain *why*, not *what*.
5. Stage only relevant files. Don't `git add .` — exclude generated output, secrets, unrelated changes.
6. Create the commit.

## Gotchas

- Don't amend the previous commit unless explicitly asked — create a new commit.
- Don't include unrelated changes in the same commit.
- Don't commit output directories (`.claude/`, `.cursor/`, `example/` generated dirs) — they're gitignored.
- Don't commit `.env`, `.DS_Store`, or `VERSION` changes unless part of a release.
- If a pre-commit hook fails, fix the issue and create a NEW commit — don't use `--no-verify`.
