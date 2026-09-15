#!/usr/bin/env bats
# Engine-owned skills: content documenting AgentSync itself is resolved from
# the install dir at sync time, so upgrading the engine updates it in every
# project. A project copy still wins, and `base_skills: false` opts out.

load test_helper

setup() {
    setup_test_project
    run_agentsync init --tools claude --yes >/dev/null 2>&1
}

teardown() {
    teardown_test_project
}

set_config() {
    printf '%s\n' "$1" >> .ai/agent_sync.yaml
}

@test "base skills: the agentsync skill reaches outputs without living in .ai/src/" {
    [ ! -d .ai/src/skills/agentsync ]
    [ -f .claude/skills/agentsync/SKILL.md ]
    grep -q "AgentSync" .claude/skills/agentsync/SKILL.md
}

@test "base skills: init no longer scaffolds it as project content" {
    run_agentsync sync --force >/dev/null 2>&1
    [ ! -d .ai/src/skills/agentsync ]
}

@test "base skills: nested reference files come along" {
    [ -f .claude/skills/agentsync/references/writing-skills.md ]
    [ -f .claude/skills/agentsync/references/maintenance.md ]
}

@test "base skills: it is a tracked output like any other" {
    grep -q "^.claude/skills/agentsync/SKILL.md"$'\t' .ai/.sync-manifest
}

@test "base skills: the project's own copy wins" {
    mkdir -p .ai/src/skills/agentsync
    printf -- '---\nname: agentsync\ndescription: Project version\n---\n\nPROJECT OVERRIDE\n' \
        > .ai/src/skills/agentsync/SKILL.md
    run_agentsync sync --force >/dev/null 2>&1
    grep -q "PROJECT OVERRIDE" .claude/skills/agentsync/SKILL.md
}

@test "base skills: base_skills false leaves it out entirely" {
    set_config "base_skills: false"
    run_agentsync sync --force >/dev/null 2>&1
    [ ! -d .claude/skills/agentsync ]
}

@test "base skills: the project's other skills are untouched" {
    [ -d .ai/src/skills/commit ]
    [ -f .claude/skills/commit/SKILL.md ]
}

@test "base skills: shared inheritance preserves child and parent skills together" {
    mkdir -p .ai/src/skills/child-only shared/.ai/src/skills/parent-only
    printf 'child skill\n' > .ai/src/skills/child-only/SKILL.md
    printf 'parent skill\n' > shared/.ai/src/skills/parent-only/SKILL.md
    set_config $'shared:\n  path: shared\n  inherit: skills'

    run run_agentsync sync
    [ "$status" -eq 0 ]
    [ "$(cat .claude/skills/child-only/SKILL.md)" = "child skill" ]
    [ "$(cat .claude/skills/parent-only/SKILL.md)" = "parent skill" ]
    [ -f .claude/skills/agentsync/SKILL.md ]
}

@test "base skills: a second sync is byte-identical (no drift)" {
    local before
    before=$(file_sha256 .claude/skills/agentsync/SKILL.md)
    run run_agentsync sync
    [ "$status" -eq 0 ]
    local after
    after=$(file_sha256 .claude/skills/agentsync/SKILL.md)
    [ "$before" = "$after" ]
}

@test "base skills: check stays green with the layer active" {
    run run_agentsync check
    [ "$status" -eq 0 ]
}

@test "base skills: removing the engine skill from a project prunes the output" {
    [ -f .claude/skills/agentsync/SKILL.md ]
    set_config "base_skills: false"
    run_agentsync sync --force >/dev/null 2>&1
    [ ! -f .claude/skills/agentsync/SKILL.md ]
}

@test "base skills: the overlay leaves no temp directory behind" {
    local sandbox="$TEST_PROJECT/tmpdir_sandbox"
    mkdir -p "$sandbox"
    TMPDIR="$sandbox" run_agentsync sync --force >/dev/null 2>&1
    [ -z "$(ls -A "$sandbox" 2>/dev/null)" ]
}
