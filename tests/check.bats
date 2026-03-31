#!/usr/bin/env bats
# Tests for agentsync check.

load test_helper

setup() {
    setup_test_project
    run_agentsync init
}

teardown() {
    teardown_test_project
}

@test "check passes after sync" {
    run run_agentsync sync
    [ "$status" -eq 0 ]

    run run_agentsync check
    [ "$status" -eq 0 ]
    [[ "$output" == *"synced"* ]]
}

@test "check fails when out of sync" {
    run run_agentsync sync
    [ "$status" -eq 0 ]

    # Modify a generated file
    echo "modified" >> .claude/CLAUDE.md

    run run_agentsync check
    [ "$status" -eq 1 ]
    [[ "$output" == *"out of sync"* ]]
}

@test "check fails when generated file is missing" {
    run run_agentsync sync
    [ "$status" -eq 0 ]

    # Remove a generated file
    rm -f .claude/CLAUDE.md

    run run_agentsync check
    [ "$status" -eq 1 ]
}

@test "check detects rule changes" {
    run run_agentsync sync
    [ "$status" -eq 0 ]

    # Modify source rule
    echo "# New rule" >> .ai/src/rules/core.md

    run run_agentsync check
    [ "$status" -eq 1 ]
}
