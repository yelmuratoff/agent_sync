#!/usr/bin/env bats
# Tests for agentsync sync --workspace and related fan-out behavior.

load test_helper

setup() {
    setup_test_project
}

teardown() {
    teardown_test_project
}

# Build a workspace with `root + leaf` projects, each initialized but with
# only `claude` enabled so sync output is predictable and fast.
_workspace_init_pair() {
    local root="$TEST_PROJECT/root"
    local leaf="$root/leaf"
    mkdir -p "$root"
    ( cd "$root" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect >/dev/null )
    ( cd "$root" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" enable claude --no-scaffold >/dev/null )
    mkdir -p "$leaf"
    ( cd "$leaf" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" init --no-detect >/dev/null )
    ( cd "$leaf" && AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" enable claude --no-scaffold >/dev/null )
    echo "$root $leaf"
}

@test "sync --workspace fails when no .ai/ found below cwd" {
    # cwd is a fresh test project with no .ai/ yet.
    run bash -c "cd '$TEST_PROJECT' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' sync --workspace"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No .ai/ directories found"* ]]
}

@test "sync --workspace --dry-run touches every project in bottom-up alpha order" {
    local pair root leaf
    pair=$(_workspace_init_pair)
    root="${pair%% *}"
    leaf="${pair##* }"

    run bash -c "cd '$root' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' sync --workspace --dry-run"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Found 2 project(s)"* ]]
    [[ "$output" == *"→ leaf"* ]]
    [[ "$output" == *"→ ."* ]]
    [[ "$output" == *"Workspace sync complete"* ]]
    # Leaf must appear before root (bottom-up alphabetical).
    local leaf_pos root_pos
    leaf_pos=$(echo "$output" | grep -n "→ leaf" | head -1 | cut -d: -f1)
    root_pos=$(echo "$output" | grep -n "→ \." | head -1 | cut -d: -f1)
    [ -n "$leaf_pos" ] && [ -n "$root_pos" ]
    [ "$leaf_pos" -lt "$root_pos" ]
}

@test "sync --workspace writes outputs in every project" {
    local pair root leaf
    pair=$(_workspace_init_pair)
    root="${pair%% *}"
    leaf="${pair##* }"

    run bash -c "cd '$root' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' sync --workspace"
    [ "$status" -eq 0 ]
    # Each project gets its own CLAUDE.md (claude is enabled in both).
    [ -f "$root/CLAUDE.md" ]
    [ -f "$leaf/CLAUDE.md" ]
}

@test "sync --workspace forwards extra args (e.g. --only) to each project" {
    local pair root leaf
    pair=$(_workspace_init_pair)
    root="${pair%% *}"
    leaf="${pair##* }"

    # --only=cursor (not enabled) → claude output should NOT be touched.
    rm -f "$root/CLAUDE.md" "$leaf/CLAUDE.md"
    run bash -c "cd '$root' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' sync --workspace --only cursor"
    [ "$status" -eq 0 ]
    [ ! -f "$root/CLAUDE.md" ]
    [ ! -f "$leaf/CLAUDE.md" ]
}

@test "sync --workspace continues past per-project failures" {
    # Build a workspace where one project is broken (missing AGENTS.md source).
    local pair root leaf
    pair=$(_workspace_init_pair)
    root="${pair%% *}"
    leaf="${pair##* }"
    rm -f "$leaf/.ai/src/AGENTS.md"

    run bash -c "cd '$root' && AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' sync --workspace"
    # Root must still produce CLAUDE.md; leaf's failure must not abort the loop.
    [ -f "$root/CLAUDE.md" ]
}
