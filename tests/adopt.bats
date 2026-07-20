#!/usr/bin/env bats
# Tests for `agentsync adopt` — promote a manual edit in a generated file
# back into .ai/src/, refuse transformed targets, keep next sync drift-free.

load test_helper

# Seed `init` once; each test clones it (APFS clonefile) and enables/syncs
# the tool it needs. Per-test `init` was the bulk of this file's runtime.
setup_file() { seed_project; }
teardown_file() { teardown_seed_project; }
setup() { clone_seed; }
teardown() { teardown_test_project; }

# ── 1:1 adoptable targets ───────────────────────────────────────────────────

@test "adopt: rule file (claude - no header) round-trips into source" {
    enable_tools claude
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    echo "## Manual addition" >> .claude/rules/core.md

    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt --yes .claude/rules/core.md
    [ "$status" -eq 0 ]
    grep -q "Manual addition" .ai/src/rules/core.md
}

@test "adopt: subsequent sync is drift-free after rule adoption" {
    enable_tools claude
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    echo "## Adopted" >> .claude/rules/core.md
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt --yes .claude/rules/core.md >/dev/null

    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync
    [ "$status" -eq 0 ]
    [[ "$output" != *"Manual edits detected"* ]]
}

@test "adopt: AGENTS.md round-trips into .ai/src/AGENTS.md" {
    enable_tools claude
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    echo "## Custom appendix" >> CLAUDE.md

    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt --yes CLAUDE.md
    [ "$status" -eq 0 ]
    grep -q "Custom appendix" .ai/src/AGENTS.md
}

@test "adopt: settings scaffolds canonical override path" {
    enable_tools claude
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    echo '{"manualEdit": true}' > .claude/settings.json
    [ ! -f ".ai/src/tools/claude/settings.json" ]

    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt --yes .claude/settings.json
    [ "$status" -eq 0 ]
    [ -f ".ai/src/tools/claude/settings.json" ]
    grep -q "manualEdit" .ai/src/tools/claude/settings.json
}

@test "adopt: skill file round-trips" {
    enable_tools claude
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    local skill_file
    skill_file=$(find .claude/skills -name 'SKILL.md' | head -1)
    [ -n "$skill_file" ]
    echo "## Skill addition" >> "$skill_file"

    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt --yes "$skill_file"
    [ "$status" -eq 0 ]
}

# ── Refusals ────────────────────────────────────────────────────────────────

@test "adopt: refuses cursor rule (header injection)" {
    enable_tools cursor
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    echo "extra" >> .cursor/rules/core.mdc

    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt --yes .cursor/rules/core.mdc
    [ "$status" -ne 0 ]
    [[ "$output" == *"frontmatter header"* ]]
}

@test "adopt: refuses codex toml subagent" {
    enable_tools codex
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    local toml_file
    toml_file=$(find .codex/agents -name '*.toml' 2>/dev/null | head -1)
    [ -n "$toml_file" ]
    echo "# edit" >> "$toml_file"

    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt --yes "$toml_file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"toml"* ]]
}

@test "adopt: refuses converted OpenCode subagent" {
    enable_tools opencode
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    local agent_file
    agent_file=$(find .opencode/agents -name '*.md' 2>/dev/null | head -1)
    [ -n "$agent_file" ]
    echo "# edit" >> "$agent_file"

    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt --yes "$agent_file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"opencode_md"* ]]
}

@test "adopt: refuses unknown destination" {
    enable_tools claude
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    echo "hello" > README.md

    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt --yes README.md
    [ "$status" -ne 0 ]
}

@test "adopt: refuses path outside repo" {
    enable_tools claude
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null

    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt --yes /etc/hosts
    [ "$status" -ne 0 ]
    [[ "$output" == *"outside the project"* ]]
}

@test "adopt: refuses when manifest is missing" {
    enable_tools claude
    # No sync yet, no manifest.

    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt --yes CLAUDE.md
    [ "$status" -ne 0 ]
    [[ "$output" == *"manifest"* ]]
}

@test "adopt: refuses untracked file (not in manifest)" {
    enable_tools claude
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    # Create a file inside a dest dir that AgentSync didn't produce.
    echo "rogue" > .claude/rules/extraneous.md

    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt --yes .claude/rules/extraneous.md
    [ "$status" -ne 0 ]
    [[ "$output" == *"not tracked"* ]]
}

# ── Dry-run safety ──────────────────────────────────────────────────────────

@test "adopt: --dry-run does not write source" {
    enable_tools claude
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    local before
    before=$(shasum -a 256 .ai/src/rules/core.md | awk '{print $1}')
    echo "## Edit" >> .claude/rules/core.md

    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt --dry-run .claude/rules/core.md
    [ "$status" -eq 0 ]

    local after
    after=$(shasum -a 256 .ai/src/rules/core.md | awk '{print $1}')
    [ "$before" = "$after" ]
}

@test "adopt: --dry-run does not update manifest" {
    enable_tools claude
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    local before
    before=$(shasum -a 256 .ai/.sync-manifest | awk '{print $1}')
    echo "## Edit" >> .claude/rules/core.md

    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt --dry-run .claude/rules/core.md >/dev/null
    local after
    after=$(shasum -a 256 .ai/.sync-manifest | awk '{print $1}')
    [ "$before" = "$after" ]
}

@test "adopt: refuses non-interactive without --yes" {
    enable_tools claude
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    echo "## Edit" >> .claude/rules/core.md

    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt .claude/rules/core.md
    [ "$status" -ne 0 ]
    [[ "$output" == *"non-interactively"* ]]
}

# ── No-op already-in-sync ───────────────────────────────────────────────────

@test "adopt: no-op when dest already matches source" {
    enable_tools claude
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null

    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt --yes .claude/rules/core.md
    [ "$status" -eq 0 ]
    [[ "$output" == *"already matches"* ]]
}

# ── Batch mode (--all) ───────────────────────────────────────────────────────

@test "adopt --all: promotes every drifted 1:1 output" {
    enable_tools claude
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    echo "## Rule edit" >> .claude/rules/core.md
    echo "## Agents edit" >> CLAUDE.md

    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt --all --yes
    [ "$status" -eq 0 ]
    grep -q "Rule edit" .ai/src/rules/core.md
    grep -q "Agents edit" .ai/src/AGENTS.md
}

@test "adopt --all: no-op when nothing drifted" {
    enable_tools claude
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null

    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt --all --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"Nothing to adopt"* ]]
}

@test "adopt --all: adopts adoptable output but skips refused target" {
    enable_tools claude cursor
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    echo "## Adoptable" >> .claude/rules/core.md
    echo "extra" >> .cursor/rules/core.mdc

    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt --all --yes
    [ "$status" -eq 0 ]
    grep -q "Adoptable" .ai/src/rules/core.md
    [[ "$output" == *"skipped"* ]]
    [[ "$output" == *".cursor/rules/core.mdc"* ]]
}

@test "adopt --all: skips same-source conflicts without writing" {
    enable_tools claude gemini
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    local before
    before=$(shasum -a 256 .ai/src/AGENTS.md | awk '{print $1}')
    echo "## Claude only" >> CLAUDE.md
    echo "## Gemini only" >> GEMINI.md

    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt --all --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"multiple edited outputs map to"* ]]

    local after
    after=$(shasum -a 256 .ai/src/AGENTS.md | awk '{print $1}')
    [ "$before" = "$after" ]
}

@test "adopt --all: --dry-run writes nothing" {
    enable_tools claude
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    local before
    before=$(shasum -a 256 .ai/src/rules/core.md | awk '{print $1}')
    echo "## Edit" >> .claude/rules/core.md

    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt --all --dry-run
    [ "$status" -eq 0 ]

    local after
    after=$(shasum -a 256 .ai/src/rules/core.md | awk '{print $1}')
    [ "$before" = "$after" ]
}

@test "adopt --all: rejects a dest-file argument" {
    enable_tools claude
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null

    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt --all CLAUDE.md
    [ "$status" -eq 2 ]
    [[ "$output" == *"takes no"* ]]
}

@test "adopt --all: refuses non-interactive without --yes" {
    enable_tools claude
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    echo "## Edit" >> .claude/rules/core.md

    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt --all
    [ "$status" -ne 0 ]
    [[ "$output" == *"non-interactively"* ]]
}

@test "adopt --all: subsequent sync is drift-free" {
    enable_tools claude
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    echo "## Adopted" >> .claude/rules/core.md
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" adopt --all --yes >/dev/null

    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync
    [ "$status" -eq 0 ]
    [[ "$output" != *"Manual edits detected"* ]]
}
