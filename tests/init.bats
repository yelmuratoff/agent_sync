#!/usr/bin/env bats
# Tests for agentsync init.

load test_helper

setup() {
    setup_test_project
}

teardown() {
    teardown_test_project
}

@test "init creates .ai/src content directories" {
    run run_agentsync init
    [ "$status" -eq 0 ]

    [ -f ".ai/src/AGENTS.md" ]
    [ -d ".ai/src/rules" ]
    [ -d ".ai/src/skills" ]
    [ -d ".ai/src/commands" ]
    [ -d ".ai/src/agents" ]
    # tools/ is created on demand by `customize`.
    [ ! -d ".ai/src/tools" ]
    # Payload dirs (settings/mcp/hooks) are lazy — created only when a tool
    # is enabled (auto-detect or --tools). Empty project = no payload dirs.
    [ ! -d ".ai/src/settings" ]
    [ ! -d ".ai/src/mcp" ]
    [ ! -d ".ai/src/hooks" ]
}

@test "init --tools claude scaffolds only claude payloads" {
    run run_agentsync init --tools claude
    [ "$status" -eq 0 ]

    # Claude has settings + hooks (none) templates; MCP is excluded in 0.11+
    # because it resolves via shared .ai/src/mcp.json (or base).
    [ -f ".ai/src/settings/claude.json" ]
    [ ! -d ".ai/src/mcp" ]
    [ ! -d ".ai/src/hooks" ]
    # No cursor leakage.
    [ ! -f ".ai/src/settings/cursor.json" ]
}

@test "init --content agents,rules skips skills/commands/agents" {
    run run_agentsync init --content agents,rules
    [ "$status" -eq 0 ]

    [ -f ".ai/src/AGENTS.md" ]
    [ -d ".ai/src/rules" ]
    [ ! -d ".ai/src/skills" ]
    [ ! -d ".ai/src/commands" ]
    [ ! -d ".ai/src/agents" ]
}

@test "init --no-detect ignores existing tool markers" {
    mkdir -p .claude
    run run_agentsync init --no-detect
    [ "$status" -eq 0 ]

    grep -q "enabled: \[\]" ".ai/agent_sync.yaml"
    [ ! -d ".ai/src/settings" ]
}

@test "init --tools union with auto-detect" {
    mkdir -p .cursor
    run run_agentsync init --tools claude
    [ "$status" -eq 0 ]

    grep -q "^    - claude$" ".ai/agent_sync.yaml"
    grep -q "^    - cursor$" ".ai/agent_sync.yaml"
}

@test "init rejects unknown --content token" {
    run run_agentsync init --content bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown --content section"* ]]
}

@test "init creates starter rules" {
    run run_agentsync init
    [ "$status" -eq 0 ]

    local rule_count
    rule_count=$(ls -1 .ai/src/rules/*.md 2>/dev/null | wc -l | tr -d ' ')
    [ "$rule_count" -ge 1 ]
}

@test "init creates agent_sync.yaml with tools.enabled list" {
    run run_agentsync init
    [ "$status" -eq 0 ]

    [ -f ".ai/agent_sync.yaml" ]
    grep -q "^tools:" ".ai/agent_sync.yaml"
    grep -q "enabled:" ".ai/agent_sync.yaml"
}

@test "init creates skills" {
    run run_agentsync init
    [ "$status" -eq 0 ]

    local skill_count
    skill_count=$(find .ai/src/skills -name "SKILL.md" 2>/dev/null | wc -l | tr -d ' ')
    [ "$skill_count" -ge 1 ]
}

@test "init creates commands" {
    run run_agentsync init
    [ "$status" -eq 0 ]

    local cmd_count
    cmd_count=$(ls -1 .ai/src/commands/*.md 2>/dev/null | wc -l | tr -d ' ')
    [ "$cmd_count" -ge 1 ]
}

@test "init creates agents" {
    run run_agentsync init
    [ "$status" -eq 0 ]

    local agent_count
    agent_count=$(ls -1 .ai/src/agents/*.md 2>/dev/null | wc -l | tr -d ' ')
    [ "$agent_count" -ge 1 ]
}

@test "init skips if .ai/src already exists" {
    run run_agentsync init
    [ "$status" -eq 0 ]

    # Second run should skip
    run run_agentsync init
    [ "$status" -eq 0 ]
    [[ "$output" == *"already exists"* ]]
}

@test "init output mentions enable command" {
    run run_agentsync init
    [ "$status" -eq 0 ]
    [[ "$output" == *"agentsync enable"* ]]
}

@test "init Next steps lists MCP and customize hints" {
    run run_agentsync init --no-detect
    [ "$status" -eq 0 ]
    [[ "$output" == *"agentsync add mcp"* ]]
    [[ "$output" == *"agentsync customize"* ]]
}

@test "init to custom directory" {
    mkdir -p subdir
    run run_agentsync init subdir
    [ "$status" -eq 0 ]
    [ -f "subdir/.ai/src/AGENTS.md" ]
}

@test "init does not copy system engine into project" {
    run run_agentsync init
    [ "$status" -eq 0 ]
    [ ! -d ".ai/system" ]
}

@test "init AGENTS.md is valid markdown" {
    run run_agentsync init
    [ "$status" -eq 0 ]

    # Should start with a heading
    local first_line
    first_line=$(head -1 .ai/src/AGENTS.md)
    [[ "$first_line" == "#"* ]]
}

@test "init with empty project enables no tools by default" {
    run run_agentsync init
    [ "$status" -eq 0 ]

    # Empty project has no markers → tools.enabled is [].
    grep -q "enabled: \[\]" ".ai/agent_sync.yaml"
}

@test "init auto-detects existing tool markers" {
    mkdir -p .claude
    mkdir -p .cursor
    run run_agentsync init
    [ "$status" -eq 0 ]

    # Both detected tools should appear under tools.enabled.
    grep -q "^    - claude$" ".ai/agent_sync.yaml"
    grep -q "^    - cursor$" ".ai/agent_sync.yaml"
}

# ── Phase 4: interactive init, --yes, --dry-run ─────────────────────────────

@test "init --dry-run shows plan without writing" {
    run run_agentsync init --dry-run --tools claude,cursor
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dry run"* ]]
    [[ "$output" == *"Plan:"* ]]
    [[ "$output" == *"claude"* ]]
    [[ "$output" == *"cursor"* ]]

    [ ! -d ".ai" ]
    [ ! -f ".ai/agent_sync.yaml" ]
}

@test "init --dry-run --content filters in plan" {
    run run_agentsync init --dry-run --content agents,rules
    [ "$status" -eq 0 ]
    [[ "$output" == *"agents, rules"* ]]
    [ ! -d ".ai" ]
}

@test "init --yes in non-TTY behaves like defaults" {
    # --yes is a no-op here (no prompts run in non-TTY), but must not error.
    run run_agentsync init --yes --no-detect
    [ "$status" -eq 0 ]
    [ -f ".ai/agent_sync.yaml" ]
    [ -f ".ai/src/AGENTS.md" ]
}

@test "init non-TTY without flags runs silently with defaults" {
    # No flags, no TTY → fall through to defaults; must NOT hang on prompts.
    run run_agentsync init
    [ "$status" -eq 0 ]
    [ -f ".ai/agent_sync.yaml" ]
}

@test "init --help documents --yes and --dry-run" {
    run run_agentsync init --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--yes"* ]]
    [[ "$output" == *"--dry-run"* ]]
}
