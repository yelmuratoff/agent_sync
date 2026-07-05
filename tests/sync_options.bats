#!/usr/bin/env bats
# Tests for sync filtering, dry-run, disable/enable, idempotency.
# Shares a single `init`ed project via seed_project/clone_seed — each test then
# layers its own enable/sync on top.

load test_helper

setup_file() { seed_project; }
teardown_file() { teardown_seed_project; }
setup() { clone_seed; }
teardown() { teardown_test_project; }

# ── --only / --skip / --dry-run ──────────────────────────────────────────────

@test "sync --only filters to single tool" {
    enable_tools claude cursor
    run run_agentsync sync --only claude
    [ "$status" -eq 0 ]
    [ -f "CLAUDE.md" ]
    [ ! -f "AGENTS.md" ]
}

@test "sync --skip excludes a tool" {
    enable_tools claude cursor
    run run_agentsync sync --skip claude
    [ "$status" -eq 0 ]
    [ ! -f "CLAUDE.md" ]
    [ -f "AGENTS.md" ]
}

@test "sync --only multiple tools" {
    enable_tools claude cursor copilot
    run run_agentsync sync --only claude,cursor
    [ "$status" -eq 0 ]
    [ -f "CLAUDE.md" ]
    [ -f "AGENTS.md" ]
    [ ! -f ".github/copilot-instructions.md" ]
}

@test "sync --dry-run does not create files" {
    enable_tools claude
    run run_agentsync sync --dry-run
    [ "$status" -eq 0 ]
    [ ! -f "CLAUDE.md" ]
    [[ "$output" == *"dry-run"* ]]
}

@test "sync skips disabled tools" {
    # Claude is disabled by default after init — no need to flip.
    run run_agentsync sync --only claude
    [ "$status" -eq 0 ]
    [ ! -f "CLAUDE.md" ]
}

@test "sync cleans up when tool is disabled" {
    enable_tools claude
    run_agentsync sync --only claude
    [ -f "CLAUDE.md" ]
    run_agentsync disable claude >/dev/null
    run run_agentsync sync --only claude
    [ "$status" -eq 0 ]
    [ ! -f "CLAUDE.md" ]
}

@test "sync copies settings.json for Claude" {
    enable_tools claude
    mkdir -p .ai/src/settings
    echo '{"permissions":{"allow":["Read"]}}' > .ai/src/settings/claude.json
    run run_agentsync sync --only claude
    [ "$status" -eq 0 ]
    [ -f ".claude/settings.json" ]
    grep -q "permissions" .claude/settings.json
}

@test "sync is idempotent" {
    enable_tools claude
    run_agentsync sync --only claude
    local hash1
    hash1=$(find .claude -type f -exec md5sum {} \; 2>/dev/null | sort || \
            find .claude -type f -exec md5 {} \; 2>/dev/null | sort)
    run_agentsync sync --only claude
    local hash2
    hash2=$(find .claude -type f -exec md5sum {} \; 2>/dev/null | sort || \
            find .claude -type f -exec md5 {} \; 2>/dev/null | sort)
    [ "$hash1" = "$hash2" ]
}

# ── post_sync trust boundary ─────────────────────────────────────────────────

@test "sync: in-repo post_sync.allow does NOT enable the hook" {
    enable_tools claude
    mkdir -p .ai/src/tools
    printf 'post_sync: "touch post_sync_ran"\n' >> .ai/src/tools/claude.yaml
    # An in-repo allow must be ignored — cloning a repo can't run its hook.
    printf '\npost_sync:\n  allow: true\n' >> .ai/agent_sync.yaml
    run run_agentsync sync
    [ "$status" -eq 0 ]
    [ ! -f "post_sync_ran" ]
    [[ "$output" == *"Skipping post-sync hook"* ]]
}

@test "sync: out-of-repo env allow runs the post_sync hook" {
    enable_tools claude
    mkdir -p .ai/src/tools
    printf 'post_sync: "touch post_sync_ran"\n' >> .ai/src/tools/claude.yaml
    AGENTSYNC_ALLOW_POST_SYNC=true run run_agentsync sync
    [ "$status" -eq 0 ]
    [ -f "post_sync_ran" ]
}

# ── A misconfigured per-tool source must not abort the whole run ──────────────

@test "sync: bad per-tool source is skipped; run completes and writes manifest" {
    enable_tools claude cursor
    mkdir -p .ai/src/tools
    printf 'targets:\n  rules:\n    source: ".ai/src/DOES_NOT_EXIST"\n' > .ai/src/tools/cursor.yaml
    run run_agentsync sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"Rules source not found"* ]]
    # Both tools still produced output, and the manifest was written.
    [ -f "CLAUDE.md" ]
    [ -f "AGENTS.md" ]
    [ -f ".ai/.sync-manifest" ]
    # A second sync sees no false drift.
    run run_agentsync check
    [ "$status" -eq 0 ]
}
