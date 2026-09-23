# Offline MCP catalog inspection

An MCP catalog is a local directory of JSON manifests. AgentSync reads it only
when you pass `--library` or configure its path. Catalog inspection does not
start a server, contact an endpoint, install a package, look up credentials, or
change project or client configuration.

```text
agentsync mcp list --library catalog/mcp
agentsync mcp show example --library catalog/mcp
agentsync mcp validate --library catalog/mcp
agentsync mcp validate example --library catalog/mcp
agentsync mcp render example@default --library catalog/mcp
agentsync mcp use example --tool claude --library catalog/mcp
agentsync mcp use example --tool claude --library catalog/mcp --apply
agentsync mcp use another --tool claude --library catalog/mcp --merge --apply
```

An explicit path may be absolute or relative to the selected project root. Or
set `library.mcp.path` in `.ai/agent_sync.yaml` (or the selected config file):

```yaml
library:
  mcp:
    path: catalog/mcp
```

A configured path must resolve inside the project root. There is no implicit
catalog search. The layout is `catalog/mcp/<id>/manifest.json`. IDs have 1–64
ASCII letters, digits, underscores, or hyphens, beginning with a letter or
digit. Entry directories and manifests must be regular filesystem objects;
symlinks are rejected. Other files at the catalog root, such as a README, are
ignored. Concurrent hostile changes to a catalog directory are outside this
read-only command's filesystem guarantee.

The repository includes an opt-in [pilot catalog](../catalog/mcp/README.md).
Pass its absolute path when using it from another project; AgentSync does not
load it by default or embed it in the binary.

`list` prints `id<TAB>title` in ID order and escapes controls, non-space
whitespace, and Unicode 17.0 default-ignorable characters in titles. `show`
validates the selected manifest and prints its exact source bytes.
`validate [id]` checks one entry or the whole catalog. A whole-catalog
operation validates every entry before writing to stdout. Errors go to stderr
and leave stdout empty.

`render <id>[@variant]` validates the selected manifest and prints one
AgentSync MCP source JSON object. An omitted variant or `@default` selects the
top-level connection. A named variant selects its alternative;
`@recommended` uses attributed guidance and fails if guidance is absent.
Unknown variants fail. For example, the version 1 manifest below renders as:

```json
{"mcpServers":{"example":{"args":[],"command":"example-mcp"}}}
```

HTTP connections render with `type: "http"` and `url`. Only the selected
connection is included; manifest metadata and requirements are not copied.
Rendering does not execute the command, contact the URL, or write a source.

`use <id>[@variant] --tool <slug>` previews the selected connection JSON and
the path of the per-tool MCP source it would create.
The tool must be enabled and have an MCP destination. `--apply` writes the
source under the configured `source.tools` directory (by default
`.ai/src/tools/<slug>/mcp.json`) and records a backup that `agentsync rollback`
can restore. Without `--merge`, it refuses an existing per-tool, declared,
legacy, or shared MCP source. `--merge` is limited to an existing regular
per-tool `mcp.json`. It adds the selected ID under `mcpServers` while preserving
other JSON members and server entries. Duplicate JSON keys and unsupported
structures are refused. If that ID has different content, pass
`--replace <id>` with the exact selected ID to replace it. Repeating an
unchanged selection does not write or create another backup. Merging can
normalize JSON formatting, so review the preview and source diff. The preview
and errors never print existing source values. `agentsync sync` is a separate
step to update generated client files.

An apply operation holds a per-tool lock, snapshots the source, checks it has
not changed while preparing the write, and replaces it atomically. A stopped
process may leave `.agentsync-mcp-use.lock`; inspect the source and remove that
lock before retrying. Writes by other programs in the narrow interval after
the final check cannot be detected, so do not edit the same source concurrently
outside AgentSync.
For Kimi, `use` writes its native `mcp.json` form: HTTP connections have a
`url` without the canonical `type: "http"` field. Claude keeps the canonical
form in `.mcp.json`; OpenCode composes it into `opencode.json` during `sync`.
`render` always prints the canonical form, independent of the target tool.
Hand-written shared HTTP sources are copied to Kimi unchanged; use a per-tool
Kimi source with its native `url` shape for those servers.
For Codex, normal `sync` composes selected MCP servers into the existing
`.codex/config.toml` settings. It supports stdio `command`, string `args`, and
string `env` entries, or an HTTP(S) `url`; other server fields are refused.
Settings that already define or may encode `mcp_servers` conflict with a
separate MCP source and leave the generated config unchanged. Edit the two
sources separately; `adopt` cannot split a composed config back into them.

## Manifest format

A version 1 manifest has this shape:

```json
{
  "schema_version": 1,
  "id": "example",
  "title": "Example MCP",
  "connection": {"type": "stdio", "command": "example-mcp", "args": []},
  "requirements": {"binaries": ["example-mcp"], "inputs": []}
}
```

The required fields are `schema_version`, `id`, `title`, `connection`, and
`requirements`. `id` must match its directory. Optional fields are a string
`description`, `provenance` with string-or-null `homepage`, `repository`, and
`artifact` fields, and `extensions`, an object with namespaced keys such as
`example.invalid`. Extension values are opaque JSON, though their syntax and
depth are checked. Unknown fields outside extensions are rejected.

`connection.type` is `stdio` or `http`. Stdio needs a nonempty `command` and
string `args` array; HTTP needs a nonempty `url`. Both forms reject fields of
the other form. `requirements` needs string arrays `binaries` and `inputs`.
`inputs` must currently be empty because secret and input binding is not
implemented. Declared binaries and URLs are not checked or used by these
commands.

Version 2 also permits `alternatives` and `guidance`:

```json
{
  "schema_version": 2,
  "id": "example",
  "title": "Example MCP",
  "connection": {"type": "http", "url": "https://example.invalid/mcp"},
  "requirements": {"binaries": [], "inputs": []},
  "alternatives": {
    "local": {
      "connection": {"type": "stdio", "command": "example-mcp", "args": []},
      "requirements": {"binaries": ["example-mcp"], "inputs": []}
    }
  },
  "guidance": {
    "recommended": "default",
    "authority": "vendor",
    "source": "https://example.invalid/docs",
    "checked_at": "2026-09-16",
    "reason": "Documented hosted connection"
  }
}
```

Every alternative is validated, even if its connection is not selected for
anything. Alternative IDs follow entry-ID rules; `default` and `recommended`
are reserved. Guidance must name `default` or an existing alternative, name
`vendor` or `maintainer` as its authority, cite an HTTPS source, and include a
real calendar date and nonempty reason. Guidance is an attributed catalog
claim, not an AgentSync verification of that recommendation.

Each manifest is limited to 128 KiB, JSON nesting to 16 containers, and a
whole catalog to 256 entries. JSON must be UTF-8 with no duplicate object
keys at any depth, including keys that become equal after escape decoding.
`show` preserves source spelling; it does not normalize valid JSON. These
limits define the catalog format, not general JSON Schema support.

Catalog inspection, rendering, and guarded creation or extension of a per-tool
source do not connect to a server. The delivery history and boundaries are in
the [MCP roadmap](mcp-roadmap.md).
