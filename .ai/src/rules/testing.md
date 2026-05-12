# Testing Rules

Tests exercise the in-tree binary against local fixtures only. Behaviour names, deterministic setup, clean teardown.

## Framework

- bats-core. `.bats` files live in `tests/`.
- Shared helpers in `tests/test_helper.bash`. Use `setup_test_project` / `teardown_test_project` for temp dirs.
- Run the in-tree binary via the `run_agentsync` helper (`AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN"`) so tests exercise the working copy rather than a globally installed version.

## Test Structure

- **Unit tests** — `cli.bats`, `files.bats`, `gitignore.bats`, `list.bats`, `generate.bats`, `init.bats`, `hooks.bats`, `release.bats`. Fresh temp dirs per test via `setup` / `teardown`.
- **Integration tests** — `sync.bats`, `sync_options.bats`, `check.bats`. Run `init` + `sync` once via `setup_file` / `teardown_file`, then readonly assertions.

## Conventions

- Name tests by behaviour verified: `@test "sync: Claude CLAUDE.md exists"`, not `@test "test_claude"`.
- Use `[ -f ... ]` and `grep -q` for assertions — bats fails on non-zero exit codes.
- Clean up temp dirs in `teardown` or `teardown_file`.
- Keep tests hermetic: local fixtures only, no network, no real GitHub calls.

## When Adding a New Tool

- Add sync assertions to `tests/sync.bats` verifying output files exist.
- Add filter tests to `tests/sync_options.bats` for `--only` / `--skip`.
- Add check assertions to `tests/check.bats`.

## CI

- Runs on Linux, macOS, and Windows (Git Bash). A failure on one platform points to a portability issue first.
- ShellCheck runs separately: `shellcheck -x -S warning -e SC1091`.
