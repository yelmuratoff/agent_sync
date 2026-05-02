#!/usr/bin/env bats
# Tests for agentsync generate.

load test_helper

setup() {
    setup_test_project
}

teardown() {
    teardown_test_project
}

@test "generate with argument outputs prompt with context" {
    run run_agentsync generate "Flutter app with BLoC"
    [ "$status" -eq 0 ]
    [[ "$output" == *"My Project"* ]]
    [[ "$output" == *"Flutter app with BLoC"* ]]
    [[ "$output" == *"AgentSync"* ]]
}

@test "generate with argument includes instructions" {
    run run_agentsync generate "React project"
    [ "$status" -eq 0 ]
    [[ "$output" == *"AGENTS.md"* ]]
    [[ "$output" == *"rules"* ]]
    [[ "$output" == *"skills"* ]]
}

@test "generate piped outputs raw prompt" {
    output=$(echo "" | run_agentsync generate)
    [[ "$output" == *"AgentSync"* ]]
    [[ "$output" == *".ai/src/"* ]]
}

@test "generate context appears before instructions" {
    run run_agentsync generate "My custom project"
    [ "$status" -eq 0 ]

    # Find line numbers
    local context_line instructions_line
    context_line=$(echo "$output" | grep -n "My custom project" | head -1 | cut -d: -f1)
    instructions_line=$(echo "$output" | grep -n "AgentSync" | head -1 | cut -d: -f1)
    [ "$context_line" -lt "$instructions_line" ]
}

@test "generate multi-word context is preserved" {
    run run_agentsync generate "React + Next.js + Prisma ORM with PostgreSQL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"React + Next.js + Prisma ORM with PostgreSQL"* ]]
}

@test "generate prompt mentions all source types" {
    run run_agentsync generate "test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"AGENTS.md"* ]]
    [[ "$output" == *"rules/"* ]]
    [[ "$output" == *"skills/"* ]]
    [[ "$output" == *"commands/"* ]]
    [[ "$output" == *"agents/"* ]]
    [[ "$output" == *"settings/"* ]]
}

@test "generate prompt uses YAML-safe frontmatter examples" {
    run run_agentsync generate "test"
    [ "$status" -eq 0 ]
    [[ "$output" == *'name: "skill-name"'* ]]
    [[ "$output" == *'name: "agent-name"'* ]]
    [[ "$output" == *"description: >-"* ]]
    [[ "$output" == *"YAML frontmatter must be parseable"* ]]
}
