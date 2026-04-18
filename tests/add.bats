#!/usr/bin/env bats
# Tests for agentsync add <kind> <name>.

load test_helper

setup() {
    setup_test_project
    run_agentsync init >/dev/null
}

teardown() {
    teardown_test_project
}

# ── Happy paths ───────────────────────────────────────────────────────────────

@test "add rule creates .ai/src/rules/<name>.md" {
    run run_agentsync add rule testing
    [ "$status" -eq 0 ]
    [ -f ".ai/src/rules/testing.md" ]
    grep -q "^# testing$" .ai/src/rules/testing.md
}

@test "add skill creates .ai/src/skills/<name>/SKILL.md" {
    run run_agentsync add skill deploy
    [ "$status" -eq 0 ]
    [ -f ".ai/src/skills/deploy/SKILL.md" ]
    grep -q "^name: deploy$" .ai/src/skills/deploy/SKILL.md
    grep -q "^description:" .ai/src/skills/deploy/SKILL.md
}

@test "add command creates .ai/src/commands/<name>.md with description frontmatter" {
    run run_agentsync add command deploy
    [ "$status" -eq 0 ]
    [ -f ".ai/src/commands/deploy.md" ]
    grep -q "^description:" .ai/src/commands/deploy.md
}

@test "add subagent creates .ai/src/agents/<name>.md" {
    run run_agentsync add subagent reviewer
    [ "$status" -eq 0 ]
    [ -f ".ai/src/agents/reviewer.md" ]
    grep -q "^name: reviewer$" .ai/src/agents/reviewer.md
    grep -q "^model:" .ai/src/agents/reviewer.md
}

@test "add prints next-step hint" {
    run run_agentsync add rule testing
    [ "$status" -eq 0 ]
    [[ "$output" == *"agentsync sync"* ]]
}

# ── Rejections ────────────────────────────────────────────────────────────────

@test "add with no args fails with usage" {
    run run_agentsync add
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
    [[ "$output" == *"<kind>"* ]]
}

@test "add with only kind fails with usage" {
    run run_agentsync add rule
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
}

@test "add rejects unknown kind" {
    run run_agentsync add banana myname
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown kind"* ]]
}

@test "add rejects name with slash" {
    run run_agentsync add rule "sub/dir"
    [ "$status" -ne 0 ]
    [[ "$output" == *"path separators"* ]]
    [ ! -e ".ai/src/rules/sub" ]
}

@test "add rejects name with .." {
    run run_agentsync add rule "..evil"
    [ "$status" -ne 0 ]
    [[ "$output" == *"'..'"* ]] || [[ "$output" == *"cannot start with"* ]]
}

@test "add rejects name with relative traversal" {
    run run_agentsync add rule "../evil"
    [ "$status" -ne 0 ]
    [[ "$output" == *"path separators"* ]]
}

@test "add rejects name starting with dot" {
    run run_agentsync add rule ".hidden"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot start with"* ]]
}

@test "add rejects name with space" {
    run run_agentsync add rule "my rule"
    [ "$status" -ne 0 ]
    [[ "$output" == *"letters, digits"* ]]
}

@test "add rejects name with extension" {
    run run_agentsync add rule "testing.md"
    [ "$status" -ne 0 ]
    [[ "$output" == *"letters, digits"* ]]
}

# ── Existing-file behavior ────────────────────────────────────────────────────

@test "add refuses existing file without --force" {
    run_agentsync add rule testing >/dev/null
    run run_agentsync add rule testing
    [ "$status" -ne 0 ]
    [[ "$output" == *"Already exists"* ]]
    [[ "$output" == *"--force"* ]]
}

@test "add --force overwrites existing file" {
    run_agentsync add rule testing >/dev/null
    echo "custom content" > .ai/src/rules/testing.md

    run run_agentsync add --force rule testing
    [ "$status" -eq 0 ]
    ! grep -q "custom content" .ai/src/rules/testing.md
    grep -q "^# testing$" .ai/src/rules/testing.md
}

@test "add --force works with -f short flag" {
    run_agentsync add rule testing >/dev/null
    run run_agentsync add -f rule testing
    [ "$status" -eq 0 ]
}

@test "add refuses existing skill directory without --force" {
    run_agentsync add skill deploy >/dev/null
    run run_agentsync add skill deploy
    [ "$status" -ne 0 ]
    [[ "$output" == *"Already exists"* ]]
}

# ── Name-shape sanity ─────────────────────────────────────────────────────────

@test "add accepts kebab-case name" {
    run run_agentsync add rule "my-rule"
    [ "$status" -eq 0 ]
    [ -f ".ai/src/rules/my-rule.md" ]
}

@test "add accepts snake_case name" {
    run run_agentsync add rule "my_rule"
    [ "$status" -eq 0 ]
    [ -f ".ai/src/rules/my_rule.md" ]
}

@test "add accepts digits in name" {
    run run_agentsync add rule "rule42"
    [ "$status" -eq 0 ]
    [ -f ".ai/src/rules/rule42.md" ]
}

@test "add substitutes name into skill frontmatter" {
    run run_agentsync add skill my-skill
    [ "$status" -eq 0 ]
    grep -q "^name: my-skill$" .ai/src/skills/my-skill/SKILL.md
    grep -q "^# my-skill$" .ai/src/skills/my-skill/SKILL.md
}
