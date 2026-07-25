# Core Rules

Every command runs on macOS, Linux, and Git Bash on Windows. Entry points own strict mode, sourced helpers remain safe under it, failures surface, and changes stay inside the requested scope.

## Shell Script Quality

- Keep `set -euo pipefail` enabled in executable entry points. Helper modules are sourced and inherit the caller's shell options.
- Quote expansions unless intentional splitting or glob expansion is part of the contract.
- Declare function-scoped variables with `local`.
- Reach for `[[ ]]` over `[ ]`, and `$(command)` over backticks.
- Stay compatible with Bash 3.2: no associative arrays, namerefs, or `mapfile`.

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

Run ShellCheck and the relevant bats tests locally; CI confirms Linux, macOS, and Git Bash.

## Scope of Changes

- Touch only what the task requires. Adjacent code stays as-is until asked.
- Three similar lines beat a premature abstraction — let real duplication drive helpers.
- Delete dead code outright; git keeps the history.
- Keep configuration within the scalar, nested-key, and supported list shapes implemented in `lib/helpers/yaml.sh`.

## Error Handling

- Match the surrounding command's output layer: structured sync paths use `log_*`; interactive CLI helpers use the shared colour and prompt helpers.
- Guard expected optional inputs explicitly. Let unexpected filesystem, parser, and subprocess failures propagate.
- Preserve meaningful non-zero exit codes and actionable stderr messages at CLI boundaries.
- Let `set -euo pipefail` stay active throughout the run — fix the failing command rather than disabling strict mode for it.
