#!/usr/bin/env bats
# Tests for config-home profiles — variant tools + per-profile overlay.

load test_helper

setup() {
    setup_test_project
    run_agentsync init --no-detect --yes >/dev/null
    run_agentsync enable claude --no-scaffold >/dev/null
}

teardown() {
    teardown_test_project
}

@test "profile add: scaffolds a thin variant tool with config-home dests" {
    run_agentsync profile add hub --tools claude
    [ -f .ai/src/tools/claude-hub.yaml ]
    grep -q '^base: claude' .ai/src/tools/claude-hub.yaml
    grep -q 'profile_home: ".claude-hub"' .ai/src/tools/claude-hub.yaml
    grep -q 'dest: ".claude-hub/rules"' .ai/src/tools/claude-hub.yaml
    grep -q 'dest: ".claude-hub/CLAUDE.md"' .ai/src/tools/claude-hub.yaml
    grep -q 'dest: ".claude-hub/.mcp.json"' .ai/src/tools/claude-hub.yaml
}

@test "profile add: nested base dest keeps internal structure (not basename)" {
    run_agentsync profile add hub --tools amazonq
    # amazonq agents dest is .amazonq/rules/00-context.md — the rules/ segment
    # must survive the rewrite into the config home.
    grep -q 'dest: ".amazonq-hub/rules/00-context.md"' .ai/src/tools/amazonq-hub.yaml
}

@test "profile add: registers a profiles block in agent_sync.yaml" {
    run_agentsync profile add hub --tools claude
    grep -q '^profiles:' .ai/agent_sync.yaml
    grep -q 'claude-hub' .ai/agent_sync.yaml
}

@test "profile add: second profile inserts under the existing profiles block" {
    run_agentsync profile add hub --tools claude
    run_agentsync profile add klara --tools claude
    run run_agentsync profile list
    [ "$status" -eq 0 ]
    [[ "$output" == *"hub"* ]]
    [[ "$output" == *"klara"* ]]
    # Exactly one top-level profiles: key (no duplicate block).
    [ "$(grep -c '^profiles:' .ai/agent_sync.yaml)" -eq 1 ]
}

@test "sync: profile produces a self-contained config-home directory" {
    run_agentsync profile add hub --tools claude >/dev/null
    run run_agentsync sync
    [ "$status" -eq 0 ]
    [ -f .claude-hub/CLAUDE.md ]
    [ -d .claude-hub/rules ]
    [ -f .claude-hub/.mcp.json ]
}

@test "sync: profile output does not touch personal tool output" {
    run_agentsync profile add hub --tools claude >/dev/null
    run_agentsync sync >/dev/null
    # Personal Claude still at its own paths.
    [ -f CLAUDE.md ]
    [ -d .claude/rules ]
}

@test "sync: profile-only rule lands in the profile output, not personal" {
    run_agentsync profile add hub --tools claude >/dev/null
    echo "work-only" > .ai/profiles/hub/src/rules/work-only.md
    run_agentsync sync >/dev/null
    [ -f .claude-hub/rules/work-only.md ]
    [ ! -f .claude/rules/work-only.md ]
}

@test "sync: base rules fill into profile output (overlay fill)" {
    run_agentsync profile add hub --tools claude >/dev/null
    echo "base-rule body" > .ai/src/rules/base-rule.md
    echo "work-only" > .ai/profiles/hub/src/rules/work-only.md
    run_agentsync sync >/dev/null
    # Both the profile extra and the inherited base rule are present.
    [ -f .claude-hub/rules/work-only.md ]
    [ -f .claude-hub/rules/base-rule.md ]
}

@test "sync: profile wins on path collision with base" {
    run_agentsync profile add hub --tools claude >/dev/null
    echo "BASE VERSION" > .ai/src/rules/clash.md
    echo "PROFILE VERSION" > .ai/profiles/hub/src/rules/clash.md
    run_agentsync sync >/dev/null
    grep -q "PROFILE VERSION" .claude-hub/rules/clash.md
}

@test "sync --profile: syncs only the named profile" {
    run_agentsync profile add hub --tools claude >/dev/null
    run_agentsync profile add klara --tools claude >/dev/null
    run run_agentsync sync --profile hub
    [ "$status" -eq 0 ]
    [ -d .claude-hub ]
    [ ! -d .claude-klara ]
}

@test "sync: a plain run syncs every active profile" {
    run_agentsync profile add hub --tools claude >/dev/null
    run_agentsync profile add klara --tools claude >/dev/null
    run_agentsync sync >/dev/null
    [ -d .claude-hub ]
    [ -d .claude-klara ]
}

@test "sync: variant inherits behaviour flags from base (base: fallback)" {
    # Codex inlines rules into AGENTS.md and ships no rules dir — the variant
    # must inherit that, proving unset fields resolve through base:.
    run_agentsync enable codex --no-scaffold >/dev/null
    run_agentsync profile add hub --tools codex >/dev/null
    run_agentsync sync >/dev/null
    [ -f .codex-hub/AGENTS.md ]
    [ ! -d .codex-hub/rules ]
}

@test "sync: profile dests are gitignored" {
    run_agentsync profile add hub --tools claude >/dev/null
    run_agentsync sync >/dev/null
    grep -q "claude-hub" .gitignore
}

@test "sync: editing a profile output is detected as drift" {
    run_agentsync profile add hub --tools claude >/dev/null
    run_agentsync sync >/dev/null
    echo "manual edit" >> .claude-hub/CLAUDE.md
    run run_agentsync sync
    [ "$status" -ne 0 ]
    [[ "$output" == *"Manual edits detected"* ]]
}

@test "sync: idempotent across runs with a profile" {
    run_agentsync profile add hub --tools claude >/dev/null
    run_agentsync sync >/dev/null
    run_agentsync sync >/dev/null
    run run_agentsync check
    [ "$status" -eq 0 ]
}

@test "sync: profile and shared: overlays compose" {
    # Parent project with a custom rule; this project inherits it via shared:
    # AND layers a profile on top.
    local parent="$TEST_PROJECT/parent"
    mkdir -p "$parent"
    ( cd "$parent" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect --yes >/dev/null )
    echo "from-parent" > "$parent/.ai/src/rules/parent-only.md"

    cat >> .ai/agent_sync.yaml <<'EOF'

shared:
  path: "./parent"
  inherit: rules
EOF
    run_agentsync profile add hub --tools claude >/dev/null
    echo "from-profile" > .ai/profiles/hub/src/rules/profile-only.md
    run run_agentsync sync
    [ "$status" -eq 0 ]
    # Parent (shared) + profile extra both materialise into the profile output.
    [ -f .claude-hub/rules/parent-only.md ]
    [ -f .claude-hub/rules/profile-only.md ]
}

@test "sync: tears down profile overlay tmpdir (no leaked dirs)" {
    local sandbox="$TEST_PROJECT/tmpdir_sandbox"
    mkdir -p "$sandbox"
    run_agentsync profile add hub --tools claude >/dev/null
    echo "x" > .ai/profiles/hub/src/rules/x.md
    TMPDIR="$sandbox" run run_agentsync sync
    [ "$status" -eq 0 ]
    ! ls "$sandbox" 2>/dev/null | grep -q "agentsync_shared\." || false
}

@test "profile remove: deletes config-home output, variant file, and config entry" {
    run_agentsync profile add hub --tools claude >/dev/null
    run_agentsync sync >/dev/null
    [ -d .claude-hub ]
    run run_agentsync profile remove hub --yes
    [ "$status" -eq 0 ]
    [ ! -d .claude-hub ]
    [ ! -f .ai/src/tools/claude-hub.yaml ]
    # Last profile gone — the empty profiles: header is cleaned up too.
    ! grep -q '^profiles:' .ai/agent_sync.yaml
}

@test "sync --profile: missing value is a usage error" {
    run run_agentsync sync --profile
    [ "$status" -ne 0 ]
}
