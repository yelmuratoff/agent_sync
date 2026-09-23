# MCP pilot catalog

These are opt-in examples for `agentsync mcp --library`; they are not embedded
defaults. The source documents were checked on 2026-09-23. Catalog validation
checks the manifest format, not server availability, client compatibility, or
the safety of a server's tools.

| Entry | Connection | Requirements before client use |
| --- | --- | --- |
| `microsoft-learn` | Public Streamable HTTP | A client supporting remote HTTP MCP; no authentication required. |
| `context7` | Remote Streamable HTTP at the OAuth endpoint | An OAuth-capable MCP client and account authorization. AgentSync does not perform login. |
| `octocode` | Local stdio through `npx` | Node.js `^22.22.2`, `^24.15.0`, or `>=26`; `npx` may download the pinned package at first launch. GitHub login is optional for public access, and needed for private repositories or higher rate limits. |

Use an absolute path when your project is elsewhere:

```sh
agentsync mcp list --library /path/to/agent_sync/catalog/mcp
agentsync mcp show microsoft-learn --library /path/to/agent_sync/catalog/mcp
agentsync mcp use microsoft-learn --tool claude --library /path/to/agent_sync/catalog/mcp
```

`use` previews the source. Repeating it with `--apply` creates only the source;
`agentsync sync` is a separate action that updates a client. Review a server's
permissions and data access before syncing it into a client.

Sources: [Microsoft Learn MCP overview](https://learn.microsoft.com/en-us/training/support/mcp),
[Context7 MCP client guide](https://context7.com/docs/resources/all-clients),
[Octocode setup](https://github.com/bgauryy/octocode/blob/main/README.md), and
[the pinned Octocode npm release](https://www.npmjs.com/package/octocode-mcp/v/19.1.0).
The Context7 OAuth choice and Octocode version pin are catalog maintainer choices,
not provider recommendations. The basic manifest format has no secret binding or
runtime-version constraint field, so these requirements remain explicit here;
`requirements.inputs` is empty because AgentSync cannot bind credentials.
