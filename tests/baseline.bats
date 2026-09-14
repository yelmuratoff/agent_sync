#!/usr/bin/env bats
# First sync in a project that already has its own tool config: the run says
# what it is replacing, keeps a restorable snapshot, and `adopt` works before
# any manifest exists so the existing content can be kept instead.

load test_helper

setup() {
    setup_test_project
    run_agentsync init --tools claude --yes --no-sync >/dev/null 2>&1
}

teardown() {
    teardown_test_project
}

@test "baseline: a pre-existing CLAUDE.md is reported before being replaced" {
    printf '# Hand-written rules\n' > CLAUDE.md
    run run_agentsync sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"already exist"* ]]
    [[ "$output" == *"CLAUDE.md"* ]]
}

@test "baseline: the warning names adopt and rollback" {
    printf '# Hand-written rules\n' > CLAUDE.md
    run run_agentsync sync
    [[ "$output" == *"agentsync adopt"* ]]
    [[ "$output" == *"agentsync rollback"* ]]
}

@test "baseline: the replaced content is restorable from the snapshot" {
    printf '# Hand-written rules\n' > CLAUDE.md
    run_agentsync sync >/dev/null 2>&1
    ! grep -q "Hand-written rules" CLAUDE.md

    run run_agentsync rollback --yes
    [ "$status" -eq 0 ]
    grep -q "Hand-written rules" CLAUDE.md
}

@test "baseline: a file inside a generated directory is reported too" {
    mkdir -p .claude/rules
    printf '# Legacy rule\n' > .claude/rules/legacy.md
    run run_agentsync sync
    [ "$status" -eq 0 ]
    [[ "$output" == *".claude/rules/"* ]]
}

@test "baseline: a path several tools write is counted once" {
    enable_tools cursor codex
    printf '# Hand-written agents\n' > AGENTS.md
    run run_agentsync sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"regenerating 1 path(s) that already exist"* ]]
}

@test "baseline: an empty generated directory is not reported" {
    mkdir -p .claude/rules
    run run_agentsync sync
    [ "$status" -eq 0 ]
    [[ "$output" != *"already exist"* ]]
}

@test "baseline: dry-run reports nothing and writes nothing" {
    printf '# Hand-written rules\n' > CLAUDE.md
    run run_agentsync sync --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" != *"already exist"* ]]
    [ "$(cat CLAUDE.md)" = "# Hand-written rules" ]
}

@test "baseline: adopt before the first sync keeps the content" {
    printf '# Hand-written rules\n' > CLAUDE.md
    run run_agentsync adopt --yes CLAUDE.md
    [ "$status" -eq 0 ]
    grep -q "Hand-written rules" .ai/src/AGENTS.md

    run run_agentsync sync
    [ "$status" -eq 0 ]
    grep -q "Hand-written rules" CLAUDE.md
}

@test "baseline: adopt of a missing destination still fails" {
    run run_agentsync adopt --yes CLAUDE.md
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

@test "baseline: adopt --all still needs a manifest" {
    printf '# Hand-written rules\n' > CLAUDE.md
    run run_agentsync adopt --all --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"manifest"* ]]
}

@test "baseline: a second sync reports nothing" {
    run_agentsync sync >/dev/null 2>&1
    run run_agentsync sync
    [ "$status" -eq 0 ]
    [[ "$output" != *"already exist"* ]]
}
