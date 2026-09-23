# MCP library roadmap

The problem from [PR #16](https://github.com/yelmuratoff/agent_sync/pull/16) is
worth keeping: a user should be able to find a documented MCP connection,
choose a variant, and prepare an AgentSync source without copying server JSON
by hand. PR #16 targets the retired Bash engine and conflicts with the current
Rust code, so its implementation is a reference, not a branch to merge.

[PR #20](https://github.com/yelmuratoff/agent_sync/pull/20) delivers the first
slice. `mcp list/show/validate` reads a selected local catalog, validates v1/v2
manifests, and does not write configuration or contact an MCP server. The
[catalog contract](mcp-library.md) defines that behavior.

## Next slices

1. **Render one explicit selection.** Add `mcp render <id>[@variant]` in the Rust
   CLI. An omitted suffix selects `default`; `@recommended` works only when the
   manifest has attributed guidance, and an unknown variant fails. Render only
   the selected `connection` as canonical AgentSync MCP source JSON on stdout.
   Never execute its command, probe its URL, install a package, or read secrets.
   Test exact output and failures for every selection form against local fixtures.

2. **Preview and materialize a per-tool source.** Add `mcp use` with a read-only
   preview by default and a separate `--apply` write. Require a named, enabled
   tool and resolve its source location through the existing `source.tools` and
   payload rules. A first implementation should refuse an occupied or ambiguous
   source instead of overwriting it. Use the existing transaction and staging
   patterns for writes, then verify that a failed operation restores the prior
   bytes. Preview and errors must never print existing source values, which may
   include credentials. Running `agentsync sync` remains a separate user action.

3. **Support guarded extension of an existing source.** If users need to add a
   selection to an occupied per-tool source, design `--merge` as its own change.
   Preserve unrelated JSON members, reject duplicate or unsupported structures,
   and require an explicit selected ID for replacement. Cover unchanged replay,
   conflict, backup, interruption, and concurrent-writer cases before enabling
   writes. Do not silently migrate shared, legacy, or alternate sources.

4. **Review client adapters independently.** Confirm Claude, OpenCode, and Kimi
   against their current tool YAML and normal sync behavior. Codex needs a
   separate Rust change because its MCP configuration shares
   `.codex/config.toml` with settings; detect ownership conflicts rather than
   rewriting arbitrary TOML. Test `sync`, `check`, `doctor`, and `adopt` for each
   supported path on Linux, macOS, and Windows before claiming compatibility.

5. **Curate small pilot entries.** Port the Microsoft Learn, Context7, and
   Octocode examples from PR #16 only after checking their current vendor or
   maintainer documentation. Keep transport and variant requirements explicit;
   record the source and review date of every recommendation. Validation proves
   catalog structure, not that a service is safe, reachable, or endorsed.

Each slice should be a separate reviewable PR with focused integration tests.
The next implementation starts with `src/cli/mcp.rs`,
`src/config/mcp_catalog.rs`, and `tests/mcp.rs`; source writes and client
composition cross into `src/engine/render/` and require their command-level
tests as well.

## Not planned as part of this library

Automatic server installation or launch, OAuth or credential binding, endpoint
probing, implicit variant fallback, and live catalog-to-client synchronization
are outside this workflow. A catalog selection is an explicit snapshot; later
catalog edits must not silently alter a project's MCP configuration.
