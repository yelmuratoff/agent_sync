# MCP library: inspect, choose, and prepare CLI sources

AgentSync can read an explicitly selected local MCP catalog without running a
server, accessing the network, or changing a project or catalog file. This is
separate from `agentsync add mcp`, which continues to manage `.ai/src/mcp.json`.
The explicit `use --apply` command can create a per-tool source for a later
normal sync. It does not modify native client configuration itself.

## Select a catalog

Use one of these forms:

```sh
agentsync mcp list --library catalog/mcp
agentsync mcp show example --library catalog/mcp
agentsync mcp validate --library catalog/mcp
agentsync mcp validate example --library /absolute/catalog/mcp
```

`--library` is explicit and may be absolute or relative to the selected
AgentSync root (`AGENTSYNC_REPO_ROOT`, otherwise the current directory). Without
the option, the selected `agent_sync.yaml` must contain:

```yaml
library:
  mcp:
    path: "catalog/mcp"
```

That configured path must stay under the selected root after symlinks resolve.
No directory is searched implicitly. Catalog entries use this layout:

```text
catalog/mcp/<id>/manifest.json
```

Entry IDs are 1–64 ASCII characters matching
`[A-Za-z0-9][A-Za-z0-9_-]*`, and must match both the directory name and manifest
`id`. Entry-directory symlinks and manifests resolving outside the selected
catalog are rejected.

## Commands and output

`list` prints `id<TAB>title`, sorted by ID. ASCII controls and UTF-8 C1 controls
in titles are rendered as `\t`, `\n`, `\r`, or `\u00XX` so list output cannot
inject terminal control lines. `show <id>` validates the manifest
then writes its original JSON bytes to standard output. `validate [id]` checks a
single selected entry or the whole catalog; full-catalog validation also detects
duplicate manifest IDs. Diagnostics go to standard error and return non-zero.

These three inspection commands are offline and read-only. They do not execute `stdio`
commands, contact HTTP endpoints, read credentials, write native client config,
or run the normal CLI update check.

## Prepare an explicitly selected CLI source

```sh
# Emit canonical AgentSync MCP JSON to stdout; diagnostics go to stderr.
agentsync mcp render example --library catalog/mcp

# Preview a selection for an already enabled client; no files are written.
agentsync mcp use example --tool claude --library catalog/mcp

# Explicitly request a documented recommendation, then create the source.
agentsync mcp use example@recommended --tool claude --library catalog/mcp --apply
agentsync sync --only claude

# Several servers, with per-entry variants when needed.
agentsync mcp use example@uvx another@default --tool opencode --library catalog/mcp --apply
agentsync sync --only opencode
```

`claude`, `opencode`, `codex` and `kimi` are supported by `use`. Enable the client
explicitly first. Other clients require additional adapters and are rejected
instead of receiving guessed JSON.

`render` emits `{"mcpServers":{...}}`, an **AgentSync source**, not native
OpenCode configuration. `use --apply` creates
`.ai/src/tools/<tool>/mcp.json` (or the corresponding in-project `source.tools`
path). The existing sync pipeline copies this for Claude and translates it
for OpenCode. Codex composes the selected connections with its settings source
into project-local `.codex/config.toml`. Per-tool settings remain under their
existing ownership.

### Codex composition boundary

```sh
agentsync mcp use example@recommended --tool codex --library catalog/mcp
agentsync mcp use example@recommended --tool codex --library catalog/mcp --apply
agentsync sync --only codex
```

The Codex adapter prepends one root `mcp_servers = { ... }` TOML assignment,
then preserves the settings source byte-for-byte. It does not rewrite arbitrary
TOML. Without a separate MCP source, settings retain the existing copy behavior,
including hand-authored MCP sections. With both sources present, overlapping or
ambiguous ownership fails before replacing the native configuration. `doctor`
reports that conflict; `adopt` refuses to copy a composed file back into a single
source.

The ownership check is deliberately conservative, not a full TOML validator:
it ignores full-line comments but refuses `mcp_servers` anywhere else, and
backslashes on lines beginning with quoted keys or table headers. This can
reject harmless mentions or escaped strings. Keep MCP in one source rather
than relying on a best-effort merge. The settings source must already be valid
TOML. Only canonical `command`/`args` and `type: http`/`url` MCP entries are
accepted; unsupported fields such as `env` or headers fail instead of being
silently discarded. The same restriction applies to a shared MCP source.

The adapter never edits the user's global Codex config, starts a server or
changes project trust. Codex's project-scoped configuration requires a trusted
project; see the [official MCP documentation](https://developers.openai.com/codex/mcp).
An explicit `targets.mcp.enabled: false` blocks library use and leaves dormant
MCP sources out of sync composition, doctor ownership checks and adopt refusal.

`use` defaults to preview; `--dry-run` is an explicit synonym. `--apply` and
`--dry-run` are mutually exclusive. No runtime is installed or started. HTTP
URLs are not contacted. Authentication, credentials, mounts and endpoints are
not verified by these commands.

This is **snapshot materialization**, not a live link: catalog changes do not
silently change the generated source. Identical reapplication is a no-op;
different existing per-tool, shared, legacy or declared sources cause a clear
conflict unless the explicit merge workflow below applies. Publishing
requires a filesystem supporting ordinary file hard links; unsupported writes
fail rather than falling back to overwriting a destination. Concurrent hostile
changes to directory structure are outside the supported write model.

### Extend an existing per-tool source

```sh
agentsync mcp use example --tool claude --merge --library catalog/mcp
agentsync mcp use example --tool claude --merge --apply --library catalog/mcp
# A differing selected ID needs explicit permission to replace its entire entry:
agentsync mcp use example --tool claude --merge --replace example --apply --library catalog/mcp
```

Merge requires an existing canonical `.ai/src/tools/<tool>/mcp.json` (respecting
`source.tools`). Shared, legacy and alternate declared sources are not migrated
implicitly. New IDs are added, identical entries are left alone, and conflicting
selected IDs fail without `--replace ID`. Repeat that option for multiple IDs.
Replacement replaces the whole selected server, including any old env or headers;
it is not a field-level overlay. Unrelated root fields and server objects retain
their JSON meaning, although formatting may change. Existing JSON must pass the
strict parser, use safe server IDs, stay within 32 MiB, 16 nesting levels and 256
servers. No server is removed automatically.

The preview prints selected IDs and actions, never existing configuration values.
Apply holds a per-target directory lock, stages and size-checks the complete
result, backs up the prior file and checks for changed source bytes before
publishing. Concurrent AgentSync merge writers fail rather than overwrite each
other. Normal exit, INT and TERM clean registered temporary files and the lock.
SIGKILL or power loss cannot be trapped: after confirming no writer remains,
inspect and remove only that target's stale `mcp.json.mcp-library.lock` and any
identified leftover staging files. Temporary files and backup snapshots may
contain existing credentials and must be treated as private data.

These checks are not a filesystem transaction with non-cooperating editors or
protection against a hostile concurrent directory replacement. A later sync still
enforces each adapter's restrictions: preserving a foreign field during merge does
not make it supported by the Codex adapter, for example.

Kimi uses the existing project `.kimi-code/mcp.json` adapter. Its documented
project trust and native OAuth login remain the client's responsibility; see
[Kimi's MCP documentation](https://www.kimi.com/code/docs/en/kimi-code-cli/customization/mcp.html).
The existing copy adapter retains the canonical HTTP `type` field; Kimi's
current schema accepts it, but its docs show URL-only entries. This is not a
native-client compatibility guarantee across future versions.

## Manifest schema v1

The root object permits only these fields:

```json
{
  "schema_version": 1,
  "id": "example",
  "title": "Example MCP",
  "description": "Optional display text.",
  "provenance": {
    "homepage": "https://example.invalid",
    "repository": null,
    "artifact": null
  },
  "connection": {
    "type": "stdio",
    "command": "example-mcp",
    "args": ["--safe"]
  },
  "requirements": {
    "binaries": ["example-mcp"],
    "inputs": []
  },
  "extensions": {
    "example.invalid": {"opaque": true}
  }
}
```

Required fields are `schema_version` (exactly `1`), `id`, `title`,
`connection`, and `requirements`. `description`, `provenance`, and `extensions`
are optional. Provenance permits only `homepage`, `repository`, and `artifact`,
each a string or `null`. Extension keys must be namespaced (for example,
`example.invalid`); their values are opaque JSON.

`connection.type` is exactly `stdio` or `http`. Stdio requires a non-empty
`command` and an `args` string array. HTTP requires a non-empty `url` and does
not permit command or args fields. Requirements requires `binaries` and `inputs`
string arrays. In this first read-only API, `inputs` must be empty: structured
input binding is explicitly unsupported.

The parser rejects malformed JSON, invalid UTF-8, unknown fields, unknown schema
versions, duplicate JSON object keys at any depth (including equivalent escaped
Unicode keys), duplicate catalog IDs, and unpaired surrogate escapes. It accepts valid control escapes as
JSON data. `show` does not decode and re-encode strings, so valid Unicode,
arguments, backslashes, quotes, and escaped control values retain their source
spelling.

To keep validation bounded, a manifest is limited to 131,072 bytes (with or
without a final newline), JSON nesting to 16 levels, and a catalog to 256
entries. These are intentional format limits, not general JSON Schema support.

## Schema v2: sourced recommendations and optional alternatives

Schema v1 remains supported unchanged. Version 2 retains the required primary
`connection` and `requirements` as variant `default`, and optionally adds
`alternatives` and `guidance`. Each alternative owns its own connection and
requirements: a remote endpoint must not inherit a local uvx dependency.

The following is a **synthetic example**, not a real provider recommendation:

```json
{
  "schema_version": 2,
  "id": "example",
  "title": "Example MCP",
  "connection": {"type": "http", "url": "https://example.invalid/mcp"},
  "requirements": {"binaries": [], "inputs": []},
  "alternatives": {
    "uvx": {
      "description": "Optional local package launch",
      "connection": {
        "type": "stdio",
        "command": "uvx",
        "args": ["--from", "example-mcp==1.0.0", "example-mcp"]
      },
      "requirements": {"binaries": ["uvx"], "inputs": []}
    }
  },
  "guidance": {
    "recommended": "default",
    "authority": "vendor",
    "source": "https://example.invalid/docs/mcp",
    "checked_at": "2026-09-16",
    "reason": "Illustrative provider-documented hosted connection"
  }
}
```

`guidance` records who recommends a variant (`vendor` or catalog `maintainer`),
the HTTPS source, the date of review and a reason. It is an attributed claim,
not a certification by AgentSync. Catalog authors must check the cited source;
the validator checks structure, not whether the provider made that statement.
Without guidance the recommendation is **unknown**, not inferred from HTTP,
the variant name, or the presence of a default connection.

Selection is always explicit:

- `example` selects `default`, regardless of guidance.
- `example@recommended` resolves the recorded recommendation or fails if absent.
- `example@uvx` selects that alternative or fails if absent.
- `--variant NAME` sets the choice for entries without an `@variant` suffix.
- Repeated IDs are rejected, even if their variants differ.

Alternative names use the same safe ID syntax as entries; `default` and
`recommended` are reserved. All variants are validated, including unselected
ones. An invalid or missing alternative never falls back to a remote service.
The original manifest and its guidance remain available through `mcp show`;
only the selected connection goes into the client source.

Start methods such as `uvx`, `uv run`, `npx`, Docker or a standalone executable
remain ordinary `command` plus `args`, not new MCP transports. Package versions
and image digests can be pinned in those arguments, but AgentSync does not
resolve packages, inspect images or lock transitive dependencies. Input binding
remains deferred; `requirements.inputs` stays empty. The bundled
[pilot catalog](../catalog/mcp/README.md) records descriptive authentication and
runtime requirements in a namespaced extension, with a separate development
checker and offline freshness queue. It does not enforce those requirements.

## Development validation

The production path uses Bash and awk, with no new Python, Node, or jq runtime
dependency. The independent development probe uses Python's standard JSON
decoder with duplicate-key rejection:

```sh
python3 tests/mcp_library_probe.py
# Optional comparison, not a replacement for the strict oracle:
python3 tests/mcp_library_probe.py --compare-jq
```

The probe checks valid and malformed JSON, equivalent escaped keys, nested
extensions, UTF-8, and byte-exact `show`. It is not a complete JSON conformance
suite or proof of safe execution of a described server. The CLI does not check
whether binaries exist, endpoints are reachable, or provenance is trustworthy.

Local development validation uses a non-root user in a network-disabled,
mount-free Linux container. CI runs ShellCheck, Bats on Linux/macOS/Windows,
and the reference probe with GNU awk and mawk on Linux and native awk/Bash on
macOS. Local Linux results do not establish macOS or Windows compatibility.

Live catalog bindings, automatic config merging without explicit selection, release management, secret
binding and server lifecycle management are not implemented. The older `add
mcp` workflow is unchanged.
