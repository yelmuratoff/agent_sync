# Core Rules

## Shell Script Quality

- Always use `set -euo pipefail` at the top of every script.
- Quote all variable expansions: `"$var"`, not `$var`. No exceptions.
- Use `local` for all function-scoped variables.
- Prefer `[[ ]]` over `[ ]` for conditionals.
- Use `$(command)` not backticks for command substitution.
- Functions under 50 lines. Extract helpers when logic branches.

## Portability

- No GNU-specific flags. `sed`, `grep`, `readlink` must work on macOS, Linux, and Git Bash.
- No `sed -i ''` or `sed -i` — both are non-portable. Write to temp file and `mv`.
- No `realpath` — use `cd "$(dirname "$path")" && pwd` pattern.
- No `readlink -f` — follow symlinks manually with a `while` loop (see `bin/agentsync.sh`).
- No `mapfile`/`readarray` — use `while IFS= read -r` loops.
- Test changes on macOS and verify CI passes on all three platforms.

## Changes

- Change only what's needed. Don't refactor adjacent code.
- Don't add features beyond what was asked.
- Remove dead code completely — don't comment it out.
- Keep the YAML parser minimal. It handles `key: value` and dot-notation; don't extend it without a clear need.

## Error Handling

- Use `log_error`, `log_warning`, `log_info` from `lib/helpers/logging.sh` — not raw `echo`.
- Always check file existence before reading: `[[ -f "$file" ]] || return`.
- Return meaningful exit codes: 0 success, 1 error, 2 usage error.
- Don't use `set +e` to swallow errors — handle them explicitly.
