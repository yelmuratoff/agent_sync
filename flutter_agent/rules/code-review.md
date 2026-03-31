# Code Review Rules

## PR Scope & Context

- Keep pull requests small and focused on one change objective.
- Include concise context: problem, approach, and verification evidence (tests/screenshots/logs when relevant).
- Split unrelated refactors from feature changes to keep reviews actionable.

## Review Quality

- Prioritize correctness, regressions, security/privacy, and architecture boundaries over style nits.
- Feedback must be specific and actionable; avoid vague comments.
- All blocking feedback must be addressed before merge.

## Automation First

- Let automation enforce formatting, linting, and baseline tests; human review focuses on behavior and design.
- AI-generated code follows the same review and testing bar as handwritten code.
