#!/usr/bin/env bats
# Tests for agentsync check.

load test_helper

setup() {
    setup_test_project
    run_agentsync init
    enable_tools claude
    run_agentsync sync
}

teardown() {
    teardown_test_project
}

@test "check passes after sync" {
    run run_agentsync check
    [ "$status" -eq 0 ]
    [[ "$output" == *"synced"* ]]
}

@test "check fails when generated file is modified" {
    echo "modified" >> CLAUDE.md
    run run_agentsync check
    [ "$status" -eq 1 ]
    [[ "$output" == *"out of sync"* ]]
}

@test "check fails when generated file is missing" {
    rm -f CLAUDE.md
    run run_agentsync check
    [ "$status" -eq 1 ]
}

@test "check detects source rule changes" {
    echo "# New rule" >> .ai/src/rules/core.md
    run run_agentsync check
    [ "$status" -eq 1 ]
}
