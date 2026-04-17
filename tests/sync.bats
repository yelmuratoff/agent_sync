#!/usr/bin/env bats
# Tests for agentsync sync.
# Uses setup_file/teardown_file — init+sync runs ONCE, all tests are readonly checks.

load test_helper

setup_file() {
    export SYNC_PROJECT="$(mktemp -d "${TMPDIR:-/tmp}/agentsync_sync_test.XXXXXX")"
    cd "$SYNC_PROJECT"
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"

    # Init + full sync once
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init
    echo "node_modules/" > .gitignore

    # Tests assert sync output for these tools — enable explicitly.
    # init defaults all tools to disabled; users opt in per project.
    enable_tools claude cursor copilot windsurf gemini codex amazonq zed continue junie antigravity

    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync
}

teardown_file() {
    [[ -n "${SYNC_PROJECT:-}" ]] && rm -rf "$SYNC_PROJECT"
}

setup() {
    cd "$SYNC_PROJECT"
}

# ── Claude Code ──────────────────────────────────────────────────────────────

@test "sync: Claude CLAUDE.md exists" {
    [ -f ".claude/CLAUDE.md" ]
}

@test "sync: Claude rules exist" {
    [ -d ".claude/rules" ]
    local count
    count=$(ls -1 .claude/rules/*.md 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" -ge 1 ]
}

@test "sync: Claude skills exist" {
    [ -d ".claude/skills" ]
}

@test "sync: Claude commands exist" {
    [ -d ".claude/commands" ]
}

@test "sync: Claude agents exist" {
    [ -d ".claude/agents" ]
}

@test "sync: Claude CLAUDE.md contains AGENTS.md content" {
    local first_heading
    first_heading=$(grep "^#" .ai/src/AGENTS.md | head -1)
    grep -qF "$first_heading" .claude/CLAUDE.md
}

# ── Cursor ───────────────────────────────────────────────────────────────────

@test "sync: Cursor AGENTS.md exists at root" {
    [ -f "AGENTS.md" ]
}

@test "sync: Cursor .mdc rules exist" {
    local count
    count=$(ls -1 .cursor/rules/*.mdc 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" -ge 1 ]
}

@test "sync: Cursor rules have globs frontmatter" {
    local first_mdc
    first_mdc=$(ls .cursor/rules/*.mdc | head -1)
    grep -q "alwaysApply: true" "$first_mdc"
}

# ── GitHub Copilot ───────────────────────────────────────────────────────────

@test "sync: Copilot instructions exist" {
    [ -f ".github/copilot-instructions.md" ]
}

@test "sync: Copilot .instructions.md rules exist" {
    local count
    count=$(ls -1 .github/instructions/*.instructions.md 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" -ge 1 ]
}

@test "sync: Copilot rules have applyTo frontmatter" {
    local first
    first=$(ls .github/instructions/*.instructions.md | head -1)
    grep -q "applyTo:" "$first"
}

# ── Windsurf ─────────────────────────────────────────────────────────────────

@test "sync: Windsurf AGENTS.md exists at root" {
    [ -f "AGENTS.md" ]
}

@test "sync: Windsurf rules have trigger frontmatter" {
    local first
    first=$(ls .windsurf/rules/*.md | head -1)
    grep -q "trigger: always_on" "$first"
}

# ── Gemini ───────────────────────────────────────────────────────────────────

@test "sync: Gemini GEMINI.md exists" {
    [ -f ".gemini/GEMINI.md" ]
}

@test "sync: Gemini inlines rules into GEMINI.md" {
    grep -q "Rules" .gemini/GEMINI.md
}

# ── Codex ────────────────────────────────────────────────────────────────────

@test "sync: Codex AGENTS.md at root exists" {
    [ -f "AGENTS.md" ]
}

# ── Hooks (per-tool) ─────────────────────────────────────────────────────────

@test "sync: Cursor hooks.json exists" {
    [ -f ".cursor/hooks.json" ]
}

@test "sync: Codex hooks.json exists" {
    [ -f ".codex/hooks.json" ]
}

@test "sync: Copilot hooks.json exists" {
    [ -f ".github/hooks/hooks.json" ]
}

@test "sync: Windsurf hooks.json exists" {
    [ -f ".windsurf/hooks.json" ]
}

# ── MCP / settings (per-tool) ────────────────────────────────────────────────

@test "sync: Claude .mcp.json exists" {
    [ -f ".claude/.mcp.json" ]
}

@test "sync: Cursor mcp.json exists" {
    [ -f ".cursor/mcp.json" ]
}

@test "sync: Windsurf mcp_config.json exists" {
    [ -f ".windsurf/mcp_config.json" ]
}

@test "sync: Amazon Q mcp.json exists" {
    [ -f ".amazonq/mcp.json" ]
}

@test "sync: Gemini settings.json exists" {
    [ -f ".gemini/settings.json" ]
}

@test "sync: Zed settings.json exists" {
    [ -f ".zed/settings.json" ]
}

@test "sync: Continue config.yaml exists" {
    [ -f ".continue/config.yaml" ]
}

# ── Tool-specific assertions for less-common tools ───────────────────────────

@test "sync: Junie AGENTS.md exists and rules are inlined" {
    [ -f ".junie/AGENTS.md" ]
    # rules were inlined — no unsupported .junie/rules/ subdirectory
    [ ! -d ".junie/rules" ]
}

# ── Gitignore ────────────────────────────────────────────────────────────────

@test "sync: .gitignore has sync markers" {
    grep -q "AI SYNC GENERATED START" .gitignore
    grep -q "AI SYNC GENERATED END" .gitignore
}

@test "sync: .gitignore preserves existing content" {
    grep -q "node_modules/" .gitignore
}

@test "sync: .gitignore has exactly one marker block" {
    local count
    count=$(grep -c "AI SYNC GENERATED START" .gitignore)
    [ "$count" -eq 1 ]
}
