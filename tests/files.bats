#!/usr/bin/env bats
# Tests for internal file utilities (sync_dir, sync_rules, copy_rules, etc.)

load test_helper

setup() {
    setup_test_project
    # Source the file utilities
    source "$REPO_ROOT/lib/helpers/cli_colors.sh"
    source "$REPO_ROOT/lib/helpers/logging.sh"
    source "$REPO_ROOT/lib/helpers/filters.sh"
    source "$REPO_ROOT/lib/helpers/file_ops.sh"
    source "$REPO_ROOT/lib/helpers/rule_operations.sh"
    source "$REPO_ROOT/lib/helpers/format_conversion.sh"
}

teardown() {
    teardown_test_project
}

# ── matches_filter ───────────────────────────────────────────────────────────

@test "matches_filter: no filter matches everything" {
    run matches_filter "foo.md" "" ""
    [ "$status" -eq 0 ]
}

@test "matches_filter: include matches" {
    run matches_filter "core.md" "*.md" ""
    [ "$status" -eq 0 ]
}

@test "matches_filter: include rejects" {
    run matches_filter "core.yaml" "*.md" ""
    [ "$status" -eq 1 ]
}

@test "matches_filter: exclude rejects" {
    run matches_filter "secret.md" "" "secret*"
    [ "$status" -eq 1 ]
}

@test "matches_filter: exclude passes non-matching" {
    run matches_filter "core.md" "" "secret*"
    [ "$status" -eq 0 ]
}

# ── ensure_dir ───────────────────────────────────────────────────────────────

@test "ensure_dir creates missing directory" {
    ensure_dir "$TEST_PROJECT/new/nested/dir"
    [ -d "$TEST_PROJECT/new/nested/dir" ]
}

@test "ensure_dir is idempotent" {
    ensure_dir "$TEST_PROJECT/existing"
    ensure_dir "$TEST_PROJECT/existing"
    [ -d "$TEST_PROJECT/existing" ]
}

# ── copy_file ────────────────────────────────────────────────────────────────

@test "copy_file copies content" {
    echo "hello" > "$TEST_PROJECT/src.txt"
    copy_file "$TEST_PROJECT/src.txt" "$TEST_PROJECT/dest.txt"
    [ "$(cat "$TEST_PROJECT/dest.txt")" = "hello" ]
}

@test "copy_file creates parent directories" {
    echo "hello" > "$TEST_PROJECT/src.txt"
    copy_file "$TEST_PROJECT/src.txt" "$TEST_PROJECT/a/b/dest.txt"
    [ -f "$TEST_PROJECT/a/b/dest.txt" ]
}

@test "copy_file dry-run does not copy" {
    echo "hello" > "$TEST_PROJECT/src.txt"
    copy_file "$TEST_PROJECT/src.txt" "$TEST_PROJECT/dest.txt" "true"
    [ ! -f "$TEST_PROJECT/dest.txt" ]
}

# ── sync_dir ─────────────────────────────────────────────────────────────────

@test "sync_dir copies directory contents" {
    mkdir -p "$TEST_PROJECT/src/a" "$TEST_PROJECT/src/b"
    echo "1" > "$TEST_PROJECT/src/a/file.md"
    echo "2" > "$TEST_PROJECT/src/b/file.md"
    sync_dir "$TEST_PROJECT/src" "$TEST_PROJECT/dest"
    [ -f "$TEST_PROJECT/dest/a/file.md" ]
    [ -f "$TEST_PROJECT/dest/b/file.md" ]
}

@test "sync_dir removes extraneous items" {
    mkdir -p "$TEST_PROJECT/src/a" "$TEST_PROJECT/dest/old"
    echo "1" > "$TEST_PROJECT/src/a/file.md"
    echo "stale" > "$TEST_PROJECT/dest/old/file.md"
    sync_dir "$TEST_PROJECT/src" "$TEST_PROJECT/dest"
    [ -f "$TEST_PROJECT/dest/a/file.md" ]
    [ ! -d "$TEST_PROJECT/dest/old" ]
}

# ── add_header ───────────────────────────────────────────────────────────────

@test "add_header prepends content" {
    echo "body" > "$TEST_PROJECT/file.md"
    add_header "$TEST_PROJECT/file.md" "---\nkey: value\n---"
    grep -q "key: value" "$TEST_PROJECT/file.md"
    grep -q "body" "$TEST_PROJECT/file.md"
    # Header should come before body
    local header_line body_line
    header_line=$(grep -n "key: value" "$TEST_PROJECT/file.md" | head -1 | cut -d: -f1)
    body_line=$(grep -n "body" "$TEST_PROJECT/file.md" | head -1 | cut -d: -f1)
    [ "$header_line" -lt "$body_line" ]
}

# ── merge_rules_to_file ─────────────────────────────────────────────────────

@test "merge_rules_to_file merges all rules" {
    mkdir -p "$TEST_PROJECT/rules"
    echo "# Rule A" > "$TEST_PROJECT/rules/a.md"
    echo "# Rule B" > "$TEST_PROJECT/rules/b.md"
    merge_rules_to_file "$TEST_PROJECT/rules" "$TEST_PROJECT/merged.md"
    grep -q "Rule A" "$TEST_PROJECT/merged.md"
    grep -q "Rule B" "$TEST_PROJECT/merged.md"
}

@test "merge_rules_to_file prepends agents" {
    mkdir -p "$TEST_PROJECT/rules"
    echo "# Agent" > "$TEST_PROJECT/agents.md"
    echo "# Rule" > "$TEST_PROJECT/rules/a.md"
    merge_rules_to_file "$TEST_PROJECT/rules" "$TEST_PROJECT/merged.md" "false" "" "" "$TEST_PROJECT/agents.md"
    # Agent content should come first
    local agent_line rule_line
    agent_line=$(grep -n "Agent" "$TEST_PROJECT/merged.md" | head -1 | cut -d: -f1)
    rule_line=$(grep -n "Rule" "$TEST_PROJECT/merged.md" | head -1 | cut -d: -f1)
    [ "$agent_line" -lt "$rule_line" ]
}
