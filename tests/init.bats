#!/usr/bin/env bats
# Tests for agentsync init.

load test_helper

setup() {
    setup_test_project
}

teardown() {
    teardown_test_project
}

@test "init creates .ai/src structure" {
    run run_agentsync init
    [ "$status" -eq 0 ]

    [ -f ".ai/src/AGENTS.md" ]
    [ -d ".ai/src/rules" ]
    [ -d ".ai/src/skills" ]
    [ -d ".ai/src/commands" ]
    [ -d ".ai/src/agents" ]
    [ -d ".ai/src/settings" ]
    [ -d ".ai/src/mcp" ]
    [ -d ".ai/src/hooks" ]
    [ -d ".ai/src/tools" ]
}

@test "init creates starter rules" {
    run run_agentsync init
    [ "$status" -eq 0 ]

    local rule_count
    rule_count=$(ls -1 .ai/src/rules/*.md 2>/dev/null | wc -l | tr -d ' ')
    [ "$rule_count" -ge 1 ]
}

@test "init creates tool configs" {
    run run_agentsync init
    [ "$status" -eq 0 ]

    [ -f ".ai/src/tools/claude.yaml" ]
    [ -f ".ai/src/tools/cursor.yaml" ]
    [ -f ".ai/src/tools/copilot.yaml" ]
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

@test "init prompts user to enable tools" {
    run run_agentsync init
    [ "$status" -eq 0 ]
    [[ "$output" == *"Enable tools"* ]]
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

@test "init tool configs have enabled field" {
    run run_agentsync init
    [ "$status" -eq 0 ]

    for f in .ai/src/tools/*.yaml; do
        [[ "$(basename "$f")" == _* ]] && continue
        grep -q "^enabled:" "$f"
    done
}

@test "init default enabled tools are correct" {
    run run_agentsync init
    [ "$status" -eq 0 ]

    # All tools default to disabled — users opt in explicitly per project.
    for f in .ai/src/tools/*.yaml; do
        [[ "$(basename "$f")" == _* ]] && continue
        grep -q "^enabled: false" "$f"
    done
}
