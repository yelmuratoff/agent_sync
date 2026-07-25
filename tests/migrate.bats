#!/usr/bin/env bats
load test_helper

setup_file() { seed_project --yes --no-detect --content agents,rules; }
teardown_file() { teardown_seed_project; }
setup() {
    clone_seed
    export AGENTSYNC_NO_CLIPBOARD=1
}
teardown() { teardown_test_project; }

@test "migrate outputs a grounded upgrade prompt" {
    sed -i.bak -E 's|^agentsync_version:.*|agentsync_version: "0.7.0"|' .ai/agent_sync.yaml

    run run_agentsync migrate
    [ "$status" -eq 0 ]
    [[ "$output" == *"AgentSync migration context"* ]]
    [[ "$output" == *"Project-pinned AgentSync version: 0.7.0"* ]]
    [[ "$output" == *"CHANGELOG.md"* ]]
    [[ "$output" == *"latest stable AgentSync release"* ]]
    [[ "$output" == *"agentsync doctor"* ]]
    [[ "$output" == *"agentsync check"* ]]
}

@test "migrate copies the full prompt with an available clipboard tool" {
    local mock_bin="$TEST_PROJECT/mock-bin"
    local clipboard_capture="$TEST_PROJECT/clipboard.txt"
    mkdir -p "$mock_bin"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'cat > "$MIGRATE_CLIPBOARD_CAPTURE"' \
        > "$mock_bin/pbcopy"
    chmod +x "$mock_bin/pbcopy"

    run env \
        PATH="$mock_bin:$PATH" \
        AGENTSYNC_NO_CLIPBOARD=0 \
        MIGRATE_CLIPBOARD_CAPTURE="$clipboard_capture" \
        AGENTSYNC_HOME="$REPO_ROOT" \
        bash "$AGENTSYNC_BIN" migrate

    [ "$status" -eq 0 ]
    [ -s "$clipboard_capture" ]
    grep -q "AgentSync migration context" "$clipboard_capture"
    grep -q "latest stable AgentSync release" "$clipboard_capture"
    [[ "$output" == *"Copied migration prompt to clipboard"* ]]
}

@test "migrate uses an explicit fallback when the project version is absent" {
    rm -f .ai/agent_sync.yaml

    run run_agentsync migrate

    [ "$status" -eq 0 ]
    [[ "$output" == *"Project-pinned AgentSync version: not detected"* ]]
}

@test "migrate --legacy reports nothing when layout is already clean" {
    run run_agentsync migrate --legacy
    [ "$status" -eq 0 ]
    [[ "$output" == *"Nothing to migrate"* ]]
}

@test "migrate --legacy dry-run shows planned moves but does not touch files" {
    mkdir -p .ai/src/hooks .ai/src/settings
    echo '{"m":"H"}' > .ai/src/hooks/cursor.json
    echo '{"m":"S"}' > .ai/src/settings/claude.json

    run run_agentsync migrate --legacy
    [ "$status" -eq 0 ]
    [[ "$output" == *"Planned moves"* ]]
    [[ "$output" == *".ai/src/hooks/cursor.json"* ]]
    [[ "$output" == *".ai/src/tools/cursor/hooks.json"* ]]
    [[ "$output" == *"Dry-run"* ]]

    # Files are unchanged.
    [ -f .ai/src/hooks/cursor.json ]
    [ -f .ai/src/settings/claude.json ]
    [ ! -f .ai/src/tools/cursor/hooks.json ]
}

@test "migrate --apply moves hooks and settings to per-tool dirs" {
    mkdir -p .ai/src/hooks .ai/src/settings
    echo '{"m":"H"}' > .ai/src/hooks/cursor.json
    echo '{"m":"S"}' > .ai/src/settings/claude.json

    run run_agentsync migrate --apply
    [ "$status" -eq 0 ]

    [ -f .ai/src/tools/cursor/hooks.json ]
    [ -f .ai/src/tools/claude/settings.json ]
    grep -q '"m":"H"' .ai/src/tools/cursor/hooks.json
    grep -q '"m":"S"' .ai/src/tools/claude/settings.json

    [ ! -f .ai/src/hooks/cursor.json ]
    [ ! -f .ai/src/settings/claude.json ]
    # Empty directories are cleaned up.
    [ ! -d .ai/src/hooks ]
    [ ! -d .ai/src/settings ]
}

@test "migrate --apply consolidates identical MCP files into shared .ai/src/mcp.json" {
    mkdir -p .ai/src/mcp
    echo '{"mcpServers":{"shared":{"command":"x"}}}' > .ai/src/mcp/claude.json
    echo '{"mcpServers":{"shared":{"command":"x"}}}' > .ai/src/mcp/cursor.json

    run run_agentsync migrate --apply --yes
    [ "$status" -eq 0 ]

    [ -f .ai/src/mcp.json ]
    grep -q '"shared"' .ai/src/mcp.json
    [ ! -f .ai/src/mcp/claude.json ]
    [ ! -f .ai/src/mcp/cursor.json ]
    [ ! -d .ai/src/mcp ]
}

@test "migrate --apply migrates MCP per-tool when files differ" {
    mkdir -p .ai/src/mcp
    echo '{"m":"A"}' > .ai/src/mcp/claude.json
    echo '{"m":"B"}' > .ai/src/mcp/cursor.json

    run run_agentsync migrate --apply
    [ "$status" -eq 0 ]

    [ -f .ai/src/tools/claude/mcp.json ]
    [ -f .ai/src/tools/cursor/mcp.json ]
    grep -q '"m":"A"' .ai/src/tools/claude/mcp.json
    grep -q '"m":"B"' .ai/src/tools/cursor/mcp.json
    [ ! -f .ai/src/mcp.json ]
}

@test "migrate --apply skips collisions without overwriting target" {
    mkdir -p .ai/src/hooks .ai/src/tools/cursor
    echo '{"m":"LEGACY"}'   > .ai/src/hooks/cursor.json
    echo '{"m":"EXISTING"}' > .ai/src/tools/cursor/hooks.json

    run run_agentsync migrate --apply
    [ "$status" -eq 0 ]

    # Target is preserved, legacy stays in place with a warning.
    grep -q '"m":"EXISTING"' .ai/src/tools/cursor/hooks.json
    [ -f .ai/src/hooks/cursor.json ]
    [[ "$output" == *"skipped"* ]]
}

@test "doctor hint points at migrate --apply when legacy files exist" {
    mkdir -p .ai/src/hooks
    echo '{}' > .ai/src/hooks/cursor.json

    run run_agentsync doctor
    [[ "$output" == *"agentsync migrate --apply"* ]]
}

@test "migrate rejects unknown flag" {
    run run_agentsync migrate --bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown flag"* ]]
}

@test "migrate --help prints usage" {
    run run_agentsync migrate --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"latest documented format"* ]]
    [[ "$output" == *"--legacy"* ]]
    [[ "$output" == *"--apply"* ]]
}

@test "migrate --legacy --help documents the legacy route" {
    run run_agentsync migrate --legacy --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"agentsync migrate --legacy"* ]]
    [[ "$output" == *"Moves legacy flat-layout"* ]]
}

# ── Legacy pre-v0.6 .agent/ (singular) directory removal ──────────────────────

@test "migrate --legacy dry-run lists legacy .agent/ contents" {
    mkdir -p .agent/rules .agent/skills
    echo "legacy AGENTS" > .agent/AGENTS.md
    run run_agentsync migrate --legacy
    [ "$status" -eq 0 ]
    [[ "$output" == *"Legacy pre-v0.6"* ]]
    [[ "$output" == *".agent/"* ]]
    [[ "$output" == *"AGENTS.md"* ]]
    # Dry-run: directory still present.
    [ -d ".agent" ]
}

@test "migrate --apply --yes removes legacy .agent/ directory" {
    mkdir -p .agent/rules
    echo "legacy" > .agent/AGENTS.md
    run run_agentsync migrate --apply --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"removed .agent/"* ]]
    [ ! -d ".agent" ]
}

@test "migrate --apply (no --yes) without TTY leaves .agent/ in place" {
    mkdir -p .agent
    echo "legacy" > .agent/AGENTS.md
    # bats is not a TTY by default; --apply alone should not auto-remove.
    run run_agentsync migrate --apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"non-interactive"* ]]
    [ -d ".agent" ]
}

@test "migrate flags .agent/ even when antigravity is enabled" {
    # Antigravity moved its output to `.agents/` (plural). `.agent/` is now
    # purely the pre-v0.6 layout regardless of which tools are enabled.
    enable_tools antigravity
    mkdir -p .agent/rules
    echo "stale" > .agent/AGENTS.md

    run run_agentsync migrate --legacy
    [ "$status" -eq 0 ]
    [[ "$output" == *"Legacy pre-v0.6"* ]]

    run run_agentsync migrate --apply --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"removed .agent/"* ]]
    [ ! -d ".agent" ]
}

@test "migrate detects .agent/ even alongside flat-layout overrides" {
    mkdir -p .agent .ai/src/hooks
    echo "legacy" > .agent/AGENTS.md
    echo '{}' > .ai/src/hooks/cursor.json
    run run_agentsync migrate --legacy
    [ "$status" -eq 0 ]
    [[ "$output" == *"Legacy pre-v0.6"* ]]
    [[ "$output" == *"Planned moves"* ]]
}
