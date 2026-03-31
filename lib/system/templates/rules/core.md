# Core Rules

## Code Quality

- Follow the project's established conventions and patterns.
- Prefer readability over cleverness. Code is read far more than written.
- Keep functions focused — one function, one responsibility.
- Use meaningful names that describe intent, not implementation.
- Handle errors explicitly. Don't swallow exceptions.

## Changes

- Change only what's needed to complete the task. Don't refactor unrelated code.
- Don't add features, abstractions, or "improvements" beyond what was asked.
- Don't add comments that restate what the code already says.
- Remove dead code instead of commenting it out.

## Testing

- Write tests for business logic and error paths.
- Tests should be deterministic — no real network, no randomness, no timing dependencies.
- Name tests to describe the behavior being verified, not the method being called.

## Security

- Never hardcode secrets, API keys, or credentials.
- Validate and sanitize untrusted input (user input, external API responses).
- Never log sensitive data (tokens, passwords, PII).
