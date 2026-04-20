#!/usr/bin/env bats
# Tests for agentsync check.

load test_helper

setup_file() {
    # Seed with init + enable claude + sync so every test starts from a
    # post-sync project tree. APFS clonefile per test.
    seed_project
    (
        cd "$TEST_SEED"
        AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" enable claude >/dev/null
        AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    )
}
teardown_file() { teardown_seed_project; }
setup() { clone_seed; }
teardown() { teardown_test_project; }

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
