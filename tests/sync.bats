#!/usr/bin/env bats
# Tests for agentsync sync.

load test_helper

setup() {
    setup_test_project
    run_agentsync init
}

teardown() {
    teardown_test_project
}

# ── Claude Code ──────────────────────────────────────────────────────────────

@test "sync creates Claude CLAUDE.md" {
    run run_agentsync sync
    [ "$status" -eq 0 ]
    [ -f ".claude/CLAUDE.md" ]
}

@test "sync creates Claude rules" {
    run run_agentsync sync
    [ "$status" -eq 0 ]
    [ -d ".claude/rules" ]
    local count
    count=$(ls -1 .claude/rules/*.md 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" -ge 1 ]
}

@test "sync creates Claude skills" {
    run run_agentsync sync
    [ "$status" -eq 0 ]
    [ -d ".claude/skills" ]
}

@test "sync creates Claude commands" {
    run run_agentsync sync
    [ "$status" -eq 0 ]
    [ -d ".claude/commands" ]
}

@test "sync creates Claude agents" {
    run run_agentsync sync
    [ "$status" -eq 0 ]
    [ -d ".claude/agents" ]
}

@test "sync appends @rules imports to CLAUDE.md" {
    run run_agentsync sync
    [ "$status" -eq 0 ]
    grep -q "@rules/" .claude/CLAUDE.md
}

# ── Cursor ───────────────────────────────────────────────────────────────────

@test "sync creates Cursor AGENTS.md" {
    run run_agentsync sync
    [ "$status" -eq 0 ]
    [ -f ".cursor/AGENTS.md" ]
}

@test "sync creates Cursor .mdc rules" {
    run run_agentsync sync
    [ "$status" -eq 0 ]
    local count
    count=$(ls -1 .cursor/rules/*.mdc 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" -ge 1 ]
}

@test "sync Cursor rules have globs frontmatter" {
    run run_agentsync sync
    [ "$status" -eq 0 ]
    local first_mdc
    first_mdc=$(ls .cursor/rules/*.mdc | head -1)
    grep -q "alwaysApply: true" "$first_mdc"
}

# ── GitHub Copilot ───────────────────────────────────────────────────────────

@test "sync creates Copilot instructions" {
    run run_agentsync sync
    [ "$status" -eq 0 ]
    [ -f ".github/copilot-instructions.md" ]
}

@test "sync creates Copilot .instructions.md rules" {
    run run_agentsync sync
    [ "$status" -eq 0 ]
    local count
    count=$(ls -1 .github/instructions/*.instructions.md 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" -ge 1 ]
}

@test "sync Copilot rules have applyTo frontmatter" {
    run run_agentsync sync
    [ "$status" -eq 0 ]
    local first
    first=$(ls .github/instructions/*.instructions.md | head -1)
    grep -q "applyTo:" "$first"
}

# ── Windsurf ─────────────────────────────────────────────────────────────────

@test "sync creates Windsurf AGENTS.md" {
    run run_agentsync sync
    [ "$status" -eq 0 ]
    [ -f ".windsurf/AGENTS.md" ]
}

@test "sync Windsurf rules have trigger frontmatter" {
    run run_agentsync sync
    [ "$status" -eq 0 ]
    local first
    first=$(ls .windsurf/rules/*.md | head -1)
    grep -q "trigger: always_on" "$first"
}

# ── Gemini ───────────────────────────────────────────────────────────────────

@test "sync creates Gemini GEMINI.md" {
    run run_agentsync sync
    [ "$status" -eq 0 ]
    [ -f ".gemini/GEMINI.md" ]
}

@test "sync Gemini inlines rules into GEMINI.md" {
    run run_agentsync sync
    [ "$status" -eq 0 ]
    grep -q "Rules" .gemini/GEMINI.md
}

# ── OpenAI Codex ─────────────────────────────────────────────────────────────

@test "sync creates Codex AGENTS.md at root" {
    run run_agentsync sync
    [ "$status" -eq 0 ]
    [ -f "AGENTS.md" ]
}

# ── Filtering ────────────────────────────────────────────────────────────────

@test "sync --only filters tools" {
    run run_agentsync sync --only claude
    [ "$status" -eq 0 ]
    [ -f ".claude/CLAUDE.md" ]
    [ ! -f ".cursor/AGENTS.md" ]
}

@test "sync --skip excludes tools" {
    run run_agentsync sync --skip claude
    [ "$status" -eq 0 ]
    [ ! -f ".claude/CLAUDE.md" ]
    [ -f ".cursor/AGENTS.md" ]
}

@test "sync --only multiple tools" {
    run run_agentsync sync --only claude,cursor
    [ "$status" -eq 0 ]
    [ -f ".claude/CLAUDE.md" ]
    [ -f ".cursor/AGENTS.md" ]
    [ ! -f ".github/copilot-instructions.md" ]
}

# ── Dry run ──────────────────────────────────────────────────────────────────

@test "sync --dry-run does not create files" {
    run run_agentsync sync --dry-run
    [ "$status" -eq 0 ]
    [ ! -f ".claude/CLAUDE.md" ]
    [ ! -f ".cursor/AGENTS.md" ]
    [[ "$output" == *"dry-run"* ]]
}

# ── Disabled tools ───────────────────────────────────────────────────────────

@test "sync skips disabled tools" {
    # Disable Claude
    sed -i.bak 's/^enabled: true$/enabled: false/' .ai/src/tools/claude.yaml
    run run_agentsync sync --only claude
    [ "$status" -eq 0 ]
    [ ! -f ".claude/CLAUDE.md" ]
}

@test "sync cleans up when tool is disabled" {
    # First sync with Claude enabled
    run run_agentsync sync --only claude
    [ -f ".claude/CLAUDE.md" ]

    # Disable Claude
    sed -i.bak 's/^enabled: true$/enabled: false/' .ai/src/tools/claude.yaml
    run run_agentsync sync
    [ "$status" -eq 0 ]
    [ ! -f ".claude/CLAUDE.md" ]
}

# ── Gitignore ────────────────────────────────────────────────────────────────

@test "sync updates .gitignore with markers" {
    run run_agentsync sync
    [ "$status" -eq 0 ]
    grep -q "AI SYNC GENERATED START" .gitignore
    grep -q "AI SYNC GENERATED END" .gitignore
}

@test "sync preserves existing .gitignore content" {
    echo "node_modules/" > .gitignore
    run run_agentsync sync
    [ "$status" -eq 0 ]
    grep -q "node_modules/" .gitignore
    grep -q "AI SYNC GENERATED START" .gitignore
}

@test "sync updates gitignore block on re-sync" {
    run run_agentsync sync
    run run_agentsync sync
    [ "$status" -eq 0 ]
    # Should have exactly one start marker
    local count
    count=$(grep -c "AI SYNC GENERATED START" .gitignore)
    [ "$count" -eq 1 ]
}

# ── Idempotency ──────────────────────────────────────────────────────────────

@test "sync is idempotent" {
    run run_agentsync sync
    [ "$status" -eq 0 ]
    local hash1
    hash1=$(find . -not -path './.git/*' -type f -exec md5sum {} \; 2>/dev/null | sort || \
            find . -not -path './.git/*' -type f -exec md5 {} \; 2>/dev/null | sort)

    run run_agentsync sync
    [ "$status" -eq 0 ]
    local hash2
    hash2=$(find . -not -path './.git/*' -type f -exec md5sum {} \; 2>/dev/null | sort || \
            find . -not -path './.git/*' -type f -exec md5 {} \; 2>/dev/null | sort)

    [ "$hash1" = "$hash2" ]
}

# ── Content integrity ────────────────────────────────────────────────────────

@test "sync CLAUDE.md contains AGENTS.md content" {
    run run_agentsync sync
    [ "$status" -eq 0 ]
    # First line of source should appear in output
    local first_heading
    first_heading=$(grep "^#" .ai/src/AGENTS.md | head -1)
    grep -qF "$first_heading" .claude/CLAUDE.md
}

@test "sync copies settings.json for Claude" {
    # Create settings source
    mkdir -p .ai/src/settings
    echo '{"permissions":{"allow":["Read"]}}' > .ai/src/settings/claude.json
    run run_agentsync sync --only claude
    [ "$status" -eq 0 ]
    [ -f ".claude/settings.json" ]
    grep -q "permissions" .claude/settings.json
}
