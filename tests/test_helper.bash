#!/usr/bin/env bash
# Shared test helpers for bats tests.

# Path to the agentsync CLI
AGENTSYNC_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/agentsync.sh"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Create a temporary project directory for testing
setup_test_project() {
    TEST_PROJECT="$(mktemp -d "${TMPDIR:-/tmp}/agentsync_test.XXXXXX")"
    cd "$TEST_PROJECT"
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
    export AGENTSYNC_HOME="$REPO_ROOT"
}

# rm -rf that tolerates the transient ENOTEMPTY a settling git background task
# (gc/maintenance) or a CI filesystem can throw mid-delete. Retries briefly, then
# gives up quietly: the target is an ephemeral /tmp dir on a throwaway runner, so
# a leftover never matters — and a cleanup race must not fail an already-asserted
# test. Surfaced under `bats --jobs` on the release suite (rm of .git/objects).
_rm_rf_resilient() {
    local target="${1:-}"
    [[ -n "$target" ]] && [[ -d "$target" ]] || return 0
    for _ in 1 2 3; do
        rm -rf "$target" 2>/dev/null && return 0
        sleep 1
    done
    rm -rf "$target" 2>/dev/null || true
}

# Clean up temporary project
teardown_test_project() {
    [[ -n "${TEST_PROJECT:-}" ]] && _rm_rf_resilient "$TEST_PROJECT"
}

# Run agentsync from the repo (not installed version)
run_agentsync() {
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" "$@"
}

# Enable tools via agentsync CLI (writes to tools.enabled in agent_sync.yaml).
# Call after `init`. Passes --no-scaffold so existing tests stay deterministic —
# resolver-level tests can still write overrides at whichever layout they test.
# Tests that specifically validate enable's scaffolding call `run_agentsync enable`.
# Usage: enable_tools claude cursor copilot
enable_tools() {
    run_agentsync enable "$@" --no-scaffold >/dev/null
}

# ── Shared seed/clone fixture ────────────────────────────────────────────────
# Pattern: setup_file builds one seeded project (git init + agentsync init);
# each setup() clones it (APFS clonefile on macOS, cp -R elsewhere). Cuts the
# per-test cost of a fresh init from ~250 ms to ~10-30 ms.

# Usage (inside setup_file): seed_project [extra args forwarded to `init`]
seed_project() {
    TEST_SEED="$(mktemp -d "${TMPDIR:-/tmp}/agentsync_seed.XXXXXX")"
    export TEST_SEED
    (
        cd "$TEST_SEED"
        git init --quiet
        git config user.email "test@test.com"
        git config user.name "Test"
        AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init "$@" >/dev/null
    )
    export AGENTSYNC_HOME="$REPO_ROOT"
}

# Usage (inside teardown_file): clean up the seed dir
teardown_seed_project() {
    [[ -n "${TEST_SEED:-}" ]] && _rm_rf_resilient "$TEST_SEED"
}

# Usage (inside setup): create a per-test clone of the seed and cd into it.
# Uses APFS clonefile via `cp -c -R` when available — near-O(1) on macOS.
clone_seed() {
    TEST_PROJECT="$(mktemp -d "${TMPDIR:-/tmp}/agentsync_clone.XXXXXX")"
    # mktemp already created the directory; remove so cp can clone into the path.
    rmdir "$TEST_PROJECT"
    if ! cp -c -R "$TEST_SEED" "$TEST_PROJECT" 2>/dev/null; then
        cp -R "$TEST_SEED" "$TEST_PROJECT"
    fi
    cd "$TEST_PROJECT"
    export AGENTSYNC_HOME="$REPO_ROOT"
}
