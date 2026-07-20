# Kimi Code and OpenCode Complete Agent-Layer Support

Date: 2026-07-20
Status: Proposed

## Objective

Complete AgentSync support for the project-level agent behavior surfaces exposed
by Kimi Code and OpenCode without expanding AgentSync into a dotfiles manager,
credential store, UI customizer, or package manager for arbitrary executable
extensions.

The result must preserve AgentSync's existing properties:

- `.ai/src/` remains the source of truth.
- Generated outputs remain drift-protected and idempotent.
- The CLI keeps its zero-runtime-dependency contract: Bash, standard Unix tools,
  and Git only.
- Unsupported or ambiguous input fails explicitly; sync never drops fields or
  overwrites one source with another silently.

## Product Boundary

AgentSync owns declarative coding-agent behavior that a team can safely commit:

- instructions and rules;
- skills and commands;
- subagent personas;
- permissions and runtime settings;
- MCP client registrations;
- tool-native hook registration.

AgentSync does not own:

- provider credentials, OAuth state, API keys, or account selection;
- personal themes, TUI preferences, notifications, or keybindings;
- arbitrary OpenCode custom-tool implementations;
- arbitrary third-party OpenCode plugins or their dependencies;
- Kimi Code's global runtime home.

An OpenCode hook is the narrow exception to the general plugin exclusion because
OpenCode exposes hooks through its plugin API. AgentSync owns one dedicated
project plugin file for hooks; it does not manage the rest of the plugin tree.

## Considered Approaches

### Portable core only

Keep the current implementation and document OpenCode MCP and hooks as manual
configuration. This keeps the engine simple but leaves two important agent-layer
surfaces outside the source-of-truth workflow.

Rejected because users would need duplicate configuration and could not rely on
`agentsync sync` to produce a complete OpenCode project setup.

### Mirror every vendor surface

Add generic directory passthrough for OpenCode tools, plugins, themes, package
metadata, and TUI configuration, plus global Kimi files.

Rejected because it mixes agent behavior with executable application code,
package installation, personal UI state, and credentials. It would materially
broaden AgentSync's security and lifecycle responsibilities.

### Portable core with native adapters

Keep the existing canonical categories and add narrowly scoped native adapters
where a supported category uses a different vendor format.

Selected because it closes the real behavior gaps while preserving existing
architecture and ownership boundaries.

## Kimi Code Design

The existing Kimi target remains the complete project-level implementation:

- `.kimi-code/AGENTS.md` receives canonical `AGENTS.md` plus the rule inventory.
- `.kimi-code/skills/` receives native skills.
- Canonical commands become `command-*` skills because Kimi exposes external
  workflows through Agent Skills rather than a separate project command format.
- `.kimi-code/mcp.json` receives the canonical `mcpServers` document.

No project-level custom-agent target is added. Kimi currently exposes built-in
`coder`, `explore`, and `plan` subagents but no documented project file format
for defining additional agents.

No default Kimi hooks target is added. Kimi registers hooks in
`$KIMI_CODE_HOME/config.toml`, normally `~/.kimi-code/config.toml`. That file also
owns providers, permissions, and other personal runtime settings. A project sync
must not overwrite or generate a misleading project-local config file that Kimi
does not read.

README and the shipped AgentSync skill will state this boundary and show a
manual, opt-in Kimi hook recipe. They will not imply that AgentSync manages the
global file.

## OpenCode Design

### Existing surfaces

The current mapping remains:

- root `AGENTS.md` for canonical instructions and the rule inventory;
- `.opencode/skills/` for skills;
- `.opencode/commands/` for native commands;
- `.opencode/agents/` for converted canonical subagents;
- root `opencode.json` for settings.

Canonical agents are subagent personas, so the converter continues to emit
`mode: subagent`. It must not reinterpret them as OpenCode primary agents.
Portable tool allowlists remain deny-by-default after conversion, including an
explicit empty list.

### MCP adapter

The OpenCode tool template gains an MCP target whose destination is the same
root `opencode.json` used by settings. The target declares a dedicated OpenCode
merge format instead of copying the canonical JSON byte-for-byte.

Input shape is the canonical AgentSync document:

```json
{
  "mcpServers": {
    "server-name": {}
  }
}
```

This shape is used by both the shared `.ai/src/mcp.json` and an optional
OpenCode-specific `.ai/src/tools/opencode/mcp.json`. The normal payload
resolution order remains unchanged, so the per-tool source overrides the shared
source.

Local server conversion:

```text
command: string                 -> type: "local"
command + args[]                -> command: [command, ...args]
type: stdio                     -> normalized to "local"
env                             -> environment
enabled, timeout                -> preserved when present
```

Remote server conversion:

```text
url                             -> type: "remote", url preserved
type: http|sse|streamable-http  -> normalized to "remote"
headers, enabled, timeout,
oauth                           -> preserved when present
```

Each server must declare exactly one transport: `command` or `url`. Arrays and
maps must contain the expected JSON value types. Unsupported fields, conflicting
transport fields, malformed JSON, or a non-object `mcpServers` value stop sync
with the server name and offending field in the error.

The generated `mcp` object is atomically merged into the resolved settings
output. Every non-MCP field in `opencode.json` is preserved.

There is one source of truth for OpenCode MCP:

- With no canonical MCP source, an existing `mcp` field in the OpenCode settings
  override is preserved for backward compatibility.
- When a canonical MCP source exists, a simultaneous `mcp` field in the settings
  source is an ambiguity and sync fails. The error instructs the user to move
  those entries to `.ai/src/tools/opencode/mcp.json` or the shared
  `.ai/src/mcp.json`.

The implementation reuses or extracts the repository's existing string-,
escape-, and nesting-aware AWK JSON machinery. It does not introduce Python,
Node, `jq`, or `yq` as a runtime dependency.

### Hooks adapter

OpenCode hooks are project plugins. The OpenCode target gains:

```text
source override: .ai/src/tools/opencode/hooks.ts
base template:   lib/templates/hooks/opencode.ts
destination:     .opencode/plugins/agentsync.ts
```

The shipped TypeScript template is a valid no-op OpenCode plugin. Running
`agentsync customize opencode hooks` materializes that template for editing.
Sync copies it as a one-to-one payload and protects it through the existing
manifest and drift mechanisms.

AgentSync manages only `agentsync.ts`; it does not sweep, delete, adopt, or
otherwise own sibling files in `.opencode/plugins/`.

### Settings ownership

OpenCode-specific permissions, models, providers, formatters, LSP configuration,
compaction, npm plugin declarations, and other schema fields continue to live in
the OpenCode settings override. AgentSync copies these fields without attempting
to normalize them.

Provider secrets remain environment or credential-store references. Secret
scanning continues to cover the settings and MCP source files.

## Sync and Drift Flow

For OpenCode, sync performs these steps in order:

1. Generate instructions, rules, skills, commands, and subagents.
2. Resolve the settings and canonical MCP sources without writing the
   destination.
3. Validate both sources, compose the complete output in a temporary file, and
   atomically replace `opencode.json` once.
4. Resolve and copy the native hook plugin to
   `.opencode/plugins/agentsync.ts`.
5. Record only the final hashes in the manifest.

Dry-run performs validation and reports the planned conversion without writing
files. A conversion or ownership conflict returns non-zero before either
`opencode.json` or the manifest is replaced.

`adopt opencode.json` remains available when the destination is a one-to-one
settings copy and no canonical MCP source participates. When MCP composition is
active, adopt refuses the multi-source destination and names the separate source
files to edit. The generated hook plugin remains one-to-one adoptable.

## Diagnostics

`agentsync doctor` will:

- validate OpenCode settings and canonical MCP JSON;
- report the settings-versus-canonical-MCP ownership conflict;
- recognize `.opencode/plugins/` as owned when OpenCode is enabled;
- keep credential findings explicit;
- document, without failing CI, that Kimi hooks are global-only when a user has
  attempted to create an unsupported project hook payload.

Conversion errors during sync are fatal because partial MCP output would make a
successful-looking sync unsafe. Documentation-only capability boundaries remain
advisory.

## Testing Strategy

Tests are added before implementation for:

- local MCP conversion, including argument ordering and `env` renaming;
- remote MCP conversion and supported optional fields;
- shared versus per-tool MCP precedence;
- preservation of all non-MCP OpenCode settings;
- settings/MCP ownership conflicts;
- malformed input, invalid types, unknown fields, and dual transports;
- atomic failure with no partial destination or manifest update;
- dry-run behavior;
- idempotent repeated sync and drift detection;
- conditional adopt behavior for composed `opencode.json`;
- OpenCode hook template fallback, override, customize, and sibling preservation;
- Kimi capability documentation and unsupported-hook diagnostic;
- regression coverage for existing Kimi and OpenCode surfaces.

Verification requires the targeted Bats files, the complete parallel Bats suite,
ShellCheck, `bash -n`, JSON/frontmatter validation, `git diff --check`, and
`lib/check.sh`.

## Compatibility and Migration

Existing projects without shared or per-tool canonical MCP retain their current
`opencode.json` unchanged.

Projects following the previous README guidance and storing MCP inside the
OpenCode settings override continue to work until they add a canonical MCP
source. At that point sync reports the exact migration instead of selecting one
source silently.

No existing Kimi destination changes. No global Kimi file is read or written.

## Success Criteria

- Every safe, documented project-level agent behavior surface for Kimi Code and
  OpenCode is represented or explicitly classified as unavailable.
- Shared `agentsync add mcp` output reaches OpenCode without manual duplication.
- OpenCode hooks are versionable through the native project plugin mechanism.
- No credentials, UI state, arbitrary plugins, or custom tools enter AgentSync's
  ownership implicitly.
- Existing tools and projects remain backward compatible.
- All specified verification gates pass.
