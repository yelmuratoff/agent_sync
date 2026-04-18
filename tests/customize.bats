#!/usr/bin/env bats
# Tests for agentsync customize / show / diff.

load test_helper

setup() {
    setup_test_project
    run_agentsync init >/dev/null
}

teardown() {
    teardown_test_project
}

@test "customize creates empty override stub" {
    run run_agentsync customize claude
    [ "$status" -eq 0 ]
    [ -f ".ai/src/tools/claude.yaml" ]
}

@test "customize stub mentions show --base" {
    run_agentsync customize claude >/dev/null
    grep -q "agentsync show claude --base" .ai/src/tools/claude.yaml
}

@test "customize --full copies entire base" {
    run run_agentsync customize cursor --full
    [ "$status" -eq 0 ]
    [ -f ".ai/src/tools/cursor.yaml" ]
    # Full copy should have name field from base
    grep -q "^name:" .ai/src/tools/cursor.yaml
}

@test "customize is idempotent (warns if exists)" {
    run_agentsync customize claude >/dev/null
    run run_agentsync customize claude
    [[ "$output" == *"Override already exists"* ]]
}

@test "customize unknown tool with --full fails" {
    run run_agentsync customize bogus_tool_xyz --full
    [ "$status" -ne 0 ]
    [[ "$output" == *"No base template"* ]]
}

@test "show displays effective config" {
    run_agentsync enable claude >/dev/null
    run run_agentsync show claude
    [ "$status" -eq 0 ]
    [[ "$output" == *"Claude Code"* ]]
    [[ "$output" == *"base"* ]]
}

@test "show --base prints the base YAML" {
    run run_agentsync show claude --base
    [ "$status" -eq 0 ]
    [[ "$output" == *"Base template"* ]]
}

@test "show marks user overrides with star" {
    run_agentsync customize claude --full >/dev/null
    run run_agentsync show claude
    [ "$status" -eq 0 ]
    [[ "$output" == *"user"* ]]
}

@test "diff with no overrides shows message" {
    run run_agentsync diff
    [ "$status" -eq 0 ]
    [[ "$output" == *"No user overrides"* ]]
}

@test "diff lists tools with overrides" {
    run_agentsync customize claude --full >/dev/null
    run run_agentsync diff
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude"* ]]
}
