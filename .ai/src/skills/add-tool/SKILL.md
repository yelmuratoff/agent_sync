---
name: add-tool
description: Add support for a new AI coding tool to AgentSync's sync engine — create the tool YAML, configure targets and converters, add base templates, and write tests. Use this skill when integrating a new AI assistant, IDE, or editor into AgentSync, when a user asks "can AgentSync sync to X", or when extending the sync surface to a new agent — even if the user names the tool by brand without saying "tool" or "integration".
---

# Add New Tool Support

Add a new AI coding tool to AgentSync so `agentsync sync` distributes instructions to it.

## Steps

1. **Study an existing tool config** — Read `.ai/src/tools/claude.yaml` or `.ai/src/tools/cursor.yaml` for the pattern.
2. **Create the tool YAML** — Copy `.ai/src/tools/_TEMPLATE.yaml` to `.ai/src/tools/<tool>.yaml`.
3. **Configure targets** — Define where each content type goes:
   - `agents` → main instructions file
   - `rules` → rules directory or merged file
   - `skills` → skills directory (if supported)
   - `commands` → commands directory (if supported)
   - `subagents` → agents directory (if supported)
   - `settings` / `mcp` → tool-specific config files
4. **Handle format differences** — Check if the tool needs:
   - `.mdc` extension instead of `.md` (Cursor)
   - Frontmatter wrapping (`alwaysApply: true` for Cursor rules)
   - Inline skill/rule merging into agents file (`inline_into_agents: true`)
   - `00-context.md` pattern for AGENTS.md content in rules dir
   - TOML format for agents (Codex)
5. **Add sync logic** — If the tool needs custom transformation, add a handler in `lib/sync.sh` (look for the `sync_tool` function and existing tool-specific blocks).
6. **Add to `lib/templates/tools/`** — Create a default YAML config.
7. **Write tests** — Add assertions in:
   - `tests/sync.bats` — verify output files exist
   - `tests/sync_options.bats` — verify `--only`/`--skip` filtering
   - `tests/check.bats` — verify `agentsync check` detects drift
8. **Test on all platforms** — Run `bats tests/sync.bats` locally, verify CI passes.

## Gotchas

- Every tool has quirks. Read the tool's docs for where it expects instruction files.
- Some tools share output paths (e.g., Copilot uses `.github/`). Check for collisions with existing tools.
- The custom YAML parser doesn't support arrays or multiline YAML blocks — keep tool configs flat.
- Register the tool in `lib/helpers/list.sh` so `agentsync list` includes it.
- Tool names must be lowercase and match the YAML filename (e.g., `claude.yaml` → tool name `claude`).
- The `example/` directory output is gitignored — after adding a tool, run sync in `example/` to verify output.
