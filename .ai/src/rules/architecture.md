---
paths:
  - "bin/**"
  - "lib/**"
  - ".ai/src/tools/**"
---

# Architecture Rules

The sync engine is config-driven: shipped tool behaviour lives in `lib/templates/tools/*.yaml`, project overrides live in `.ai/src/tools/`, and generic helpers in `lib/helpers/` do the work. Extend by adding a YAML option, then handling it in a helper — not by branching on a tool name.

## Config-Driven Sync Engine

- Declare shipped behavior in `lib/templates/tools/*.yaml` and repository-specific differences in `.ai/src/tools/*.yaml`. `sync_tool()` reads the resolved `targets.*` values and routes to helpers.
- Express format differences through YAML target options (`extension`, `header`, `merge_to_file`, `inline_into_agents`, `prepend_agents`, `append_imports`, `as_skills`). Add a new option and a helper rather than an `if [[ "$tool_name" == "cursor" ]]` branch.
- Resolve source paths through `resolve_source_override()` → project `agent_sync.yaml` → global `config.yaml`. Reference the `SOURCE_*` variables set by `_resolve_source_paths()`.
- Read defaults (`enabled`, `cleanup`) from `config.yaml` into `DEFAULT_ENABLED` / `DEFAULT_CLEANUP`, then propagate from there.

## Module Map

```
bin/agentsync.sh               → CLI router; delegates to focused helper modules.
lib/sync.sh                    → orchestration, tool/profile passes, transactions.
lib/helpers/yaml.sh            → supported YAML scalar, nesting, and list shapes.
lib/helpers/tool_resolver.sh   → layered base/user/profile config and payload resolution.
lib/helpers/file_ops.sh        → safe copying, directory sync, and cleanup.
lib/helpers/rule_operations.sh → rule headers, merges, imports, and scoping.
lib/helpers/format_conversion.sh / opencode.sh → target format conversion and composition.
lib/helpers/paths.sh / filters.sh             → containment and include/exclude matching.
lib/helpers/backup.sh / manifest.sh           → transactions, ownership, and drift.
lib/helpers/shared.sh / profiles.sh           → source overlays and config-home variants.
lib/templates/                 → shipped tool/payload bases and init/refresh content.
```

Business logic lives in `lib/helpers/`. `bin/agentsync.sh` stays a router. `sync.sh` and `check.sh` share code through helpers so both commands stay aligned.

## Hard Constraints

- **Path safety**: `resolve_dest_path()` rejects paths outside `REPO_ROOT_CANONICAL`. Resolve through `normalize_absolute_path()` + `canonicalize_with_existing_ancestor()` — these exist so the codebase stays free of `realpath` and `readlink -f`. `is_path_safe_source()` allows three roots: `$REPO_ROOT_CANONICAL`, `$DEFAULT_REPO_ROOT`, and (when active) `$SHARED_OVERLAY_DIR_CANONICAL` — the third covers the transient `shared:` shadow tree built by `lib/helpers/shared.sh` and torn down via an EXIT trap.
- **Zero external deps**: Pure Bash + coreutils. The codebase reaches its goals without `yq`, `jq`, `python`, `node`, `perl`, or `eval` — reads YAML via parameter expansion through `parse_yaml_value()`.
- **YAML parser scope**: scalar keys, dot-notation nesting, and the explicitly supported list forms. New YAML shapes need a concrete engine requirement and parser tests.
- **Idempotency**: `agentsync sync` produces identical output on repeated runs. No timestamps, no ordering changes, no platform-dependent sorting. `agentsync check` verifies this.
- **Stateless runs**: read config fresh each invocation. Read version numbers from the `VERSION` file rather than embedding them in scripts.
- **Transactional mutation**: `init`, `sync`, and `rollback` snapshot their complete managed write set. Failures restore the previous state; successful operations prune completed history through `backup_prune`.
- **Document new inline options** (`inline_into_agents`, `prepend_agents`, etc.) in the `agentsync` skill and `_TEMPLATE.yaml` as part of the change that introduces them.

## Data Flow

1. `sync.sh` resolves source overlays and the layered tool catalog, then dispatches each target to generic copy, conversion, composition, and manifest helpers.
2. Helpers operate on resolved inputs rather than tool identity; EXIT traps clean overlays and restore failed transactions.
