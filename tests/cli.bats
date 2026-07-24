#!/usr/bin/env bats
# Tests for CLI basics: help, version, unknown commands.

load test_helper

@test "help shows usage" {
    run run_agentsync help
    [ "$status" -eq 0 ]
    [[ "$output" == *"AgentSync"* ]]
    [[ "$output" == *"COMMANDS"* ]]
    [[ "$output" == *"init"* ]]
    [[ "$output" == *"sync"* ]]
    [[ "$output" == *"rollback"* ]]
}

@test "--help shows usage" {
    run run_agentsync --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"COMMANDS"* ]]
}

@test "version prints version" {
    run run_agentsync version
    [ "$status" -eq 0 ]
    [[ "$output" == agentsync\ v* ]]
}

@test "--version prints version" {
    run run_agentsync --version
    [ "$status" -eq 0 ]
    [[ "$output" == agentsync\ v* ]]
}

@test "-v prints version" {
    run run_agentsync -v
    [ "$status" -eq 0 ]
    [[ "$output" == agentsync\ v* ]]
}

@test "unknown command fails with error" {
    run run_agentsync nonexistent
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown command"* ]]
}

@test "no arguments shows help" {
    run run_agentsync
    [ "$status" -eq 0 ]
    [[ "$output" == *"COMMANDS"* ]]
}

@test "rollback --help documents safe restore options" {
    run run_agentsync rollback --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--list"* ]]
    [[ "$output" == *"--dry-run"* ]]
    [[ "$output" == *"--yes"* ]]
}
