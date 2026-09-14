#!/usr/bin/env bats
# Tests for .gitignore management.

load test_helper

setup() {
    setup_test_project
    source "$REPO_ROOT/lib/helpers/cli_colors.sh"
    source "$REPO_ROOT/lib/helpers/logging.sh"
    source "$REPO_ROOT/lib/helpers/tmp.sh"
    source "$REPO_ROOT/lib/helpers/gitignore.sh"
}

teardown() {
    teardown_test_project
}

@test "update_gitignore creates block in empty file" {
    touch "$TEST_PROJECT/.gitignore"
    update_gitignore "$TEST_PROJECT/.gitignore" ".claude/rules/"
    grep -q "AI SYNC GENERATED START" "$TEST_PROJECT/.gitignore"
    grep -q ".claude/rules/" "$TEST_PROJECT/.gitignore"
    grep -q "AI SYNC GENERATED END" "$TEST_PROJECT/.gitignore"
}

@test "update_gitignore creates file if missing" {
    update_gitignore "$TEST_PROJECT/.gitignore" ".claude/"
    [ -f "$TEST_PROJECT/.gitignore" ]
    grep -q ".claude/" "$TEST_PROJECT/.gitignore"
}

@test "update_gitignore preserves existing content" {
    echo "node_modules/" > "$TEST_PROJECT/.gitignore"
    update_gitignore "$TEST_PROJECT/.gitignore" ".claude/"
    grep -q "node_modules/" "$TEST_PROJECT/.gitignore"
    grep -q ".claude/" "$TEST_PROJECT/.gitignore"
}

@test "update_gitignore replaces block on re-run" {
    update_gitignore "$TEST_PROJECT/.gitignore" ".claude/"
    update_gitignore "$TEST_PROJECT/.gitignore" ".cursor/"
    # Old path gone, new path present
    ! grep -q ".claude/" "$TEST_PROJECT/.gitignore"
    grep -q ".cursor/" "$TEST_PROJECT/.gitignore"
    # Exactly one block
    local count
    count=$(grep -c "AI SYNC GENERATED START" "$TEST_PROJECT/.gitignore")
    [ "$count" -eq 1 ]
}

@test "update_gitignore sorts and deduplicates paths" {
    local paths
    paths=$(printf '%s\n' ".cursor/" ".claude/" ".cursor/" ".claude/")
    update_gitignore "$TEST_PROJECT/.gitignore" "$paths"

    local claude_count cursor_count
    claude_count=$(grep -c "^\.claude/$" "$TEST_PROJECT/.gitignore")
    cursor_count=$(grep -c "^\.cursor/$" "$TEST_PROJECT/.gitignore")
    [ "$claude_count" -eq 1 ]
    [ "$cursor_count" -eq 1 ]
}

@test "update_gitignore orders paths by bytes whatever the locale" {
    locale -a 2>/dev/null | grep -qix 'en_US.utf-\{0,1\}8' || skip "en_US.UTF-8 locale not installed"
    LC_ALL=en_US.UTF-8 update_gitignore "$TEST_PROJECT/.gitignore" "$(printf '%s\n' b/ _x/ B/)"
    run grep -A3 "Do not edit this block manually" "$TEST_PROJECT/.gitignore"
    [ "${lines[1]}" = "B/" ]
    [ "${lines[2]}" = "_x/" ]
    [ "${lines[3]}" = "b/" ]
}

@test "update_gitignore handles empty paths" {
    update_gitignore "$TEST_PROJECT/.gitignore" ""
    grep -q "AI SYNC GENERATED START" "$TEST_PROJECT/.gitignore"
    grep -q "AI SYNC GENERATED END" "$TEST_PROJECT/.gitignore"
}
