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

# Clean up temporary project
teardown_test_project() {
    if [[ -n "${TEST_PROJECT:-}" ]] && [[ -d "$TEST_PROJECT" ]]; then
        rm -rf "$TEST_PROJECT"
    fi
}

# Run agentsync from the repo (not installed version)
run_agentsync() {
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" "$@"
}

# Enable tools via agentsync CLI (writes to tools.enabled in agent_sync.yaml).
# Call after `init`.
# Usage: enable_tools claude cursor copilot
enable_tools() {
    run_agentsync enable "$@" >/dev/null
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
    [[ -n "${TEST_SEED:-}" ]] && [[ -d "$TEST_SEED" ]] && rm -rf "$TEST_SEED"
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
