---
name: code-review
description: When preparing a PR for review or performing a structured review focused on correctness, risk, and maintainability.
---

# Code Review (Author + Reviewer Workflow)

## When to use

- Opening a pull request.
- Reviewing a teammate's or AI-generated changes.
- Validating merge readiness for medium/large changes.

## Steps

### 1) Prepare review-friendly PRs (author)

- Keep changes focused on a single objective.
- Separate unrelated refactors from behavioral changes.
- Include concise context: what changed, why, and how it was verified.

### 2) Run automation first

- Ensure local format/analyze/test checks pass before requesting review.
- Treat failing automation as a blocker, not reviewer work.

### 3) Review by risk, not by file order (reviewer)

- Start with architecture boundaries and dependency direction.
- Check correctness, error handling, and state transitions.
- Verify security/privacy risks (secrets, PII logging, untrusted input paths).

### 4) Validate tests and observability

- Confirm changed behavior is covered by meaningful tests.
- Ensure error paths are tested for critical flows.
- Check logging/analytics changes are safe and intentional.

### 5) Give actionable feedback

- Describe the concrete issue, impact, and expected fix direction.
- Distinguish blocking issues from optional improvements.
- Prefer precise suggestions over broad or stylistic comments.

### 6) Close review cleanly

- Resolve all blocking comments before merge.
- Re-run relevant checks after follow-up commits.
- Merge only when intent, behavior, and verification are all clear.
