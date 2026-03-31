#!/usr/bin/env bats
# Tests for sync filtering, dry-run, disable/enable, idempotency.
# Each group uses setup_file for shared state where possible.

load test_helper

# ── --only / --skip / --dry-run ──────────────────────────────────────────────

@test "sync --only filters to single tool" {
    setup_test_project
    run_agentsync init
    run run_agentsync sync --only claude
    [ "$status" -eq 0 ]
    [ -f ".claude/CLAUDE.md" ]
    [ ! -f ".cursor/AGENTS.md" ]
    teardown_test_project
}

@test "sync --skip excludes a tool" {
    setup_test_project
    run_agentsync init
    run run_agentsync sync --skip claude
    [ "$status" -eq 0 ]
    [ ! -f ".claude/CLAUDE.md" ]
    [ -f ".cursor/AGENTS.md" ]
    teardown_test_project
}

@test "sync --only multiple tools" {
    setup_test_project
    run_agentsync init
    run run_agentsync sync --only claude,cursor
    [ "$status" -eq 0 ]
    [ -f ".claude/CLAUDE.md" ]
    [ -f ".cursor/AGENTS.md" ]
    [ ! -f ".github/copilot-instructions.md" ]
    teardown_test_project
}

@test "sync --dry-run does not create files" {
    setup_test_project
    run_agentsync init
    run run_agentsync sync --dry-run
    [ "$status" -eq 0 ]
    [ ! -f ".claude/CLAUDE.md" ]
    [[ "$output" == *"dry-run"* ]]
    teardown_test_project
}

@test "sync skips disabled tools" {
    setup_test_project
    run_agentsync init
    sed -i.bak 's/^enabled: true$/enabled: false/' .ai/src/tools/claude.yaml
    run run_agentsync sync --only claude
    [ "$status" -eq 0 ]
    [ ! -f ".claude/CLAUDE.md" ]
    teardown_test_project
}

@test "sync cleans up when tool is disabled" {
    setup_test_project
    run_agentsync init
    run_agentsync sync --only claude
    [ -f ".claude/CLAUDE.md" ]
    sed -i.bak 's/^enabled: true$/enabled: false/' .ai/src/tools/claude.yaml
    run run_agentsync sync --only claude
    [ "$status" -eq 0 ]
    [ ! -f ".claude/CLAUDE.md" ]
    teardown_test_project
}

@test "sync copies settings.json for Claude" {
    setup_test_project
    run_agentsync init
    mkdir -p .ai/src/settings
    echo '{"permissions":{"allow":["Read"]}}' > .ai/src/settings/claude.json
    run run_agentsync sync --only claude
    [ "$status" -eq 0 ]
    [ -f ".claude/settings.json" ]
    grep -q "permissions" .claude/settings.json
    teardown_test_project
}

@test "sync is idempotent" {
    setup_test_project
    run_agentsync init
    run_agentsync sync --only claude
    local hash1
    hash1=$(find .claude -type f -exec md5sum {} \; 2>/dev/null | sort || \
            find .claude -type f -exec md5 {} \; 2>/dev/null | sort)
    run_agentsync sync --only claude
    local hash2
    hash2=$(find .claude -type f -exec md5sum {} \; 2>/dev/null | sort || \
            find .claude -type f -exec md5 {} \; 2>/dev/null | sort)
    [ "$hash1" = "$hash2" ]
    teardown_test_project
}
