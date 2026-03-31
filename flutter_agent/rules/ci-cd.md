# CI/CD Rules

## Required Checks

- Every pull request must pass formatting, static analysis, and relevant tests for changed areas before merge.
- Keep `main` always releasable: failed required checks must block merging.
- CI runs on pull requests and pushes to `main`.

## Pipeline Design

- Optimize for fast feedback: run lint/analyze and tests before expensive build jobs.
- Keep jobs deterministic and isolated (no hidden state shared across jobs).
- Cache dependencies and reusable build artifacts when supported by the CI provider.

## Delivery Safety

- Production releases must be explicitly gated (manual approval or protected release workflow).
- Risky changes should use feature flags or staged rollout patterns.
