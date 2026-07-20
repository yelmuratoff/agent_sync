#!/usr/bin/env bats
# Tests for agentsync sync.
# Uses setup_file/teardown_file — init+sync runs ONCE against a shared fixture.
# A few tests intentionally re-run sync, so tests within this file must not race.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load test_helper

setup_file() {
    export SYNC_PROJECT="$(mktemp -d "${TMPDIR:-/tmp}/agentsync_sync_test.XXXXXX")"
    cd "$SYNC_PROJECT"
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"

    # Init + full sync once. Minimal init; sync falls back to base templates
    # for hooks/mcp/settings when project overrides are absent (Phase 2).
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init
    echo "node_modules/" > .gitignore

    # Tests assert sync output for these tools — enable explicitly.
    # init defaults all tools to disabled; users opt in per project.
    enable_tools claude cursor copilot windsurf gemini codex amazonq zed junie antigravity kimi opencode

    # Path-scoped rule (leads with YAML frontmatter) — regression fixture for the
    # inline-into-agents rule inventory title extraction.
    printf '%s\n' '---' 'paths:' '  - "**/*.dart"' '---' '' '# Scoped Fixture Rule' '' '- Body.' \
        > .ai/src/rules/scoped-fixture.md

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
    [ -f "CLAUDE.md" ]
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
    grep -qF "$first_heading" CLAUDE.md
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

@test "sync: Gemini GEMINI.md exists at root" {
    [ -f "GEMINI.md" ]
}

@test "sync: Gemini inlines rules into GEMINI.md" {
    grep -q "Rules" GEMINI.md
}

# ── Codex ────────────────────────────────────────────────────────────────────

@test "sync: Codex AGENTS.md at root exists" {
    [ -f "AGENTS.md" ]
}

@test "sync: Codex skills directory exists" {
    [ -d ".agents/skills" ]
}

@test "sync: Codex commands rendered as generated skills (command-*)" {
    [ -d ".agents/skills/command-fix-issue" ]
    [ -d ".agents/skills/command-review" ]
    [ -f ".agents/skills/command-fix-issue/SKILL.md" ]
}

@test "sync: Codex generated skill carries command-prefixed name and copies description" {
    grep -q '^name: "command-fix-issue"$' ".agents/skills/command-fix-issue/SKILL.md"
    grep -q 'Investigate and fix a GitHub issue' ".agents/skills/command-fix-issue/SKILL.md"
}

@test "sync: Codex generated skill strips \$ARGUMENTS and !\` slash-command sugar" {
    ! grep -qF '$ARGUMENTS' ".agents/skills/command-fix-issue/SKILL.md"
    ! grep -qF '!`' ".agents/skills/command-fix-issue/SKILL.md"
}

@test "sync: Codex generated skills do not collide with native skills" {
    # Native skill 'review' coexists with generated 'command-review'.
    [ -d ".agents/skills/review" ]
    [ -d ".agents/skills/command-review" ]
}

@test "sync: Codex repeat sync is idempotent (no command-* sweep)" {
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null 2>&1
    [ -d ".agents/skills/command-fix-issue" ]
    [ -d ".agents/skills/command-review" ]
}

# ── Kimi Code ────────────────────────────────────────────────────────────────

@test "sync: Kimi Code emits native skills and command skills" {
    [ -f ".kimi-code/AGENTS.md" ]
    grep -q '^## Rules$' ".kimi-code/AGENTS.md"
    [ -d ".kimi-code/skills" ]
    [ -f ".kimi-code/skills/command-review/SKILL.md" ]
}

@test "sync: Kimi Code emits project MCP config" {
    [ -f ".kimi-code/mcp.json" ]
    grep -q '"mcpServers"' ".kimi-code/mcp.json"
}

# ── OpenCode ─────────────────────────────────────────────────────────────────

@test "sync: OpenCode emits native skills and commands" {
    [ -d ".opencode/skills" ]
    [ -f ".opencode/commands/review.md" ]
}

@test "sync: OpenCode converts portable subagents safely" {
    [ -f ".opencode/agents/code-reviewer.md" ]
    grep -q '^mode: subagent$' ".opencode/agents/code-reviewer.md"
    grep -q '^  "\*": deny$' ".opencode/agents/code-reviewer.md"
    grep -q '^  "read": allow$' ".opencode/agents/code-reviewer.md"
}

@test "sync: OpenCode emits project settings" {
    [ -f "opencode.json" ]
    grep -q 'https://opencode.ai/config.json' "opencode.json"
}

@test "sync: OpenCode emits the managed native plugin" {
    [ -f ".opencode/plugins/agentsync.ts" ]
    grep -q 'AgentSyncHooks' ".opencode/plugins/agentsync.ts"
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
    [ -f ".mcp.json" ]
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

@test "sync: Amazon Q AGENTS.md gets ## Commands inline section" {
    grep -q '^## Commands$' ".amazonq/rules/00-context.md"
    grep -q '^- `/fix-issue` —' ".amazonq/rules/00-context.md"
}

@test "sync: Zed .rules gets ## Commands inline section (merge_to_file fallback)" {
    grep -q '^## Commands$' ".rules"
    grep -q '^- `/fix-issue` —' ".rules"
}

@test "sync: Gemini settings.json exists" {
    [ -f ".gemini/settings.json" ]
}

@test "sync: Zed settings.json exists" {
    [ -f ".zed/settings.json" ]
}

# ── Tool-specific assertions for less-common tools ───────────────────────────

@test "sync: Junie AGENTS.md exists and rules are inlined" {
    [ -f ".junie/AGENTS.md" ]
    # rules were inlined — no unsupported .junie/rules/ subdirectory
    [ ! -d ".junie/rules" ]
}

@test "sync: inlined rule inventory shows heading, not frontmatter delimiter" {
    # A path-scoped rule opens with a `---` frontmatter block; the shared
    # inline-into-agents inventory must surface its heading, not the `---`
    # delimiter. Asserted on .junie/AGENTS.md (uniquely owned — the root
    # AGENTS.md is contended by several tools depending on sync order).
    grep -q '^- `scoped-fixture.md` — Scoped Fixture Rule$' ".junie/AGENTS.md"
    ! grep -q '`scoped-fixture.md` — ---' ".junie/AGENTS.md"
}

# ── Path-scoped rules: canonical `paths:` → each tool's native glob trigger ───

@test "sync: path-scoped rule keeps native paths: for Claude" {
    grep -q '^paths:' ".claude/rules/scoped-fixture.md"
    grep -qF '"**/*.dart"' ".claude/rules/scoped-fixture.md"
}

@test "sync: path-scoped rule becomes Cursor Auto Attached glob" {
    grep -qF "globs: '**/*.dart'" ".cursor/rules/scoped-fixture.mdc"
    grep -qF "alwaysApply: false" ".cursor/rules/scoped-fixture.mdc"
}

@test "sync: path-scoped rule becomes Copilot applyTo glob" {
    grep -qF "applyTo: '**/*.dart'" ".github/instructions/scoped-fixture.instructions.md"
}

@test "sync: path-scoped rule becomes Windsurf glob trigger" {
    grep -qF "trigger: glob" ".windsurf/rules/scoped-fixture.md"
    grep -qF "globs: '**/*.dart'" ".windsurf/rules/scoped-fixture.md"
}

@test "sync: path-scoped rule becomes Antigravity glob trigger" {
    grep -qF "trigger: glob" ".agents/rules/scoped-fixture.md"
    grep -qF "globs: '**/*.dart'" ".agents/rules/scoped-fixture.md"
}

@test "sync: rule without paths: stays always-on (Cursor)" {
    # core.md has no `paths:` — must keep the always-on default, not a glob.
    grep -qF "alwaysApply: true" ".cursor/rules/core.mdc"
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

# ── Re-sync stability (finding 5: shared-dest / nested-agents churn) ──────────

@test "sync: re-sync emits no churn for shared-dest command-* or nested agents" {
    # A second sync must not warn "Kept" for Codex-generated
    # .agents/skills/command-* (which Antigravity's skills step sweeps because
    # both tools share .agents/skills), nor "Removed" the nested AGENTS file
    # .amazonq/rules/00-context.md (written by the agents step, then swept by the
    # rules step) only to re-copy it every run.
    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync
    [ "$status" -eq 0 ]
    [[ "$output" != *"Kept .agents/skills/command-"* ]]
    [[ "$output" != *"Removed: .amazonq/rules/00-context.md"* ]]
}
