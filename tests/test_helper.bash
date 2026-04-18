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
