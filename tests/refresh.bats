#!/usr/bin/env bats
# Tests for agentsync refresh.

load test_helper

setup() {
    setup_test_project
    run run_agentsync init --yes --no-detect --content rules,skills,commands,subagents
    [ "$status" -eq 0 ]
}

teardown() {
    teardown_test_project
}

@test "refresh: --help prints usage" {
    run run_agentsync refresh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"agentsync refresh"* ]]
    [[ "$output" == *"--only"* ]]
    [[ "$output" == *"--include-agents-md"* ]]
    [[ "$output" == *"--dry-run"* ]]
}

@test "refresh: errors when no .ai/ directory" {
    rm -rf .ai
    run run_agentsync refresh --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"No .ai/"* ]]
}

@test "refresh: --yes adds missing template files" {
    rm -f .ai/src/rules/comments.md
    run run_agentsync refresh --yes
    [ "$status" -eq 0 ]
    [ -f .ai/src/rules/comments.md ]
}

@test "refresh: --yes keeps user-modified file untouched (conflict skipped)" {
    echo "USER LOCAL EDIT" >> .ai/src/rules/core.md
    local before
    before=$(cat .ai/src/rules/core.md)
    run run_agentsync refresh --yes
    [ "$status" -eq 0 ]
    [ "$(cat .ai/src/rules/core.md)" = "$before" ]
    [[ "$output" == *"conflict"* ]]
}

@test "refresh: --dry-run does not write" {
    rm -f .ai/src/rules/comments.md
    run run_agentsync refresh --dry-run
    [ "$status" -eq 0 ]
    [ ! -f .ai/src/rules/comments.md ]
    [[ "$output" == *"Dry run"* ]]
}

@test "refresh: --only filters by category" {
    rm -f .ai/src/rules/comments.md
    rm -rf .ai/src/skills/comments
    run run_agentsync refresh --yes --only rules
    [ "$status" -eq 0 ]
    [ -f .ai/src/rules/comments.md ]
    [ ! -d .ai/src/skills/comments ]
}

@test "refresh: --only subagents alias maps to agents dir" {
    rm -rf .ai/src/agents
    run run_agentsync refresh --yes --only subagents
    [ "$status" -eq 0 ]
    [ -d .ai/src/agents ]
}

@test "refresh: rejects unknown --only value" {
    run run_agentsync refresh --yes --only bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown --only"* ]]
}

@test "refresh: idempotent — second run reports up to date" {
    run run_agentsync refresh --yes
    [ "$status" -eq 0 ]
    run run_agentsync refresh --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"Already up to date"* ]]
}

@test "refresh: AGENTS.md excluded by default" {
    echo "USER LOCAL EDIT" >> .ai/src/AGENTS.md
    local before
    before=$(cat .ai/src/AGENTS.md)
    run run_agentsync refresh --yes
    [ "$status" -eq 0 ]
    [ "$(cat .ai/src/AGENTS.md)" = "$before" ]
}

@test "refresh: --include-agents-md surfaces AGENTS.md but --yes still skips conflict" {
    echo "USER LOCAL EDIT" >> .ai/src/AGENTS.md
    local before
    before=$(cat .ai/src/AGENTS.md)
    run run_agentsync refresh --yes --include-agents-md
    [ "$status" -eq 0 ]
    [[ "$output" == *"AGENTS.md"* ]]
    [ "$(cat .ai/src/AGENTS.md)" = "$before" ]
}

@test "refresh: non-TTY without --yes errors with hint" {
    rm -f .ai/src/rules/comments.md
    run run_agentsync refresh
    [ "$status" -ne 0 ]
    [[ "$output" == *"--yes"* ]]
}

@test "refresh: leaves user's custom files alone (not in templates)" {
    cat > .ai/src/rules/my-custom.md <<'EOF'
# My Custom Rule
Custom content.
EOF
    run run_agentsync refresh --yes
    [ "$status" -eq 0 ]
    [ -f .ai/src/rules/my-custom.md ]
    grep -q "My Custom Rule" .ai/src/rules/my-custom.md
}

@test "refresh: scope auto-detection skips categories absent from .ai/src/" {
    rm -rf .ai/src/commands .ai/src/agents
    run run_agentsync refresh --yes
    [ "$status" -eq 0 ]
    # commands and agents weren't in scope (absent) — still absent after refresh
    [ ! -d .ai/src/commands ]
    [ ! -d .ai/src/agents ]
    # rules and skills were in scope and are unchanged
    [ -f .ai/src/rules/core.md ]
    [ -d .ai/src/skills ]
}

@test "refresh: explicit --only opts into a category not yet in tree" {
    rm -rf .ai/src/commands
    run run_agentsync refresh --yes --only commands
    [ "$status" -eq 0 ]
    [ -d .ai/src/commands ]
    # At least one template command file should now exist
    local count
    count=$(ls -1 .ai/src/commands/*.md 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" -ge 1 ]
}

@test "refresh: errors when no source categories present and no --only" {
    rm -rf .ai/src/rules .ai/src/skills .ai/src/commands .ai/src/agents
    run run_agentsync refresh --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"No source content categories"* ]]
}

@test "refresh: --only=value form (= separator)" {
    rm -f .ai/src/rules/comments.md
    rm -rf .ai/src/skills/comments
    run run_agentsync refresh --yes --only=rules
    [ "$status" -eq 0 ]
    [ -f .ai/src/rules/comments.md ]
    [ ! -d .ai/src/skills/comments ]
}

@test "refresh: nested skill references files appear as new" {
    rm -rf .ai/src/skills/agentsync/references
    run run_agentsync refresh --yes
    [ "$status" -eq 0 ]
    # Templates ship references/maintenance.md and references/writing-skills.md;
    # at least one should land back via refresh.
    [ -f .ai/src/skills/agentsync/references/maintenance.md ] || \
    [ -f .ai/src/skills/agentsync/references/writing-skills.md ]
}
