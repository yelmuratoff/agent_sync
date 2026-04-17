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

# Flip the given tool yamls to enabled: true. Call after `init`.
# Usage: enable_tools claude cursor copilot
enable_tools() {
    local tool f tmp
    for tool in "$@"; do
        f=".ai/src/tools/${tool}.yaml"
        tmp="${f}.tmp"
        sed 's/^enabled: false$/enabled: true/' "$f" > "$tmp" && mv "$tmp" "$f"
    done
}
