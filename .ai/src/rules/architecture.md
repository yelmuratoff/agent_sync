# Architecture Rules

## Config-Driven Sync Engine

- All tool behavior is declared in YAML configs (`.ai/src/tools/*.yaml`). The `sync_tool()` function in `lib/sync.sh` reads `targets.*` from YAML and delegates to generic helpers. Don't hardcode tool names, paths, or formats in sync logic.
- Source paths resolve through `resolve_source_override()` → project `agent_sync.yaml` → global `config.yaml`. Never hardcode `.ai/src/` paths directly — use the `SOURCE_*` variables set in `_resolve_source_paths()`.
- Default values (`enabled`, `cleanup`) come from `config.yaml` → `defaults:` section, read into `DEFAULT_ENABLED` / `DEFAULT_CLEANUP`. Don't scatter default values across helpers.
- Tool-specific format differences are expressed through YAML target options (`extension`, `header`, `merge_to_file`, `inline_into_agents`, `prepend_agents`, `append_imports`). Sync logic reads these and routes to the right helper — not via `if [[ "$tool_name" == "cursor" ]]`.

## Module Boundaries

```
bin/agentsync.sh           → CLI entry only. Delegates to lib/helpers/*.sh
lib/sync.sh                → Orchestrator: reads configs, iterates tools, calls helpers
lib/helpers/
  yaml.sh                  → Custom YAML parser (key: value, dot-notation)
  file_ops.sh              → copy_file, sync_dir, cleanup_path, ensure_dir
  rule_operations.sh       → sync_rules, copy_rules, merge_rules_to_file, append_imports
  format_conversion.sh     → MD→TOML conversion, frontmatter parsing
  paths.sh                 → Path resolution, repo-root safety checks
  filters.sh               → include/exclude glob matching
  gitignore.sh             → .gitignore management
  logging.sh               → log_info, log_error, log_warning, log_step
  init.sh                  → agentsync init scaffolding
  list.sh                  → agentsync list
  generate.sh              → agentsync generate (prompt output)
  export.sh / import.sh    → agentsync export/import
  update.sh / release.sh   → agentsync update/release
  resolve.sh               → Engine/install dir resolution
  cli_colors.sh            → Terminal color helpers
lib/templates/             → Defaults for `agentsync init`. Never used at sync time.
lib/prompts/               → Prompt templates for `agentsync generate`.
```

- **Don't put business logic in `bin/agentsync.sh`** — it's a router only.
- **Don't add tool-specific `if/case` blocks in `lib/sync.sh`** — use YAML target declarations and generic helpers.
- **Don't duplicate logic between `sync.sh` and `check.sh`** — extract shared helpers into `lib/helpers/`.

## How Sync Works (Data Flow)

1. `sync.sh` reads project config → resolves source paths → iterates `.ai/src/tools/*.yaml`
2. For each tool: reads `enabled`, reads `targets.*` destinations, reads format options
3. Dispatches to helpers: `copy_file`, `sync_rules`, `sync_dir`, `merge_rules_to_file`, `sync_commands_as_toml`, etc.
4. Each helper is generic — it doesn't know which tool it's serving.

## Path Safety

- `resolve_dest_path()` rejects paths outside `REPO_ROOT_CANONICAL` — prevents path traversal.
- `resolve_source_path()` validates against both `REPO_ROOT_CANONICAL` and `DEFAULT_REPO_ROOT` — no reading arbitrary files.
- All path resolution uses `normalize_absolute_path()` (lexical) + `canonicalize_with_existing_ancestor()` — no `realpath`, no `readlink -f`.

## Zero External Dependencies

- No `yq`, `jq`, `python`, `node`, `perl`. Pure Bash + coreutils.
- The custom YAML parser (`yaml.sh`) handles `key: value` and dot-notation nesting. Don't extend it to handle arrays or multiline blocks without strong justification.
- No `eval` anywhere in the codebase — YAML values are used via pattern matching and parameter expansion only.

## Idempotency

- `agentsync sync` must produce identical output on repeated runs. No timestamps, no ordering changes, no platform-dependent sorting.
- `agentsync check` verifies this — run it after any change to sync logic.

## Anti-Patterns

- Don't hardcode version numbers — read from `VERSION` file.
- Don't store state between syncs. Every run reads config fresh.
- Don't add inline options (`inline_into_agents`, `prepend_agents`) without documenting them in the `agentsync` skill and `_TEMPLATE.yaml`.
- Don't bypass `parse_yaml_value()` to read YAML — inline `grep | sed` parsing will diverge from the parser's quoting/comment handling.
