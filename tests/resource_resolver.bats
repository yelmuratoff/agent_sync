#!/usr/bin/env bats
# Tests for resolve_payload_source — hooks/mcp/settings resolution order:
#   1. Project override at .ai/src/<resource>/<tool>.<ext>
#   2. Fallback to <install-dir>/lib/templates/<resource>/<tool>.<ext>
#   3. Nothing found → sync skips silently.

load test_helper

setup() {
    setup_test_project
}

teardown() {
    teardown_test_project
}

@test "sync falls back to base template when override is absent" {
    run_agentsync init --no-detect >/dev/null
    enable_tools cursor

    # No .ai/src/hooks/cursor.json override exists.
    [ ! -f ".ai/src/hooks/cursor.json" ]

    run run_agentsync sync
    [ "$status" -eq 0 ]

    # Base template was used — destination file appears.
    [ -f ".cursor/hooks.json" ]
    [ -f ".cursor/mcp.json" ]
}

@test "project override wins over base template" {
    run_agentsync init --no-detect >/dev/null
    enable_tools cursor

    mkdir -p .ai/src/hooks
    echo '{"marker":"USER_OVERRIDE"}' > .ai/src/hooks/cursor.json

    run run_agentsync sync
    [ "$status" -eq 0 ]

    grep -q "USER_OVERRIDE" .cursor/hooks.json
}

@test "no override and no base template → sync skips silently" {
    run_agentsync init --no-detect >/dev/null
    # Claude has no hooks template — neither override nor base for hooks.
    enable_tools claude

    run run_agentsync sync
    [ "$status" -eq 0 ]

    # Claude's settings and .mcp.json come from base — should exist.
    [ -f ".claude/settings.json" ]
    [ -f ".mcp.json" ]
    # But no hooks dest is declared for Claude; nothing to create.
    [ ! -f ".claude/hooks.json" ]
}

@test "base fallback works for settings across template types (json/toml)" {
    run_agentsync init --no-detect >/dev/null
    enable_tools gemini codex

    run run_agentsync sync
    [ "$status" -eq 0 ]

    [ -f ".gemini/settings.json" ]         # json base
    [ -f ".codex/config.toml" ]            # toml base
}

@test "removing an override after sync restores base on next sync" {
    run_agentsync init --no-detect >/dev/null
    enable_tools cursor

    mkdir -p .ai/src/hooks
    echo '{"marker":"USER_OVERRIDE"}' > .ai/src/hooks/cursor.json
    run_agentsync sync >/dev/null
    grep -q "USER_OVERRIDE" .cursor/hooks.json

    rm .ai/src/hooks/cursor.json
    run run_agentsync sync
    [ "$status" -eq 0 ]

    # Base content replaced the override.
    [ -f ".cursor/hooks.json" ]
    ! grep -q "USER_OVERRIDE" .cursor/hooks.json
}

# ── Phase 7: per-tool override directory ────────────────────────────────────

@test "new per-tool-dir override is used by sync" {
    run_agentsync init --no-detect >/dev/null
    enable_tools cursor

    mkdir -p .ai/src/tools/cursor
    echo '{"marker":"PER_TOOL_DIR"}' > .ai/src/tools/cursor/hooks.json

    run run_agentsync sync
    [ "$status" -eq 0 ]

    grep -q "PER_TOOL_DIR" .cursor/hooks.json
}

@test "new layout wins over legacy flat layout when both exist" {
    run_agentsync init --no-detect >/dev/null
    enable_tools cursor

    mkdir -p .ai/src/hooks .ai/src/tools/cursor
    echo '{"marker":"LEGACY"}'   > .ai/src/hooks/cursor.json
    echo '{"marker":"CANONICAL"}' > .ai/src/tools/cursor/hooks.json

    run run_agentsync sync
    [ "$status" -eq 0 ]

    grep -q "CANONICAL" .cursor/hooks.json
    ! grep -q "LEGACY" .cursor/hooks.json
}

@test "legacy flat override emits deprecation warning" {
    run_agentsync init --no-detect >/dev/null
    enable_tools cursor

    mkdir -p .ai/src/hooks
    echo '{"marker":"LEGACY"}' > .ai/src/hooks/cursor.json

    # Warning is on stderr — `run` captures combined stdout+stderr by default.
    run run_agentsync sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"Legacy payload override layout"* ]]

    # But the override still takes effect.
    grep -q "LEGACY" .cursor/hooks.json
}

# ── Phase 8: shared MCP (.ai/src/mcp.json) ──────────────────────────────────

@test "shared .ai/src/mcp.json propagates to every enabled tool" {
    run_agentsync init --no-detect >/dev/null
    enable_tools claude cursor

    mkdir -p .ai/src
    echo '{"mcpServers":{"shared":{"command":"shared-mcp"}}}' > .ai/src/mcp.json

    run run_agentsync sync
    [ "$status" -eq 0 ]

    # Claude's dest is repo-root .mcp.json; Cursor's is .cursor/mcp.json.
    grep -q "shared-mcp" .mcp.json
    grep -q "shared-mcp" .cursor/mcp.json
}

@test "per-tool MCP override wins over shared source" {
    run_agentsync init --no-detect >/dev/null
    enable_tools claude cursor

    mkdir -p .ai/src .ai/src/tools/cursor
    echo '{"mcpServers":{"shared":{"command":"shared-mcp"}}}' > .ai/src/mcp.json
    echo '{"mcpServers":{"cursor_only":{"command":"cursor-mcp"}}}' > .ai/src/tools/cursor/mcp.json

    run run_agentsync sync
    [ "$status" -eq 0 ]

    # Cursor takes the override; claude keeps the shared source.
    grep -q "cursor_only" .cursor/mcp.json
    ! grep -q "shared-mcp" .cursor/mcp.json
    grep -q "shared-mcp" .mcp.json
}

@test "legacy flat MCP override wins over shared source" {
    run_agentsync init --no-detect >/dev/null
    enable_tools claude cursor

    mkdir -p .ai/src .ai/src/mcp
    echo '{"mcpServers":{"shared":{"command":"shared-mcp"}}}' > .ai/src/mcp.json
    echo '{"mcpServers":{"legacy":{"command":"legacy-mcp"}}}' > .ai/src/mcp/cursor.json

    run run_agentsync sync
    [ "$status" -eq 0 ]

    grep -q "legacy-mcp" .cursor/mcp.json
    grep -q "shared-mcp" .mcp.json
}

@test "sync emits source label line for MCP" {
    run_agentsync init --no-detect >/dev/null
    enable_tools cursor

    mkdir -p .ai/src
    echo '{"mcpServers":{}}' > .ai/src/mcp.json

    run run_agentsync sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"mcp source: shared"* ]]
}

@test "sync MCP label is 'base' when nothing overrides" {
    run_agentsync init --no-detect >/dev/null
    enable_tools cursor

    [ ! -f ".ai/src/mcp.json" ]

    run run_agentsync sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"mcp source: base"* ]]
}
