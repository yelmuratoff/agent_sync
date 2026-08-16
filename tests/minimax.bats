#!/usr/bin/env bats
# Tests for the `minimax` (MiniMax Code) AgentSync target.
#
# MiniMax Code is the desktop AI agent app built on the OpenCode runtime
# (bundled @opencode-ai/sdk 1.18.18). The project-level files it reads are
# exactly OpenCode's, so this target mirrors opencode.yaml's destinations.
#
# Coverage:
#   - list, enable, disable
#   - init auto-detect
#   - sync (all categories)
#   - --only / --skip / --dry-run
#   - check + drift
#   - adopt refusal for converted outputs
#   - rollback
#   - workspace fan-out
#   - doctor
#   - customize / simplify
#   - clean project
#   - existing Claude coexistence
#   - existing AGENTS.md coexistence
#   - gitignore

load test_helper

setup() {
    setup_test_project
}

teardown() {
    teardown_test_project
}

# Convenience: init + enable a tool in one call.
init_and_enable() {
    run_agentsync init --no-detect >/dev/null
    enable_tools "$@"
}

# ── list / enable / disable ─────────────────────────────────────────────────

@test "minimax: list shows MiniMax Code as a base tool" {
    run_agentsync init --no-detect >/dev/null

    run run_agentsync list
    [ "$status" -eq 0 ]
    [[ "$output" == *"MiniMax Code"* ]]
    [[ "$output" == *"minimax"* ]]
}

@test "minimax: enable adds to tools.enabled" {
    run run_agentsync enable minimax
    [ "$status" -eq 0 ]
    [[ "$output" == *"Enabled 1 tool(s)"* ]]
    grep -q "^    - minimax$" .ai/agent_sync.yaml
}

@test "minimax: enable is idempotent (no duplicates)" {
    run_agentsync enable minimax >/dev/null
    run_agentsync enable minimax >/dev/null
    local count
    count=$(grep -c "^    - minimax$" .ai/agent_sync.yaml)
    [ "$count" -eq 1 ]
}

@test "minimax: disable removes from tools.enabled" {
    run_agentsync enable minimax >/dev/null
    run run_agentsync disable minimax
    [ "$status" -eq 0 ]
    ! grep -q "^    - minimax$" .ai/agent_sync.yaml
}

@test "minimax: enable is a no-op for unknown tool slugs" {
    run run_agentsync enable bogus_minimax_xyz
    [ "$status" -eq 0 ]
    [[ "$output" == *"Unknown tool"* ]]
}

# ── init auto-detect ───────────────────────────────────────────────────────

@test "minimax: init auto-detects .opencode/ as a minimax marker" {
    mkdir -p .opencode/skills
    run run_agentsync init
    [ "$status" -eq 0 ]
    grep -q "^    - minimax$" ".ai/agent_sync.yaml"
}

@test "minimax: init auto-detects opencode.json as a minimax marker" {
    : > opencode.json
    run run_agentsync init
    [ "$status" -eq 0 ]
    grep -q "^    - minimax$" ".ai/agent_sync.yaml"
}

@test "minimax: init with --no-detect does not auto-enable" {
    mkdir -p .opencode
    run run_agentsync init --no-detect
    [ "$status" -eq 0 ]
    grep -q "enabled: \[\]" ".ai/agent_sync.yaml"
}

@test "minimax: init --tools minimax scaffolds minimax settings base" {
    run run_agentsync init --tools minimax
    [ "$status" -eq 0 ]
    [ -f ".ai/src/settings/minimax.json" ]
    [ ! -d ".ai/src/mcp" ]   # MCP is composed at sync time, not scaffolded
}

# ── sync (all categories) ──────────────────────────────────────────────────

@test "minimax: sync produces AGENTS.md at project root" {
    init_and_enable minimax
    run run_agentsync sync
    [ "$status" -eq 0 ]
    [ -f "AGENTS.md" ]
}

@test "minimax: sync produces .opencode/skills/<name>/SKILL.md" {
    init_and_enable minimax
    # Scaffold at least one skill so the sync has something to copy.
    mkdir -p .ai/src/skills/deploy
    printf '%s\n' '---' 'description: Deploy to production' '---' > .ai/src/skills/deploy/SKILL.md
    run_agentsync sync >/dev/null
    [ -d ".opencode/skills" ]
    [ -f ".opencode/skills/deploy/SKILL.md" ]
}

@test "minimax: sync produces .opencode/commands/<name>.md" {
    init_and_enable minimax
    printf '%s\n' '---' 'description: Run a code review' '---' > .ai/src/commands/review.md
    run_agentsync sync >/dev/null
    [ -d ".opencode/commands" ]
    [ -f ".opencode/commands/review.md" ]
}

@test "minimax: sync produces .opencode/agents/<name>.md" {
    init_and_enable minimax
    printf '%s\n' '---' 'description: Test subagent' 'mode: subagent' '---' > .ai/src/agents/test.md
    run_agentsync sync >/dev/null
    [ -d ".opencode/agents" ]
    [ -f ".opencode/agents/test.md" ]
}

@test "minimax: sync produces opencode.json from per-tool settings" {
    init_and_enable minimax
    run_agentsync sync >/dev/null
    [ -f "opencode.json" ]
    python3 -c "import json; json.load(open('opencode.json'))"
}

@test "minimax: sync composes shared .ai/src/mcp.json into opencode.json mcp{}" {
    init_and_enable minimax
    mkdir -p .ai/src
    printf '%s\n' '{"mcpServers":{"github":{"command":"npx","args":["-y","@github/mcp"]}}}' > .ai/src/mcp.json
    run run_agentsync sync
    [ "$status" -eq 0 ]
    python3 -c "import json; d=json.load(open('opencode.json')); assert 'github' in d['mcp']; assert d['mcp']['github']['command'] == ['npx','-y','@github/mcp']"
}

@test "minimax: sync produces .opencode/plugins/agentsync.ts" {
    init_and_enable minimax
    run_agentsync sync >/dev/null
    [ -f ".opencode/plugins/agentsync.ts" ]
    grep -q "AgentSyncHooks" ".opencode/plugins/agentsync.ts"
}

# ── --only / --skip / --dry-run ────────────────────────────────────────────

@test "minimax: --only minimax syncs only this tool" {
    init_and_enable minimax opencode
    run run_agentsync sync --only minimax
    [ "$status" -eq 0 ]
    # AGENTS.md is a shared dest with opencode — must exist.
    [ -f "AGENTS.md" ]
    # .opencode/ subtree was touched (proves minimax ran).
    [ -d ".opencode/skills" ] || [ -d ".opencode/agents" ] || [ -d ".opencode/commands" ]
}

@test "minimax: --skip minimax reports MiniMax Code in the skipped list" {
    init_and_enable minimax opencode
    run run_agentsync sync --skip minimax
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipped:"* ]]
    [[ "$output" == *"MiniMax Code"* ]]
}

@test "minimax: sync --dry-run does not create outputs" {
    init_and_enable minimax
    run run_agentsync sync --dry-run
    [ "$status" -eq 0 ]
    [ ! -f "AGENTS.md" ]
    [ ! -d ".opencode" ]
}

@test "minimax: sync is idempotent (manifest bytes are stable)" {
    init_and_enable minimax
    run_agentsync sync >/dev/null
    local first
    first=$(shasum -a 256 .ai/.sync-manifest | awk '{print $1}')
    run_agentsync sync >/dev/null
    local second
    second=$(shasum -a 256 .ai/.sync-manifest | awk '{print $1}')
    [ "$first" = "$second" ]
}

# ── check + drift detection ────────────────────────────────────────────────

@test "minimax: check passes after sync" {
    init_and_enable minimax
    run_agentsync sync >/dev/null
    run run_agentsync check
    [ "$status" -eq 0 ]
    [[ "$output" == *"synced"* ]]
}

@test "minimax: check fails when generated AGENTS.md is modified" {
    init_and_enable minimax
    run_agentsync sync >/dev/null
    echo "tampered" >> AGENTS.md
    run run_agentsync check
    [ "$status" -ne 0 ]
    [[ "$output" == *"out of sync"* ]]
}

@test "minimax: check fails when generated .opencode output is missing" {
    init_and_enable minimax
    run_agentsync sync >/dev/null
    rm -rf .opencode
    run run_agentsync check
    [ "$status" -ne 0 ]
}

@test "minimax: drift refusal on manual edit (no --force)" {
    init_and_enable minimax
    run_agentsync sync >/dev/null
    echo "manual" >> AGENTS.md
    run run_agentsync sync
    [ "$status" -ne 0 ]
    [[ "$output" == *"Manual edits detected"* ]]
}

@test "minimax: --force overwrites a manually-edited generated file" {
    init_and_enable minimax
    run_agentsync sync >/dev/null
    echo "manual" >> AGENTS.md
    run run_agentsync sync --force
    [ "$status" -eq 0 ]
    ! grep -q "manual" AGENTS.md
}

# ── adopt refusal (converted targets) ─────────────────────────────────────

@test "minimax: adopt refuses an opencode_md subagent (format conversion)" {
    init_and_enable minimax
    printf '%s\n' '---' 'description: Test subagent' 'mode: subagent' '---' > .ai/src/agents/test.md
    run_agentsync sync >/dev/null
    local agent_file
    agent_file=$(find .opencode/agents -name '*.md' 2>/dev/null | head -1)
    [ -n "$agent_file" ]
    echo "# edit" >> "$agent_file"
    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt --yes "$agent_file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"opencode_md"* ]]
}

# ── rollback ───────────────────────────────────────────────────────────────

@test "minimax: rollback --yes removes generated files" {
    init_and_enable minimax
    # Plant at least one skill so rollback has a non-empty file to remove.
    mkdir -p .ai/src/skills/deploy
    printf '%s\n' '---' 'description: Deploy' '---' > .ai/src/skills/deploy/SKILL.md
    run_agentsync sync >/dev/null
    [ -f "AGENTS.md" ]
    [ -f ".opencode/plugins/agentsync.ts" ]
    [ -f ".opencode/skills/deploy/SKILL.md" ]
    run run_agentsync rollback --yes
    [ "$status" -eq 0 ]
    [ ! -f "AGENTS.md" ]
    [ ! -f ".opencode/plugins/agentsync.ts" ]
    [ ! -f ".opencode/skills/deploy/SKILL.md" ]
}

# ── gitignore ──────────────────────────────────────────────────────────────

@test "minimax: sync adds MiniMax outputs to .gitignore managed block" {
    init_and_enable minimax
    run_agentsync sync >/dev/null
    # AgentSync writes the managed block with trailing slashes on directory
    # targets — see sync.sh:_collect_tool_dests. Accept any .opencode/* line.
    grep -q "^\.opencode/" .gitignore
    grep -q "^opencode\.json$" .gitignore
    # The sync-manifest is intentionally NOT gitignored — it is meant to be
    # committed so CI can detect drift (see lib/helpers/manifest.sh:7).
    # Verify the block exists between the AI SYNC markers.
    grep -q "AI SYNC GENERATED START" .gitignore
    grep -q "AI SYNC GENERATED END" .gitignore
}

# ── customize / simplify ──────────────────────────────────────────────────

@test "minimax: customize settings scaffolds a per-tool override" {
    init_and_enable minimax
    run_agentsync sync >/dev/null
    run run_agentsync customize minimax settings --yes
    [ "$status" -eq 0 ]
    [ -f ".ai/src/tools/minimax/settings.json" ]
}

@test "minimax: customize hooks scaffolds the OpenCode plugin override" {
    init_and_enable minimax
    run_agentsync sync >/dev/null
    run run_agentsync customize minimax hooks --yes
    [ "$status" -eq 0 ]
    [ -f ".ai/src/tools/minimax/hooks.ts" ]
    grep -q "AgentSyncHooks" ".ai/src/tools/minimax/hooks.ts"
}

@test "minimax: simplify cleans redundant override fields" {
    init_and_enable minimax
    run run_agentsync customize minimax --full --yes
    [ "$status" -eq 0 ]
    # Simplify should not fail and should leave the override in place.
    run run_agentsync simplify minimax
    [ "$status" -eq 0 ]
    [ -f ".ai/src/tools/minimax.yaml" ]
}

# ── coexistence: Claude and AGENTS.md ─────────────────────────────────────

@test "minimax: existing .claude/CLAUDE.md does not block minimax sync" {
    init_and_enable claude minimax
    # Plant a Claude-only rule so the destination is non-empty.
    mkdir -p .claude/rules
    echo "# Claude rule" > .claude/rules/core.md
    run run_agentsync sync
    [ "$status" -eq 0 ]
    [ -f "AGENTS.md" ]
    [ -d ".claude/rules" ]
    [ -f ".claude/rules/core.md" ]
}

@test "minimax: existing project-root AGENTS.md is overwritten by sync (documented behavior)" {
    echo "# Pre-existing user AGENTS.md" > AGENTS.md
    init_and_enable minimax
    run run_agentsync sync
    [ "$status" -eq 0 ]
    # After sync, AGENTS.md is the canonical one from .ai/src/AGENTS.md.
    grep -q "Project Agent" AGENTS.md
}

# ── clean project (no .ai/, no MiniMax config) ───────────────────────────

@test "minimax: clean project syncs from scratch without error" {
    init_and_enable minimax
    run run_agentsync sync
    [ "$status" -eq 0 ]
    [ -f "AGENTS.md" ]
    [ -d ".opencode" ]
}

# ── doctor ────────────────────────────────────────────────────────────────

@test "minimax: doctor reports MiniMax Code in the enabled-tools list" {
    run_agentsync init --no-detect >/dev/null
    run_agentsync enable minimax >/dev/null
    run run_agentsync doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"MiniMax Code"* ]]
}

@test "minimax: doctor does NOT flag .opencode/ as orphan when minimax is enabled" {
    init_and_enable minimax
    run_agentsync sync >/dev/null
    run run_agentsync doctor
    [[ ! "$output" == *".opencode/ — orphan"* ]]
}

@test "minimax: doctor does NOT flag .opencode/ as orphan when opencode is enabled" {
    init_and_enable opencode
    run_agentsync sync >/dev/null
    run run_agentsync doctor
    [[ ! "$output" == *".opencode/ — orphan"* ]]
}

# ── subagent frontmatter (opencode_md format) ─────────────────────────────

@test "minimax: synced subagent uses opencode_md format (mode + permissions)" {
    init_and_enable minimax
    printf '%s\n' '---' 'description: Test subagent' 'mode: subagent' '---' > .ai/src/agents/test.md
    run_agentsync sync >/dev/null
    [ -f ".opencode/agents/test.md" ]
    # opencode_md format: the source frontmatter is rewritten with safe defaults
    # (mode: primary, permission: edit/bash/webfetch ask). The original
    # description line should NOT survive verbatim.
    ! grep -q "^description: Test subagent$" .opencode/agents/test.md
    grep -q "^mode:" .opencode/agents/test.md
}

# ── workspace fan-out ─────────────────────────────────────────────────────

@test "minimax: sync --workspace forwards --only minimax to every project" {
    # Create a workspace under cwd so the --workspace fan-out picks it up.
    local parent="$BATS_TEST_TMPDIR/workspace"
    mkdir -p "$parent/a" "$parent/b"
    for sub in a b; do
        (
            cd "$parent/$sub"
            git init --quiet
            git config user.email "test@test.com"
            git config user.name "Test"
            AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init >/dev/null
            AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" enable minimax --no-scaffold >/dev/null
        )
    done

    cd "$parent"
    run run_agentsync sync --workspace --only minimax
    [ "$status" -eq 0 ]
    [ -f "a/AGENTS.md" ]
    [ -f "b/AGENTS.md" ]
}
