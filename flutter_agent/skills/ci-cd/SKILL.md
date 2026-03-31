---
name: ci-cd
description: When defining or improving CI/CD workflows for Flutter/Dart repositories (quality gates, caching, release safety).
---

# CI/CD (Fast Feedback, Safe Delivery)

## When to use

- Creating or updating CI workflows.
- Reducing pipeline duration or flaky failures.
- Defining release gating for production deployments.

## Steps

### 1) Define triggers and required checks

- Trigger CI on pull requests and pushes to `main`.
- Mark format/analyze/test workflows as required checks before merge.
- Keep required checks minimal but sufficient for regression prevention.

### 2) Keep jobs deterministic and isolated

- Pin SDK/tool versions in CI.
- Avoid shared mutable state between jobs.
- Fail fast on unstable or network-fragile tests; move those to dedicated integration flows.

### 3) Order jobs for fast feedback

- Run formatting and static analysis first.
- Run unit/widget tests next.
- Run heavier build/signing jobs only after quality checks pass.

### 4) Optimize execution time

- Cache pub dependencies and reusable artifacts where CI supports it.
- Parallelize independent jobs (for example test shards or package groups).
- Prefer incremental, targeted test/build scopes when the repository supports it.

### 5) Gate production delivery

- Keep production deployment behind explicit approval or protected release jobs.
- Use feature flags or staged rollout for high-risk functionality.

### 6) Continuously tune pipeline quality

- Track pipeline duration and flaky test rate.
- Fix flaky tests before adding new jobs.
- Revisit required checks when architecture or tooling changes.
