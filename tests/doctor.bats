#!/usr/bin/env bats
# Tests for agentsync doctor.

load test_helper

setup() {
    setup_test_project
}

teardown() {
    teardown_test_project
}

@test "doctor fails with exit 2 when .ai/ missing" {
    run run_agentsync doctor
    [ "$status" -eq 2 ]
    [[ "$output" == *".ai/ directory missing"* ]]
}

@test "doctor passes on fresh init" {
    run_agentsync init >/dev/null
    run run_agentsync doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"All checks passed"* ]]
}

@test "doctor reports enabled tools" {
    run_agentsync init >/dev/null
    run_agentsync enable claude >/dev/null
    run run_agentsync doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"Claude Code"* ]]
}

@test "doctor shows customization marker" {
    run_agentsync init >/dev/null
    run_agentsync enable claude >/dev/null
    run_agentsync customize claude >/dev/null
    run run_agentsync doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"customized"* ]]
}

@test "doctor flags legacy enabled: true" {
    run_agentsync init >/dev/null
    mkdir -p .ai/src/tools
    cat > .ai/src/tools/claude.yaml <<'YAML'
enabled: true
YAML
    run run_agentsync doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"legacy"* ]]
}

@test "doctor reports source directories" {
    run_agentsync init >/dev/null
    run run_agentsync doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *".ai/src/AGENTS.md"* ]]
    [[ "$output" == *".ai/src/rules"* ]]
}

# ── Phase 5: security scan ─────────────────────────────────────────────────

@test "doctor catches planted GitHub PAT in mcp override" {
    run_agentsync init >/dev/null
    mkdir -p .ai/src/mcp
    cat > .ai/src/mcp/claude.json <<'JSON'
{"mcpServers":{"gh":{"env":{"TOKEN":"ghp_abcdefghijklmnopqrstuvwxyz012345678901"}}}}
JSON
    run run_agentsync doctor
    [ "$status" -eq 2 ]
    [[ "$output" == *"possible secret"* ]]
}

@test "doctor catches AWS access key" {
    run_agentsync init >/dev/null
    mkdir -p .ai/src/settings
    cat > .ai/src/settings/claude.json <<'JSON'
{"aws":{"key":"AKIAIOSFODNN7EXAMPLE"}}
JSON
    run run_agentsync doctor
    [ "$status" -eq 2 ]
    [[ "$output" == *"possible secret"* ]]
}

@test "doctor allows \${VAR} placeholders in mcp overrides" {
    run_agentsync init >/dev/null
    mkdir -p .ai/src/mcp
    cat > .ai/src/mcp/claude.json <<'JSON'
{"mcpServers":{"gh":{"env":{"TOKEN":"${GITHUB_TOKEN}"}}}}
JSON
    run run_agentsync doctor
    [ "$status" -eq 0 ]
    [[ "$output" != *"possible secret"* ]]
}

@test "doctor flags invalid JSON override" {
    run_agentsync init >/dev/null
    mkdir -p .ai/src/mcp
    # Only run this check if python3 or node is available to validate JSON.
    if ! command -v python3 >/dev/null 2>&1 && ! command -v node >/dev/null 2>&1; then
        skip "no JSON validator available"
    fi
    echo '{"broken":' > .ai/src/mcp/cursor.json
    run run_agentsync doctor
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid JSON"* ]]
}

# ── Phase 5: list payload-override column ──────────────────────────────────

@test "list shows payload override column when hooks override exists" {
    run_agentsync init --tools cursor >/dev/null
    run_agentsync customize cursor hooks --yes >/dev/null
    run run_agentsync list
    [ "$status" -eq 0 ]
    # The H column should be starred for cursor after creating hooks override.
    [[ "$output" == *"H*"* ]]
    [[ "$output" == *"payload override"* ]]
}

# ── Phase 5: version pinning ───────────────────────────────────────────────

@test "init pins agentsync_version in agent_sync.yaml" {
    run_agentsync init --no-detect >/dev/null
    grep -q '^agentsync_version:' ".ai/agent_sync.yaml"
}

@test "doctor warns when pinned version differs from CLI" {
    run_agentsync init --no-detect >/dev/null
    # Rewrite pin to an impossible-old version.
    sed -i.bak -E 's|^agentsync_version:.*|agentsync_version: "0.0.1"|' .ai/agent_sync.yaml
    rm -f .ai/agent_sync.yaml.bak

    run run_agentsync doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"pinned"* ]]
    [[ "$output" == *"upgrade-config"* ]]
}

@test "upgrade-config bumps pinned version to current CLI" {
    run_agentsync init --no-detect >/dev/null
    sed -i.bak -E 's|^agentsync_version:.*|agentsync_version: "0.0.1"|' .ai/agent_sync.yaml
    rm -f .ai/agent_sync.yaml.bak

    run run_agentsync upgrade-config
    [ "$status" -eq 0 ]

    # After upgrade-config, pinned version should no longer be 0.0.1.
    ! grep -q 'agentsync_version: "0.0.1"' .ai/agent_sync.yaml

    # And doctor should now pass without the version warning.
    run run_agentsync doctor
    [[ "$output" != *"differs from pinned"* ]]
}
