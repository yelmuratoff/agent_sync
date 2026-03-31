# Testing Rules

## What Must Be Tested

- Business logic: repositories/services and any pure transformation logic.
- State orchestration: BLoCs for success + expected failure paths.
- Error mapping: low-level failures must map to explicit exception types deterministically.

## Test Quality

- Use Given/When/Then structure and clear naming. Test complex business logic before implementation (TDD approach).
- **Test Behavior, Not Properties**: Verify actions, state changes, and logic flows rather than checking static UI properties or numbers (e.g. testing that `onTap` fires, rather than testing padding values).
- Tests must be deterministic (no real HTTP, no real clocks, no randomness).
- Prefer fakes/stubs over mocks; use mocks only when interaction verification is required.
- Mock I/O boundaries (HTTP, database, preferences, secure storage).
- Organize `test/` to mirror source structure for discoverability.
- Group tests by behavior domain (for example: renders/navigation for widgets, event names for BLoCs, method names for repositories).
- Keep one behavior/scenario per test for easier debugging.
- Every test must end with explicit assertions (`expect`/`verify`) tied to behavior.
- Keep `setUp`/`tearDown` scoped to `group(...)` blocks, not at file top level.
- Initialize mutable collaborators per test; never share mutable/static state across tests.
- Do not add dedicated tests for pure barrel export files.

## Coverage Expectations

- Target 100% coverage on all business logic (repositories, BLoCs, services, domain utilities).
- Minimum floor: 80% line coverage on all business-logic files; PRs below this floor require explicit justification.
- Critical flows (authentication, payment, token refresh): 100% coverage is mandatory—no exceptions.
- Prioritize meaningful scenario coverage over mechanical line coverage. A test that exercises no real assertion is worthless regardless of the percentage it adds.
- Always cover the error path for every async operation (network failure, parse failure, cache miss, timeout).

## Assertions & Integration

- Use `package:checks` for assertions (clear failure messages, fluent API) where possible.
- Use `integration_test` for critical user flows that span multiple screens/features.
- Tag golden tests consistently (for example `golden`) so they can run separately in CI.
- Run randomized ordering periodically in CI to expose hidden test coupling (`--test-randomize-ordering-seed random`).
