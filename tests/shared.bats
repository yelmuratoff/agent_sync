#!/usr/bin/env bats
# Tests for `shared:` resources concept — materializing parent .ai/src/ files
# into child output via a transient overlay during sync.

load test_helper

setup() {
    setup_test_project
}

teardown() {
    teardown_test_project
}

# Helper: build a parent project with one custom rule, and a child below
# that declares `shared:` inheritance for rules. Echoes "<parent> <child>".
_shared_make_pair() {
    local parent_dir="$TEST_PROJECT/parent"
    local child_dir="$parent_dir/child"
    mkdir -p "$parent_dir"
    ( cd "$parent_dir" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect --yes >/dev/null )
    echo "parent-rule" > "$parent_dir/.ai/src/rules/parent-only.md"

    mkdir -p "$child_dir"
    ( cd "$child_dir" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect --yes >/dev/null )
    ( cd "$child_dir" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" enable claude --no-scaffold >/dev/null )
    # Remove default rules so the test is unambiguous about what's inherited.
    rm -f "$child_dir/.ai/src/rules/"*.md
    echo "child-rule" > "$child_dir/.ai/src/rules/child-only.md"

    cat >> "$child_dir/.ai/agent_sync.yaml" <<'EOF'

shared:
  path: "../"
  inherit: rules
EOF
    echo "$parent_dir $child_dir"
}

@test "shared: parent rules materialise into child output dirs" {
    local pair child
    pair=$(_shared_make_pair)
    child="${pair##* }"

    run bash -c "cd '$child' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' sync"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Shared overlay active"* ]]
    # Inherited parent file present in child output.
    [ -f "$child/.claude/rules/parent-only.md" ]
    # Child's own file still present.
    [ -f "$child/.claude/rules/child-only.md" ]
}

@test "shared: child wins on path collision (overlay does not overwrite child)" {
    local pair parent child
    pair=$(_shared_make_pair)
    parent="${pair%% *}"
    child="${pair##* }"

    echo "PARENT VERSION" > "$parent/.ai/src/rules/clash.md"
    echo "CHILD VERSION" > "$child/.ai/src/rules/clash.md"

    run bash -c "cd '$child' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' sync"
    [ "$status" -eq 0 ]
    grep -q "CHILD VERSION" "$child/.claude/rules/clash.md"
}

@test "shared: inherit list filters which categories materialise" {
    local pair parent child
    pair=$(_shared_make_pair)   # inherits: rules
    parent="${pair%% *}"
    child="${pair##* }"

    # Parent has a custom skill — but child only inherits rules, not skills.
    mkdir -p "$parent/.ai/src/skills/parent-skill"
    echo "ps" > "$parent/.ai/src/skills/parent-skill/SKILL.md"

    run bash -c "cd '$child' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' sync"
    [ "$status" -eq 0 ]
    # Inherited via rules — present.
    [ -f "$child/.claude/rules/parent-only.md" ]
    # NOT inherited (skills not in list) — absent.
    [ ! -d "$child/.claude/skills/parent-skill" ]
}

@test "shared: missing parent path warns and skips overlay" {
    setup_test_project
    run_agentsync init --no-detect --yes >/dev/null
    run_agentsync enable claude --no-scaffold >/dev/null
    cat >> .ai/agent_sync.yaml <<'EOF'

shared:
  path: "../does-not-exist"
  inherit: rules
EOF
    run run_agentsync sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"shared.path does not exist"* ]] || [[ "$output" == *"overlay skipped"* ]]
    # Child's own rules still sync.
    [ -d ".claude/rules" ]
}

@test "shared: cleans up tmpdir after sync (no leaked dirs)" {
    # Use a per-run TMPDIR so we can assert no leftovers afterward.
    local sandbox="$TEST_PROJECT/tmpdir_sandbox"
    mkdir -p "$sandbox"
    local pair child
    pair=$(_shared_make_pair)
    child="${pair##* }"

    TMPDIR="$sandbox" run bash -c "cd '$child' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' sync"
    [ "$status" -eq 0 ]
    # No leftover agentsync_shared.* directory.
    ! ls "$sandbox" 2>/dev/null | grep -q "agentsync_shared\." || false
}

@test "shared: dry-run does not produce output but still tears down tmpdir" {
    local sandbox="$TEST_PROJECT/tmpdir_sandbox"
    mkdir -p "$sandbox"
    local pair child
    pair=$(_shared_make_pair)
    child="${pair##* }"

    TMPDIR="$sandbox" run bash -c "cd '$child' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' sync --dry-run"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Shared overlay active"* ]]
    [ ! -f "$child/.claude/rules/parent-only.md" ]
    ! ls "$sandbox" 2>/dev/null | grep -q "agentsync_shared\." || false
}

@test "doctor adds 'inherited via shared:' hint on duplicates in inherited categories" {
    local pair parent child
    pair=$(_shared_make_pair)
    parent="${pair%% *}"
    child="${pair##* }"

    # Force a duplicate in child for an inherited category.
    cp "$parent/.ai/src/rules/parent-only.md" "$child/.ai/src/rules/parent-only.md"

    run bash -c "cd '$child' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' doctor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"rules/parent-only.md — duplicate"* ]]
    [[ "$output" == *"inherited via shared:"* ]]
}

@test "doctor: governance-category divergent file is upgraded to advisory" {
    local parent_dir="$TEST_PROJECT/parent"
    local child_dir="$parent_dir/child"
    mkdir -p "$parent_dir"
    ( cd "$parent_dir" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect --yes >/dev/null )
    cat > "$parent_dir/.ai/src/rules/governance-rule.md" <<'EOF'
---
name: governance-rule
description: a rule
category: governance
---
parent body
EOF

    mkdir -p "$child_dir"
    ( cd "$child_dir" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect --yes >/dev/null )
    cat > "$child_dir/.ai/src/rules/governance-rule.md" <<'EOF'
---
name: governance-rule
description: a rule
category: governance
---
CHILD overrides body
EOF

    run bash -c "cd '$child_dir' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' doctor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"governance file diverges from parent"* ]]
    [[ "$output" == *"likely a mistake"* ]]
}

@test "doctor: non-governance divergent file stays info-tier" {
    local parent_dir="$TEST_PROJECT/parent"
    local child_dir="$parent_dir/child"
    mkdir -p "$parent_dir"
    ( cd "$parent_dir" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect --yes >/dev/null )
    echo "no frontmatter, parent" > "$parent_dir/.ai/src/rules/plain.md"

    mkdir -p "$child_dir"
    ( cd "$child_dir" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect --yes >/dev/null )
    echo "no frontmatter, child" > "$child_dir/.ai/src/rules/plain.md"

    run bash -c "cd '$child_dir' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' doctor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"diverges from parent"* ]]
    [[ "$output" != *"governance file diverges"* ]]
}
