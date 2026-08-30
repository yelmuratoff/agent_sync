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

# ── Project root is not AgentSync's to read ──────────────────────────────────
# A global install makes the project root $HOME, so the root holds directories
# check has no business reading: OS-protected ones (~/Library, ~/Pictures) and
# multi-GB tool caches. Reading the whole root made check unusable there.

# chmod cannot deny root, and Git Bash on Windows ignores permission bits.
require_unreadable_dirs() {
    [[ "$(id -u)" -ne 0 ]] || skip "running as root — chmod cannot deny access"
    [[ "$(uname -s)" != MINGW* && "$(uname -s)" != MSYS* ]] || skip "Windows ignores chmod bits"
}

@test "check ignores an unreadable directory in the project root" {
    require_unreadable_dirs
    mkdir -p protected/inner
    chmod 000 protected

    run run_agentsync check
    chmod 755 protected

    [ "$status" -eq 0 ]
    [[ "$output" == *"synced"* ]]
}

@test "check ignores an unreadable .ai/backups directory" {
    require_unreadable_dirs
    mkdir -p .ai/backups/snapshot
    chmod 000 .ai/backups

    run run_agentsync check
    chmod 755 .ai/backups

    [ "$status" -eq 0 ]
    [[ "$output" == *"synced"* ]]
}

@test "check ignores unrelated root files rather than reporting them as drift" {
    mkdir -p unrelated
    echo "not agentsync's business" > unrelated/notes.txt
    echo "stray" > stray.txt

    run run_agentsync check
    [ "$status" -eq 0 ]
    [[ "$output" != *"stray.txt"* ]]
    [[ "$output" != *"unrelated"* ]]
}
