#!/usr/bin/env bats
# Tests for agentsync setup-hooks.

load test_helper

setup_file() { seed_project; }
teardown_file() { teardown_seed_project; }
setup() { clone_seed; }
teardown() { teardown_test_project; }

@test "setup-hooks creates post-merge hook" {
    run run_agentsync setup-hooks
    [ "$status" -eq 0 ]
    [ -f ".git/hooks/post-merge" ]
    [ -x ".git/hooks/post-merge" ]
}

@test "setup-hooks creates post-checkout hook" {
    run run_agentsync setup-hooks
    [ "$status" -eq 0 ]
    [ -f ".git/hooks/post-checkout" ]
    [ -x ".git/hooks/post-checkout" ]
}

@test "setup-hooks adds agentsync block" {
    run run_agentsync setup-hooks
    [ "$status" -eq 0 ]
    grep -q "AGENTSYNC AUTO SYNC" .git/hooks/post-merge
    grep -q "AGENTSYNC AUTO SYNC" .git/hooks/post-checkout
}

@test "setup-hooks is idempotent" {
    run run_agentsync setup-hooks
    run run_agentsync setup-hooks
    [ "$status" -eq 0 ]

    # Should have exactly one block
    local count
    count=$(grep -c "AGENTSYNC AUTO SYNC START" .git/hooks/post-merge)
    [ "$count" -eq 1 ]
}

@test "setup-hooks preserves existing hook content" {
    # Create pre-existing hook
    echo '#!/bin/sh' > .git/hooks/post-merge
    echo 'echo "existing hook"' >> .git/hooks/post-merge
    chmod +x .git/hooks/post-merge

    run run_agentsync setup-hooks
    [ "$status" -eq 0 ]
    grep -q "existing hook" .git/hooks/post-merge
    grep -q "AGENTSYNC AUTO SYNC" .git/hooks/post-merge
}

@test "setup-hooks: hook invokes the installed agentsync binary" {
    run run_agentsync setup-hooks
    [ "$status" -eq 0 ]
    grep -q "command -v agentsync" .git/hooks/post-merge
    grep -q "agentsync sync" .git/hooks/post-merge
}

@test "setup-hooks: hook is non-fatal on sync failure" {
    run run_agentsync setup-hooks
    [ "$status" -eq 0 ]
    # The sync call is OR'd with a fallback so a failed sync never blocks git.
    grep -q "agentsync sync ||" .git/hooks/post-merge
}

@test "setup-hooks: default run does not install a pre-commit hook" {
    run run_agentsync setup-hooks
    [ "$status" -eq 0 ]
    [ ! -f ".git/hooks/pre-commit" ]
}

@test "setup-hooks --pre-commit installs a pre-commit hook" {
    run run_agentsync setup-hooks --pre-commit
    [ "$status" -eq 0 ]
    [ -f ".git/hooks/pre-commit" ]
    [ -x ".git/hooks/pre-commit" ]
    grep -q "AGENTSYNC AUTO SYNC" .git/hooks/pre-commit
}

@test "setup-hooks --pre-commit uses --if-stale" {
    run run_agentsync setup-hooks --pre-commit
    [ "$status" -eq 0 ]
    grep -q "agentsync sync --if-stale" .git/hooks/pre-commit
}

@test "setup-hooks rejects unknown options" {
    run run_agentsync setup-hooks --bogus
    [ "$status" -eq 2 ]
}
