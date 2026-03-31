#!/usr/bin/env bats
# Tests for agentsync list.

load test_helper

setup() {
    setup_test_project
    run_agentsync init
}

teardown() {
    teardown_test_project
}

@test "list shows tools" {
    run run_agentsync list
    [ "$status" -eq 0 ]
    [[ "$output" == *"AgentSync Tools"* ]]
}

@test "list shows enabled tools with green dot" {
    run run_agentsync list
    [ "$status" -eq 0 ]
    [[ "$output" == *"Claude Code"* ]]
    [[ "$output" == *"Cursor"* ]]
}

@test "list shows disabled tools" {
    run run_agentsync list
    [ "$status" -eq 0 ]
    [[ "$output" == *"disabled"* ]]
}

@test "list shows tool count" {
    run run_agentsync list
    [ "$status" -eq 0 ]
    [[ "$output" == *"tool(s) configured"* ]]
}

@test "list alias ls works" {
    run run_agentsync ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"AgentSync Tools"* ]]
}

@test "list fails without .ai/src/tools" {
    rm -rf .ai
    run run_agentsync list
    [ "$status" -eq 1 ]
    [[ "$output" == *"No tools directory"* ]]
}
