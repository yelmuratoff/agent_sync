# Testing Rules

Tests exercise the in-tree binary against local fixtures only. Behaviour names, deterministic setup, clean teardown.

## Framework

- bats-core. `.bats` files live in `tests/`.
- Shared helpers in `tests/test_helper.bash`. Use `setup_test_project` / `teardown_test_project` for temp dirs.
- Run the in-tree binary via the `run_agentsync` helper (`AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN"`) so tests exercise the working copy rather than a globally installed version.

## Test Structure

- Use `setup_test_project` for isolated unit-style command tests.
- For expensive initialized projects, use `seed_project` in `setup_file` and `clone_seed` in `setup`; each test still owns an isolated clone.
- Keep integration coverage close to the owning command (`sync.bats`, `refresh.bats`, `profiles.bats`, and similar focused files).

## Conventions

- Name tests by behaviour verified: `@test "sync: Claude CLAUDE.md exists"`, not `@test "test_claude"`.
- Use `[ -f ... ]` and `grep -q` for assertions — bats fails on non-zero exit codes.
- Clean up temp dirs in `teardown` or `teardown_file`.
- Keep tests hermetic: local fixtures only, no network, no real GitHub calls.
- Protect the developer environment from side effects such as clipboard writes, global config changes, or edits outside `TEST_PROJECT`.

## When Adding a New Tool

- Add sync assertions to `tests/sync.bats` verifying output files exist.
- Add filter tests to `tests/sync_options.bats` for `--only` / `--skip`.
- Add check assertions to `tests/check.bats`.

## CI

- Runs on Linux, macOS, and Windows (Git Bash). A failure on one platform points to a portability issue first.
- ShellCheck runs separately: `shellcheck -x -S warning -e SC1091`.
- The full suite supports parallel execution: `bats --jobs 4 tests/ --tap`.
