#!/usr/bin/env bats
# Tests for agentsync enable / disable.

load test_helper

setup_file() { seed_project; }
teardown_file() { teardown_seed_project; }
setup() { clone_seed; }
teardown() { teardown_test_project; }

@test "enable adds tool to tools.enabled" {
    run run_agentsync enable claude
    [ "$status" -eq 0 ]
    [[ "$output" == *"Enabled 1 tool(s)"* ]]
    grep -q "^    - claude$" .ai/agent_sync.yaml
}

@test "enable multiple tools at once" {
    run run_agentsync enable claude cursor
    [ "$status" -eq 0 ]
    grep -q "^    - claude$" .ai/agent_sync.yaml
    grep -q "^    - cursor$" .ai/agent_sync.yaml
}

@test "enable is idempotent (no duplicates)" {
    run_agentsync enable claude >/dev/null
    run_agentsync enable claude >/dev/null
    local count
    count=$(grep -c "^    - claude$" .ai/agent_sync.yaml)
    [ "$count" -eq 1 ]
}

@test "enable unknown tool shows warning" {
    run run_agentsync enable bogus_tool_xyz
    [[ "$output" == *"Unknown tool"* ]]
}

@test "disable removes tool from tools.enabled" {
    run_agentsync enable claude cursor >/dev/null
    run run_agentsync disable claude
    [ "$status" -eq 0 ]
    ! grep -q "^    - claude$" .ai/agent_sync.yaml
    grep -q "^    - cursor$" .ai/agent_sync.yaml
}

@test "disable unknown tool is a no-op" {
    run run_agentsync disable claude
    [ "$status" -eq 0 ]
    [[ "$output" == *"No matching tools"* ]]
}

@test "enable with no args fails with usage" {
    run run_agentsync enable
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
}

@test "enable scaffolds per-tool payload dir by default (non-TTY)" {
    run run_agentsync enable claude
    [ "$status" -eq 0 ]
    [ -f .ai/src/tools/claude/settings.json ]
    [[ "$output" == *"Edit settings:"* ]]
    [[ "$output" == *".ai/src/tools/claude/settings.json"* ]]
    [[ "$output" == *"Edit MCP:"* ]]
    [[ "$output" == *".ai/src/mcp.json"* ]]
}

@test "enable --no-scaffold skips per-tool dir but still prints hints" {
    run run_agentsync enable claude --no-scaffold
    [ "$status" -eq 0 ]
    [ ! -d .ai/src/tools/claude ]
    [[ "$output" != *"Edit settings:"* ]]
    [[ "$output" == *"agentsync customize claude settings"* ]]
}

@test "enable is idempotent for scaffolded files" {
    run_agentsync enable claude >/dev/null
    echo '{"custom": true}' > .ai/src/tools/claude/settings.json
    run_agentsync disable claude >/dev/null
    run run_agentsync enable claude
    [ "$status" -eq 0 ]
    grep -q '"custom": true' .ai/src/tools/claude/settings.json
}

@test "enable scaffolds hooks when tool has hooks base" {
    run run_agentsync enable windsurf
    [ "$status" -eq 0 ]
    [ -f .ai/src/tools/windsurf/hooks.json ]
    [[ "$output" == *"Edit hooks:"* ]]
}

@test "enable respects legacy flat-layout overrides (no shadow)" {
    mkdir -p .ai/src/settings
    echo '{"legacy": true}' > .ai/src/settings/claude.json
    run run_agentsync enable claude
    [ "$status" -eq 0 ]
    [ ! -f .ai/src/tools/claude/settings.json ]
    grep -q '"legacy": true' .ai/src/settings/claude.json
}
