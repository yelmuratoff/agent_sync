# Architecture Rules

## Config-Driven Design

- All tool behavior is defined in YAML configs (`.ai/src/tools/*.yaml`). Sync logic reads these declaratively — don't hardcode tool names, paths, or formats in `lib/sync.sh`.
- Source paths come from `config.yaml` and project-level `.ai/agent_sync.yaml`. Don't hardcode `.ai/src/` paths — use `resolve_source_override` and the `SOURCE_*` variables.
- Default values (`enabled`, `cleanup`) come from `config.yaml` `defaults:` section. Don't hardcode defaults in sync logic.
- Tool-specific settings (permissions, MCP, hooks) are loaded from `source:` fields in each tool's YAML — not from hardcoded file paths.

## Adding New Tools

- One YAML file per tool in `.ai/src/tools/`. The YAML declares `name`, `enabled`, and `targets` with `dest` paths.
- If a tool needs format conversion (e.g., `.md` → `.mdc`, TOML agents), add the converter in `lib/helpers/format_conversion.sh` and reference it from the tool's YAML — don't inline conversion logic in `sync.sh`.
- New tools must have bats tests in `tests/sync.bats` and `tests/sync_options.bats`.
- Template defaults for new tools go in `lib/templates/tools/`.

## Module Boundaries

- `bin/agentsync.sh` — CLI entry point only. Delegates to helpers. No business logic here.
- `lib/sync.sh` — Orchestration: reads configs, iterates tools, calls helpers. Avoid tool-specific `if/case` blocks — use YAML target declarations.
- `lib/helpers/*.sh` — One file per concern: `yaml.sh` (parsing), `file_ops.sh` (copy/write), `filters.sh` (--only/--skip), `gitignore.sh`, etc.
- `lib/templates/` — Default scaffolding for `agentsync init`. Never used at sync time.

## Anti-Patterns

- Don't add `if [[ "$tool_name" == "cursor" ]]; then ...` in sync logic. Use YAML target options (`format`, `extension`, `frontmatter`) to declare differences.
- Don't hardcode version numbers — read from `VERSION` file.
- Don't duplicate logic between `sync.sh` and `check.sh` — extract shared helpers.
- Don't store state between syncs. Every `agentsync sync` run reads config fresh and writes from scratch.
- Don't add inline options (`inline_into_agents`, `prepend_agents`) without documenting them in the `agentsync` skill and `_TEMPLATE.yaml`.
