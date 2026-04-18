#!/usr/bin/env bats
# Tests for agentsync doctor.

load test_helper

setup() {
    setup_test_project
}

teardown() {
    teardown_test_project
}

@test "doctor fails with exit 2 when .ai/ missing" {
    run run_agentsync doctor
    [ "$status" -eq 2 ]
    [[ "$output" == *".ai/ directory missing"* ]]
}

@test "doctor passes on fresh init" {
    run_agentsync init >/dev/null
    run run_agentsync doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"All checks passed"* ]]
}

@test "doctor reports enabled tools" {
    run_agentsync init >/dev/null
    run_agentsync enable claude >/dev/null
    run run_agentsync doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"Claude Code"* ]]
}

@test "doctor shows customization marker" {
    run_agentsync init >/dev/null
    run_agentsync enable claude >/dev/null
    run_agentsync customize claude >/dev/null
    run run_agentsync doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"customized"* ]]
}

@test "doctor flags legacy enabled: true" {
    run_agentsync init >/dev/null
    mkdir -p .ai/src/tools
    cat > .ai/src/tools/claude.yaml <<'YAML'
enabled: true
YAML
    run run_agentsync doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"legacy"* ]]
}

@test "doctor reports source directories" {
    run_agentsync init >/dev/null
    run run_agentsync doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *".ai/src/AGENTS.md"* ]]
    [[ "$output" == *".ai/src/rules"* ]]
}
