# Architecture Rules

## Config-Driven Sync Engine

- Declare all tool behavior in YAML configs (`.ai/src/tools/*.yaml`). `sync_tool()` in `lib/sync.sh` reads `targets.*` from YAML and delegates to generic helpers — keep tool names, paths, and formats out of sync logic itself.
- Resolve source paths through `resolve_source_override()` → project `agent_sync.yaml` → global `config.yaml`. Reference the `SOURCE_*` variables set by `_resolve_source_paths()` rather than literal `.ai/src/` paths.
- Read defaults (`enabled`, `cleanup`) from `config.yaml` → `defaults:` into `DEFAULT_ENABLED` / `DEFAULT_CLEANUP`, then propagate from there. Keep defaults centralized.
- Express tool-specific format differences through YAML target options (`extension`, `header`, `merge_to_file`, `inline_into_agents`, `prepend_agents`, `append_imports`). Sync logic reads these options and routes to the right helper — extend by adding an option, not an `if [[ "$tool_name" == "cursor" ]]` branch.

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

- **Keep `bin/agentsync.sh` as a router** — it parses CLI args and delegates; business logic belongs in `lib/helpers/`.
- **Drive `lib/sync.sh` from YAML target declarations** — extend behavior by adding YAML options and generic helpers, not by branching on tool name.
- **Share logic between `sync.sh` and `check.sh` through helpers in `lib/helpers/`** — both commands stay aligned by calling the same code.

## How Sync Works (Data Flow)

1. `sync.sh` reads project config → resolves source paths → iterates `.ai/src/tools/*.yaml`
2. For each tool: reads `enabled`, reads `targets.*` destinations, reads format options
3. Dispatches to helpers: `copy_file`, `sync_rules`, `sync_dir`, `merge_rules_to_file`, `sync_commands_as_toml`, etc.
4. Each helper is generic — it doesn't know which tool it's serving.

## Path Safety

- `resolve_dest_path()` rejects paths outside `REPO_ROOT_CANONICAL` — prevents path traversal.
- `resolve_source_path()` validates against both `REPO_ROOT_CANONICAL` and `DEFAULT_REPO_ROOT`, keeping reads inside trusted roots.
- Resolve paths through `normalize_absolute_path()` (lexical) + `canonicalize_with_existing_ancestor()`. These exist so the codebase stays free of `realpath` and `readlink -f`.

## Zero External Dependencies

- Use pure Bash + coreutils. The codebase stays free of `yq`, `jq`, `python`, `node`, and `perl` by design.
- Keep the custom YAML parser (`yaml.sh`) scoped to `key: value` and dot-notation nesting. Arrays and multiline blocks need a strong justification before extending the parser.
- Read YAML values via pattern matching and parameter expansion. The codebase has zero uses of `eval` and stays that way for security.

## Idempotency

- `agentsync sync` must produce identical output on repeated runs. No timestamps, no ordering changes, no platform-dependent sorting.
- `agentsync check` verifies this — run it after any change to sync logic.

## Discipline

- Read version numbers from the `VERSION` file rather than embedding them in scripts.
- Keep every sync run stateless — read config fresh each time.
- Document new inline options (`inline_into_agents`, `prepend_agents`, etc.) in the `agentsync` skill and `_TEMPLATE.yaml` as part of the same change that introduces them.
- Read YAML through `parse_yaml_value()` so quoting and comment handling stay consistent across the codebase.
