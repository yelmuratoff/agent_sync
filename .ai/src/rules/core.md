# Core Rules

## Shell Script Quality

- Always use `set -euo pipefail` at the top of every script.
- Quote all variable expansions: `"$var"`, not `$var`. No exceptions.
- Use `local` for all function-scoped variables.
- Prefer `[[ ]]` over `[ ]` for conditionals.
- Use `$(command)` not backticks for command substitution.
- Functions under 50 lines. Extract helpers when logic branches.

## Portability

- Use POSIX-compatible flags for `sed`, `grep`, `readlink` so scripts run on macOS, Linux, and Git Bash.
- For in-place edits, write to a temp file and `mv` — both `sed -i` and `sed -i ''` are non-portable.
- Resolve absolute paths with `cd "$(dirname "$path")" && pwd` instead of `realpath`.
- Follow symlinks with a manual `while` loop (see `bin/agentsync.sh`) instead of `readlink -f`.
- Read line-by-line with `while IFS= read -r` loops instead of `mapfile` / `readarray`.
- Test changes on macOS and verify CI passes on all three platforms.

## Changes

- Change only what the task requires. Leave adjacent code as-is.
- Wait for an explicit ask before adding features beyond scope.
- Delete dead code outright; rely on git for history.
- Keep the YAML parser minimal — it handles `key: value` and dot-notation. Extend only when there is a concrete, justified need.

## Error Handling

- Log via `log_error`, `log_warning`, `log_info` from `lib/helpers/logging.sh` (raw `echo` skips formatting and stderr routing).
- Guard reads: `[[ -f "$file" ]] || return`.
- Return meaningful exit codes: 0 success, 1 error, 2 usage error.
- Handle failures explicitly. Keep `set -euo pipefail` active and let errors surface — `set +e` should stay out of the codebase.
