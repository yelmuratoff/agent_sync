---
name: debug
description: >
  Investigate and fix bugs in AgentSync's Bash scripts or sync logic.
  USE WHEN debugging sync failures, YAML parsing issues, cross-platform errors, or bats test failures.
---

# Debug AgentSync

Systematically find and fix bugs in the sync engine or helpers.

## Steps

1. **Reproduce** — Get the exact error. Run the failing command with `bash -x` for trace output:
   - `bash -x bin/agentsync.sh sync` for sync issues.
   - `bats tests/<file>.bats` for test failures.
   - Check CI logs if the failure is platform-specific.
2. **Locate** — Narrow down the failing script:
   - `bin/agentsync.sh` → CLI entry point, delegates to helpers.
   - `lib/sync.sh` → Main sync engine.
   - `lib/helpers/*.sh` → Specific functionality (YAML parsing, file ops, gitignore, etc.).
   - `lib/helpers/yaml.sh` → Custom YAML parser (common source of parsing bugs).
3. **Understand** — Check:
   - Is it a portability issue? (macOS vs Linux vs Git Bash)
   - Is the YAML parser mishandling a value? (Quoting, comments, nesting)
   - Is a file path wrong? (Relative vs absolute, symlink resolution)
   - Is `set -euo pipefail` causing an unexpected exit? (Unset variable, failed command)
4. **Fix** — Make the smallest portable change. Test on the affected platform.
5. **Verify** — Run the specific bats test file, then the full suite: `bats tests/`.

## Common Issues

- **`unbound variable`** — Missing `${VAR:-}` default for optional variables under `set -u`.
- **`sed` differences** — macOS BSD sed vs GNU sed. Avoid `sed -i`, write to temp + `mv`.
- **Path issues** — Use `cd && pwd` pattern, not `realpath` or `readlink -f`.
- **YAML parsing** — The custom parser only handles `key: value`. No arrays, no multiline blocks.

## Gotchas

- Don't add `set +e` to silence errors — find the actual failing command.
- Platform-specific bugs often manifest only in CI — check all three OS results.
- The `example/` directory is a full integration test — run `agentsync sync` there to validate end-to-end.
- YAML values with `#` are treated as comments unless quoted. Check `_yaml_normalize_scalar` for edge cases.
