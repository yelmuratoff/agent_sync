# Architecture Rules

The sync engine is config-driven: tool behaviour lives in `.ai/src/tools/*.yaml`, and generic helpers in `lib/helpers/` do the work. Extend by adding a YAML option, then handling it in a helper — not by branching on a tool name.

## Config-Driven Sync Engine

- Declare tool behaviour in YAML configs. `sync_tool()` in `lib/sync.sh` reads `targets.*` and routes to helpers. Keep tool names, paths, and formats inside YAML.
- Express format differences through YAML target options (`extension`, `header`, `merge_to_file`, `inline_into_agents`, `prepend_agents`, `append_imports`). Add a new option and a helper rather than an `if [[ "$tool_name" == "cursor" ]]` branch.
- Resolve source paths through `resolve_source_override()` → project `agent_sync.yaml` → global `config.yaml`. Reference the `SOURCE_*` variables set by `_resolve_source_paths()`.
- Read defaults (`enabled`, `cleanup`) from `config.yaml` into `DEFAULT_ENABLED` / `DEFAULT_CLEANUP`, then propagate from there.

## Module Map

```
bin/agentsync.sh         → CLI router. Parses args, delegates to lib/helpers/.
lib/sync.sh              → Orchestrator. Reads configs, iterates tools, calls helpers.
lib/helpers/yaml.sh      → Custom YAML parser (key: value + dot-notation).
lib/helpers/file_ops.sh  → copy_file, sync_dir, cleanup_path, ensure_dir.
lib/helpers/rule_*.sh    → sync_rules, merge_rules_to_file, append_imports.
lib/helpers/format_*.sh  → MD→TOML, frontmatter parsing.
lib/helpers/paths.sh     → Path resolution, repo-root safety.
lib/helpers/filters.sh   → include/exclude glob matching.
lib/helpers/logging.sh   → log_info, log_error, log_warning, log_step.
lib/templates/           → Defaults scaffolded by `agentsync init` only.
```

Business logic lives in `lib/helpers/`. `bin/agentsync.sh` stays a router. `sync.sh` and `check.sh` share code through helpers so both commands stay aligned.

## Hard Constraints

- **Path safety**: `resolve_dest_path()` rejects paths outside `REPO_ROOT_CANONICAL`. Resolve through `normalize_absolute_path()` + `canonicalize_with_existing_ancestor()` — these exist so the codebase stays free of `realpath` and `readlink -f`.
- **Zero external deps**: Pure Bash + coreutils. The codebase reaches its goals without `yq`, `jq`, `python`, `node`, `perl`, or `eval` — reads YAML via parameter expansion through `parse_yaml_value()`.
- **YAML parser scope**: `key: value` and dot-notation nesting. Arrays and multiline blocks need a strong, justified reason to land.
- **Idempotency**: `agentsync sync` produces identical output on repeated runs. No timestamps, no ordering changes, no platform-dependent sorting. `agentsync check` verifies this.
- **Stateless runs**: read config fresh each invocation. Read version numbers from the `VERSION` file rather than embedding them in scripts.
- **Document new inline options** (`inline_into_agents`, `prepend_agents`, etc.) in the `agentsync` skill and `_TEMPLATE.yaml` as part of the change that introduces them.

## Data Flow

1. `sync.sh` reads project config → resolves source paths → iterates `.ai/src/tools/*.yaml`.
2. For each tool: reads `enabled`, reads `targets.*`, reads format options.
3. Dispatches to generic helpers (`copy_file`, `sync_rules`, `sync_dir`, `merge_rules_to_file`, `sync_commands_as_toml`).
4. Each helper stays tool-agnostic — it operates on inputs, not on tool identity.
