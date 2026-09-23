# MiniMax Code target

[PR #7](https://github.com/yelmuratoff/agent_sync/pull/7) proposed a
MiniMax target for the retired Bash engine by mirroring OpenCode's project
files. It is not a branch to merge into the Rust engine: the review found
unresolved output differences and ambiguous auto-detection, and its version
bump belongs to a separate release.

The [MiniMax Code source README](https://github.com/MiniMax-AI/minimax-code/blob/main/README.md)
documents a current terminal CLI and `AGENTS.md` project guidance. It also
states that the desktop application's source is not included there. This is
enough to keep the integration idea, but not enough to assert that the CLI or
desktop consumes OpenCode's `opencode.json`, `.opencode/`, or plugin files.

Before adding a `minimax` tool, choose the product and version to support and
verify its project-level instruction, skill, command, subagent, settings, MCP,
and hook surfaces against current first-party documentation or a reproducible
installed-client check. Map only confirmed surfaces in
`lib/templates/tools/minimax.yaml`; keep credentials and user-global state out
of AgentSync. Test `sync`, `check`, `doctor`, `adopt`, rollback, and coexistence
with OpenCode, especially any destination shared by both tools. Add a base MCP
payload only if the client needs one and the clean-project output remains
correct. Release versioning follows the normal release workflow.

Revisit when there is a concrete MiniMax Code user need and enough client
evidence to make the generated files testable. Until then, AgentSync's existing
root `AGENTS.md` output covers the only project file confirmed by the source
README.
