# Core Rules

Every script runs on macOS, Linux, and Git Bash on Windows with the same code path. Strict mode stays on, errors surface, and changes stay inside the scope the task asked for.

## Shell Script Quality

- Open every script with `set -euo pipefail` so failures surface at the source.
- Quote every variable expansion: `"$var"` keeps whitespace and globs intact.
- Declare function-scoped variables with `local`.
- Reach for `[[ ]]` over `[ ]`, and `$(command)` over backticks.
- Functions stay under 50 lines. Extract a helper when logic branches.

## Portability

POSIX-compatible flags only — `sed`, `grep`, `readlink`, `find` ship in different flavours across platforms. Examples:

```bash
# In-place edits — write to a temp file and move it
- sed -i 's/foo/bar/' "$file"        # GNU-only
- sed -i '' 's/foo/bar/' "$file"     # BSD-only
+ sed 's/foo/bar/' "$file" > "$tmp" && mv "$tmp" "$file"

# Absolute paths — use cd+pwd
- realpath "$path"                   # not on macOS by default
+ (cd "$(dirname "$path")" && pwd)

# Resolve symlinks — manual loop, see bin/agentsync.sh
- readlink -f "$link"                # GNU-only
+ while [[ -L "$target" ]]; do target=$(readlink "$target"); done

# Line-by-line reads — POSIX everywhere
- mapfile -t lines < "$file"         # bash 4+
+ while IFS= read -r line; do ...; done < "$file"
```

Run changed scripts on macOS locally; CI confirms Linux and Git Bash.

## Scope of Changes

- Touch only what the task requires. Adjacent code stays as-is until asked.
- Three similar lines beat a premature abstraction — let real duplication drive helpers.
- Delete dead code outright; git keeps the history.
- The YAML parser handles `key: value` and dot-notation. Extend it only with a concrete, justified need.

## Error Handling

- Log via `log_error`, `log_warning`, `log_info` from `lib/helpers/logging.sh` — raw `echo` skips formatting and stderr routing.
- Guard reads: `[[ -f "$file" ]] || return`.
- Return exit codes that mean something: `0` success, `1` runtime error, `2` usage error.
- Let `set -euo pipefail` stay active throughout the run — fix the failing command rather than disabling strict mode for it.
