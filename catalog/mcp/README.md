# MCP pilot catalog

These entries are opt-in examples, not an installed server list. Sources were
reviewed on 2026-09-16; no server or authentication flow was executed.

| Entry | Selected default | Authentication owner |
| --- | --- | --- |
| `microsoft-learn` | Public Streamable HTTP | None |
| `context7` | Remote OAuth endpoint | Native MCP client |
| `octocode` | Local stdio, pinned npm package | Server/provider login or inherited environment |

Octocode is **not** a public hosted MCP endpoint. Its catalog entry requires
Node.js and npx. GitHub operations need provider authentication; local and
remote prerequisites are kept separate.

Use an absolute catalog path when selecting these entries from another project:

```sh
agentsync mcp use microsoft-learn --tool claude --library /path/to/agent_sync/catalog/mcp
# Inspect the preview, then repeat with --apply; native config changes only at sync.
```

## Requirements convention

`extensions["agentsync.dev"]` is an experimental catalog-maintainer convention,
not a new MCP standard or an extension to the Agent Skills standard. The core
manifest validator treats extensions as opaque JSON. The development checker
below validates this convention for the bundled catalog.

Each selectable variant records authentication kind and owner, conditional
requirements, runtime constraints, descriptive network hosts, capabilities and
notes. Environment entries contain **names only**, never credentials. Network
hosts are documentation, not a complete firewall allowlist. These records are
not runtime readiness checks or proof of client compatibility.

`guidance.authority` distinguishes vendor guidance from our maintainer choice.
Context7 OAuth and the Octocode version pin are maintainer choices, not claims
that the vendor recommends them over every alternative.

`optional_methods` describes supported provider approaches which are deliberately
**not selectable variants** yet. For example, Context7 API-key headers and local
npx are documented but do not bypass the current absence of secret/input binding.
OAuth requires an OAuth-capable client and its own native login flow. AgentSync
neither logs in nor reads, writes or validates tokens.

## Offline freshness queue

```sh
python3 tests/check_mcp_catalog.py
python3 tests/check_mcp_catalog.py --as-of 2026-09-16 --fail-stale
```

The checker validates production manifests and catalog metadata, then emits a
JSON review queue from `checked_at` and `review_after_days`. It does not fetch
sources, resolve package versions, change dates or schedule recurring work.
A due record is a request for review, not proof that its requirements changed.
Only update `checked_at` after substantively rechecking the cited primary sources.
Evidence URLs must use HTTPS without user information, query strings or fragments;
the checker must not echo unclassified query credentials into its review report.

The per-entry manifests own source URLs and detailed requirements. Possible
later authenticated pilot: [Tavily remote MCP](https://docs.tavily.com/documentation/mcp),
using native OAuth or explicit header binding; never put API keys in catalog URLs.
