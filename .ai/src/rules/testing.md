# Testing Rules

## Framework

- Tests use [bats-core](https://github.com/bats-core/bats-core) — `.bats` files in `tests/`.
- Shared helpers live in `tests/test_helper.bash`. Use `setup_test_project` / `teardown_test_project` for temp dirs.
- Run `AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN"` via the `run_agentsync` helper — never test against the installed version.

## Test Structure

- Unit tests: `cli.bats`, `files.bats`, `gitignore.bats`, `list.bats`, `generate.bats`, `init.bats`, `hooks.bats`, `release.bats`.
- Integration tests: `sync.bats`, `sync_options.bats`, `check.bats`.
- Integration tests use `setup_file`/`teardown_file` — run `init` + `sync` once, then readonly assertions.
- Unit tests use `setup`/`teardown` per test with fresh temp directories.

## Conventions

- Test names describe behavior: `@test "sync: Claude CLAUDE.md exists"`, not `@test "test_claude"`.
- Use `[ -f ... ]` and `grep -q` for assertions — bats fails on non-zero exit codes.
- Always clean up temp dirs in `teardown` or `teardown_file`.
- Don't test against real GitHub or network resources.

## When Adding a New Tool

- Add sync assertions to `tests/sync.bats` verifying output files exist.
- Add filter tests to `tests/sync_options.bats` for `--only` / `--skip`.
- Add check assertions to `tests/check.bats`.

## CI

- CI runs on Linux, macOS, and Windows (Git Bash). If a test fails on one platform, it's likely a portability issue.
- ShellCheck runs separately: `shellcheck -x -S warning -e SC1091`.
