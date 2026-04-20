#!/usr/bin/env bats
# Tests for agentsync list.

load test_helper

setup_file() { seed_project; }
teardown_file() { teardown_seed_project; }
setup() { clone_seed; }
teardown() { teardown_test_project; }

@test "list shows tools header" {
    run run_agentsync list
    [ "$status" -eq 0 ]
    [[ "$output" == *"AgentSync Tools"* ]]
}

@test "list shows base tools from catalog" {
    run run_agentsync list
    [ "$status" -eq 0 ]
    [[ "$output" == *"Claude Code"* ]]
    [[ "$output" == *"Cursor"* ]]
}

@test "list shows available for unenabled tools" {
    run run_agentsync list
    [ "$status" -eq 0 ]
    [[ "$output" == *"available"* ]]
}

@test "list reports enabled tool count" {
    run run_agentsync list
    [ "$status" -eq 0 ]
    [[ "$output" == *"enabled"* ]]
}

@test "list alias ls works" {
    run run_agentsync ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"AgentSync Tools"* ]]
}

@test "list works even without .ai directory (uses base catalog)" {
    rm -rf .ai
    run run_agentsync list
    [ "$status" -eq 0 ]
    [[ "$output" == *"AgentSync Tools"* ]]
}

@test "list shows enabled marker after enable" {
    run_agentsync enable claude
    run run_agentsync list
    [ "$status" -eq 0 ]
    [[ "$output" == *"enabled"* ]]
}
