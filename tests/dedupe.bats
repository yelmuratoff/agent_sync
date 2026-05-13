#!/usr/bin/env bats
# Tests for agentsync dedupe.

load test_helper

setup() {
    setup_test_project
}

teardown() {
    teardown_test_project
}

# Build a parent project with one rule + one skill, and a child below it that
# has the SAME files (identical hash). Echoes "<parent_dir> <child_dir>".
_dedupe_make_parent_child_identical() {
    local parent_dir="$TEST_PROJECT/parent"
    local child_dir="$parent_dir/child"
    mkdir -p "$parent_dir"
    ( cd "$parent_dir" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect >/dev/null )
    echo "shared rule" > "$parent_dir/.ai/src/rules/shared.md"
    mkdir -p "$parent_dir/.ai/src/skills/foo"
    echo "shared skill" > "$parent_dir/.ai/src/skills/foo/SKILL.md"

    mkdir -p "$child_dir"
    ( cd "$child_dir" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect >/dev/null )
    cp "$parent_dir/.ai/src/rules/shared.md" "$child_dir/.ai/src/rules/shared.md"
    mkdir -p "$child_dir/.ai/src/skills/foo"
    cp "$parent_dir/.ai/src/skills/foo/SKILL.md" "$child_dir/.ai/src/skills/foo/SKILL.md"

    echo "$parent_dir $child_dir"
}

@test "dedupe requires TTY without --yes" {
    _dedupe_make_parent_child_identical >/dev/null
    run bash -c "cd '$TEST_PROJECT/parent/child' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' dedupe </dev/null"
    [ "$status" -ne 0 ]
    [[ "$output" == *"interactive TTY"* ]]
}

@test "dedupe --yes deletes identical-hash files and prunes empty skill dirs" {
    local pair
    pair=$(_dedupe_make_parent_child_identical)
    local child="${pair##* }"

    run bash -c "cd '$child' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' dedupe --yes"
    [ "$status" -eq 0 ]
    [[ "$output" == *"rules/shared.md"* ]]
    [[ "$output" == *"skills/foo/SKILL.md"* ]]
    [ ! -f "$child/.ai/src/rules/shared.md" ]
    [ ! -f "$child/.ai/src/skills/foo/SKILL.md" ]
    # Skill dir pruned after losing its only file.
    [ ! -d "$child/.ai/src/skills/foo" ]
}

@test "dedupe leaves divergent files untouched even with --yes" {
    local parent_dir="$TEST_PROJECT/parent"
    local child_dir="$parent_dir/child"
    mkdir -p "$parent_dir"
    ( cd "$parent_dir" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect >/dev/null )
    echo "parent version" > "$parent_dir/.ai/src/rules/shared.md"
    mkdir -p "$child_dir"
    ( cd "$child_dir" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect >/dev/null )
    echo "child version" > "$child_dir/.ai/src/rules/shared.md"

    run bash -c "cd '$child_dir' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' dedupe --yes"
    [ "$status" -eq 0 ]
    [[ "$output" == *"divergent"* ]] || [[ "$output" == *"Divergent: 1"* ]]
    [ -f "$child_dir/.ai/src/rules/shared.md" ]
    grep -q "child version" "$child_dir/.ai/src/rules/shared.md"
}

@test "dedupe --yes adds template-derived dupe to template_overrides.declined" {
    # Use a real shipped template name so the file matches the template set.
    local parent_dir="$TEST_PROJECT/parent"
    local child_dir="$parent_dir/child"
    mkdir -p "$parent_dir"
    ( cd "$parent_dir" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect >/dev/null )
    # Overwrite the shipped comments.md in parent with a stable test value.
    echo "comments rule" > "$parent_dir/.ai/src/rules/comments.md"

    mkdir -p "$child_dir"
    ( cd "$child_dir" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect >/dev/null )
    cp "$parent_dir/.ai/src/rules/comments.md" "$child_dir/.ai/src/rules/comments.md"

    run bash -c "cd '$child_dir' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' dedupe --yes"
    [ "$status" -eq 0 ]
    [ ! -f "$child_dir/.ai/src/rules/comments.md" ]
    grep -q "^  declined:" "$child_dir/.ai/agent_sync.yaml"
    grep -q "rules/comments.md" "$child_dir/.ai/agent_sync.yaml"
}

@test "dedupe --yes does NOT add non-template duplicate to declined" {
    local pair
    pair=$(_dedupe_make_parent_child_identical)
    local child="${pair##* }"

    run bash -c "cd '$child' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' dedupe --yes"
    [ "$status" -eq 0 ]
    # rules/shared.md is NOT a shipped template — must not be added to declined.
    ! grep -q "rules/shared.md" "$child/.ai/agent_sync.yaml" || false
}

@test "dedupe --against PATH compares against an explicit tree" {
    local parent_dir="$TEST_PROJECT/parent"
    local child_dir="$TEST_PROJECT/unrelated"
    mkdir -p "$parent_dir"
    ( cd "$parent_dir" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect >/dev/null )
    echo "shared" > "$parent_dir/.ai/src/rules/shared.md"
    mkdir -p "$child_dir"
    ( cd "$child_dir" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect >/dev/null )
    cp "$parent_dir/.ai/src/rules/shared.md" "$child_dir/.ai/src/rules/shared.md"

    # Without --against, child has no parent walk-up target (sibling, not nested).
    run bash -c "cd '$child_dir' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' dedupe --yes"
    [ "$status" -eq 0 ]
    [ -f "$child_dir/.ai/src/rules/shared.md" ]

    # With --against, the dupe is found and removed.
    run bash -c "cd '$child_dir' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' dedupe --against '$parent_dir' --yes"
    [ "$status" -eq 0 ]
    [ ! -f "$child_dir/.ai/src/rules/shared.md" ]
}

@test "dedupe --workspace iterates bottom-up alphabetical" {
    # Three children under one parent. Each child has an identical dupe.
    local root="$TEST_PROJECT/root"
    mkdir -p "$root"
    ( cd "$root" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect >/dev/null )
    echo "shared" > "$root/.ai/src/rules/shared.md"

    local name
    for name in alpha bravo charlie; do
        mkdir -p "$root/$name"
        ( cd "$root/$name" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect >/dev/null )
        cp "$root/.ai/src/rules/shared.md" "$root/$name/.ai/src/rules/shared.md"
    done

    run bash -c "cd '$root' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' dedupe --workspace --yes"
    [ "$status" -eq 0 ]
    # Each child's dupe was removed; the parent's own file is untouched.
    [ -f "$root/.ai/src/rules/shared.md" ]
    [ ! -f "$root/alpha/.ai/src/rules/shared.md" ]
    [ ! -f "$root/bravo/.ai/src/rules/shared.md" ]
    [ ! -f "$root/charlie/.ai/src/rules/shared.md" ]
    # Ordering: alpha first, then bravo, then charlie, then root (bottom-up alpha).
    local alpha_pos bravo_pos charlie_pos root_pos
    alpha_pos=$(echo "$output" | grep -n "→ alpha" | cut -d: -f1 | head -1)
    bravo_pos=$(echo "$output" | grep -n "→ bravo" | cut -d: -f1 | head -1)
    charlie_pos=$(echo "$output" | grep -n "→ charlie" | cut -d: -f1 | head -1)
    root_pos=$(echo "$output" | grep -n "→ \." | cut -d: -f1 | head -1)
    [ -n "$alpha_pos" ] && [ -n "$bravo_pos" ] && [ -n "$charlie_pos" ] && [ -n "$root_pos" ]
    [ "$alpha_pos" -lt "$bravo_pos" ]
    [ "$bravo_pos" -lt "$charlie_pos" ]
    [ "$charlie_pos" -lt "$root_pos" ]
}

@test "dedupe --help prints usage" {
    run run_agentsync dedupe --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"agentsync dedupe"* ]]
    [[ "$output" == *"--against"* ]]
    [[ "$output" == *"--workspace"* ]]
}

@test "dedupe rejects --workspace + --against combination" {
    run run_agentsync dedupe --workspace --against /tmp --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"mutually exclusive"* ]]
}
