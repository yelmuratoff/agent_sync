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
    mkdir -p .ai/src/tools/claude
    cat > .ai/src/tools/claude/mcp.json <<'JSON'
{"mcpServers":{"gh":{"env":{"TOKEN":"ghp_abcdefghijklmnopqrstuvwxyz012345678901"}}}}
JSON
    run run_agentsync doctor
    [ "$status" -eq 2 ]
    [[ "$output" == *"possible secret"* ]]
}

@test "doctor catches AWS access key" {
    run_agentsync init >/dev/null
    mkdir -p .ai/src/tools/claude
    cat > .ai/src/tools/claude/settings.json <<'JSON'
{"aws":{"key":"AKIAIOSFODNN7EXAMPLE"}}
JSON
    run run_agentsync doctor
    [ "$status" -eq 2 ]
    [[ "$output" == *"possible secret"* ]]
}

@test "doctor allows \${VAR} placeholders in mcp overrides" {
    run_agentsync init >/dev/null
    mkdir -p .ai/src/tools/claude
    cat > .ai/src/tools/claude/mcp.json <<'JSON'
{"mcpServers":{"gh":{"env":{"TOKEN":"${GITHUB_TOKEN}"}}}}
JSON
    run run_agentsync doctor
    [ "$status" -eq 0 ]
    [[ "$output" != *"possible secret"* ]]
}

@test "doctor flags invalid JSON override" {
    run_agentsync init >/dev/null
    mkdir -p .ai/src/tools/cursor
    # Only run this check if python3 or node is available to validate JSON.
    if ! command -v python3 >/dev/null 2>&1 && ! command -v node >/dev/null 2>&1; then
        skip "no JSON validator available"
    fi
    echo '{"broken":' > .ai/src/tools/cursor/mcp.json
    run run_agentsync doctor
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid JSON"* ]]
}

@test "doctor warns about legacy flat-layout payload overrides" {
    run_agentsync init >/dev/null
    mkdir -p .ai/src/mcp
    cat > .ai/src/mcp/cursor.json <<'JSON'
{"mcpServers":{}}
JSON
    run run_agentsync doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"Legacy payload layout"* ]]
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

@test "doctor shows Edit paths section for enabled tools" {
    run_agentsync init --no-detect >/dev/null
    run_agentsync enable claude >/dev/null
    run run_agentsync doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"Edit paths"* ]]
    [[ "$output" == *".ai/src/tools/claude/settings.json"* ]]
    # Shared MCP not configured → hint line should appear.
    [[ "$output" == *"agentsync add mcp"* ]]
}

@test "doctor Edit paths shows customize hint when no override exists" {
    run_agentsync init --no-detect >/dev/null
    enable_tools cursor
    run run_agentsync doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"Edit paths"* ]]
    [[ "$output" == *"agentsync customize cursor hooks"* ]]
}

@test "doctor Edit paths points at shared mcp.json when configured" {
    run_agentsync init --no-detect >/dev/null
    enable_tools claude
    echo '{"mcpServers":{}}' > .ai/src/mcp.json
    run run_agentsync doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *".ai/src/mcp.json"* ]]
    [[ "$output" == *"(shared)"* ]]
}

@test "doctor skips Edit paths section when no tools enabled" {
    run_agentsync init --no-detect >/dev/null
    run run_agentsync doctor
    [ "$status" -eq 0 ]
    [[ "$output" != *"Edit paths"* ]]
}

# ── Advisory checks (cross-project, orphan outputs, empty skills) ─────────────
# These detections must never bump exit code beyond 0 — they should be
# visible (yellow ⚠) but not fail CI in pre-commit hooks.

@test "doctor advises on empty skill directory (no SKILL.md)" {
    run_agentsync init --no-detect >/dev/null
    mkdir -p .ai/src/skills/empty-one
    run run_agentsync doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"empty-one/ — missing SKILL.md"* ]]
    [[ "$output" == *"advisory"* ]]
}

@test "doctor advises on legacy .agent/ directory" {
    run_agentsync init --no-detect >/dev/null
    mkdir -p .agent/rules
    echo "legacy" > .agent/AGENTS.md
    run run_agentsync doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *".agent/ — legacy pre-v0.6 layout"* ]]
}

@test "doctor flags .agent/ even when antigravity is enabled" {
    # Antigravity moved its output to `.agents/` (plural). `.agent/` is now
    # purely the pre-v0.6 layout regardless of which tools are enabled.
    run_agentsync init --no-detect >/dev/null
    enable_tools antigravity
    mkdir -p .agent/rules
    echo "stale" > .agent/AGENTS.md
    run run_agentsync doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *".agent/ — legacy pre-v0.6 layout"* ]]
}

@test "doctor does not flag .agents/ when antigravity is enabled" {
    run_agentsync init --no-detect >/dev/null
    enable_tools antigravity
    mkdir -p .agents/rules .agents/skills
    run run_agentsync doctor
    [ "$status" -eq 0 ]
    [[ "$output" != *".agents/ — orphan"* ]]
}

@test "doctor advises on orphan tool-output dir for disabled tool" {
    run_agentsync init --no-detect >/dev/null
    mkdir -p .cursor/rules
    run run_agentsync doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *".cursor/ — orphan"* ]]
}

@test "doctor does not flag .cursor/ when cursor is enabled" {
    run_agentsync init --no-detect >/dev/null
    enable_tools cursor
    mkdir -p .cursor/rules
    run run_agentsync doctor
    [ "$status" -eq 0 ]
    [[ "$output" != *".cursor/ — orphan"* ]]
}

@test "doctor detects identical-hash duplicate against parent .ai/src/" {
    # Parent has rules/shared.md; child below it has identical file. Child's
    # doctor should flag it as a duplicate and point at `agentsync dedupe`.
    local parent_dir="$TEST_PROJECT/parent"
    local child_dir="$parent_dir/child"
    mkdir -p "$parent_dir"
    ( cd "$parent_dir" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect >/dev/null )
    echo "shared content" > "$parent_dir/.ai/src/rules/shared.md"
    mkdir -p "$child_dir"
    ( cd "$child_dir" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect >/dev/null )
    cp "$parent_dir/.ai/src/rules/shared.md" "$child_dir/.ai/src/rules/shared.md"

    run bash -c "cd '$child_dir' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' doctor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"rules/shared.md — duplicate of parent"* ]]
    [[ "$output" == *"agentsync dedupe"* ]]
}

@test "doctor flags divergent shared file as info (not advisory)" {
    local parent_dir="$TEST_PROJECT/parent"
    local child_dir="$parent_dir/child"
    mkdir -p "$parent_dir"
    ( cd "$parent_dir" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect >/dev/null )
    echo "parent version" > "$parent_dir/.ai/src/rules/shared.md"
    mkdir -p "$child_dir"
    ( cd "$child_dir" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect >/dev/null )
    echo "child version" > "$child_dir/.ai/src/rules/shared.md"

    run bash -c "cd '$child_dir' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' doctor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"rules/shared.md — diverges from parent"* ]]
}

@test "doctor honors shared.path across git boundary (asymmetric repro)" {
    # Outer + inner with separate .git: walk-up alone would stop at inner's
    # boundary and miss the parent. Declaring shared.path in inner makes the
    # parent explicit, so doctor must use it regardless of git boundary.
    local outer="$TEST_PROJECT/outer"
    local inner="$outer/inner"
    mkdir -p "$outer"
    (
        cd "$outer"
        git init --quiet
        git config user.email "test@test.com"
        git config user.name "Test"
        AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect >/dev/null
    )
    echo "shared content" > "$outer/.ai/src/rules/shared.md"

    mkdir -p "$inner"
    (
        cd "$inner"
        git init --quiet
        git config user.email "test@test.com"
        git config user.name "Test"
        AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect >/dev/null
    )
    cp "$outer/.ai/src/rules/shared.md" "$inner/.ai/src/rules/shared.md"
    cat >> "$inner/.ai/agent_sync.yaml" <<'EOF'

shared:
  path: "../"
  inherit: rules
EOF

    run bash -c "cd '$inner' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' doctor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"rules/shared.md — duplicate of parent"* ]]
    [[ "$output" == *"(from shared.path)"* ]]
    [[ "$output" != *"No parent .ai/src/ found"* ]]
}

@test "doctor walk-up stops at git boundary" {
    # Outer project with .ai/src/, but the child has its own .git — the walk-up
    # must NOT traverse out of the child's git repo.
    local outer="$TEST_PROJECT/outer"
    local inner="$outer/inner"
    mkdir -p "$outer"
    (
        cd "$outer"
        git init --quiet
        git config user.email "test@test.com"
        git config user.name "Test"
        AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect >/dev/null
    )
    echo "would be dupe" > "$outer/.ai/src/rules/shared.md"
    mkdir -p "$inner"
    (
        cd "$inner"
        git init --quiet
        git config user.email "test@test.com"
        git config user.name "Test"
        AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect >/dev/null
    )
    cp "$outer/.ai/src/rules/shared.md" "$inner/.ai/src/rules/shared.md"

    run bash -c "cd '$inner' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' doctor"
    [ "$status" -eq 0 ]
    # Should NOT find the parent — git boundary stops the walk.
    [[ "$output" != *"duplicate of parent"* ]]
    [[ "$output" == *"No parent .ai/src/ found"* ]]
}

@test "doctor advises path-scoping when always-on rules exceed the budget" {
    run_agentsync init >/dev/null
    rm -f .ai/src/rules/*.md
    local big
    big=$(printf 'x%.0s' {1..6000})
    local i
    for i in 1 2 3 4; do
        printf '# Rule %s\n\n- %s\n' "$i" "$big" > ".ai/src/rules/bloat-$i.md"
    done
    run run_agentsync doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"always-on rule(s) load on every task"* ]]
    [[ "$output" == *"paths:"* ]]
}

@test "doctor does not count paths:-scoped rules toward always-on bloat" {
    run_agentsync init >/dev/null
    rm -f .ai/src/rules/*.md
    local big
    big=$(printf 'x%.0s' {1..30000})
    printf -- '---\npaths:\n  - "**/*.ts"\n---\n\n# Scoped\n\n- %s\n' "$big" > .ai/src/rules/scoped-big.md
    run run_agentsync doctor
    [ "$status" -eq 0 ]
    [[ "$output" != *"always-on rule(s) load on every task"* ]]
}
