#!/usr/bin/env bats
# Tests for restoring init/sync target backups.

load test_helper

setup() {
    setup_test_project
    run_agentsync init --no-detect >/dev/null
    enable_tools claude
}

teardown() {
    teardown_test_project
}

complete_backup_count() {
    local count=0 snapshot
    for snapshot in .ai/backups/*; do
        [[ -f "$snapshot/.complete" ]] && count=$((count + 1))
    done
    echo "$count"
}

@test "rollback restores the latest pre-sync state and creates an undo backup" {
    printf 'before-sync\n' > CLAUDE.md
    run_agentsync sync --only claude >/dev/null
    grep -q '# Project Agent' CLAUDE.md

    local sync_id
    sync_id=$(cat .ai/backups/.latest)
    grep -q '^operation=sync$' ".ai/backups/$sync_id/metadata"

    run run_agentsync rollback --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"Restored backup $sync_id"* ]]
    [ "$(cat CLAUDE.md)" = "before-sync" ]
    [ ! -e ".claude/rules" ]

    local undo_id
    undo_id=$(cat .ai/backups/.latest)
    [ "$undo_id" != "$sync_id" ]
    grep -q '^operation=rollback$' ".ai/backups/$undo_id/metadata"

    run run_agentsync rollback "$undo_id" --yes
    [ "$status" -eq 0 ]
    grep -q '# Project Agent' CLAUDE.md
}

@test "rollback --dry-run previews an explicit backup without changing state" {
    printf 'before-sync\n' > CLAUDE.md
    run_agentsync sync --only claude >/dev/null
    local sync_id backups_before
    sync_id=$(cat .ai/backups/.latest)
    backups_before=$(complete_backup_count)

    run run_agentsync rollback "$sync_id" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Rollback plan"* ]]
    [[ "$output" == *"CLAUDE.md"* ]]
    grep -q '# Project Agent' CLAUDE.md
    [ "$(complete_backup_count)" -eq "$backups_before" ]
}

@test "rollback --list shows complete init and sync backups" {
    run_agentsync sync --only claude >/dev/null

    run run_agentsync rollback --list
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\tinit\t'* ]]
    [[ "$output" == *$'\tsync\t'* ]]
}

@test "rollback requires confirmation outside a TTY unless --yes is passed" {
    printf 'before-sync\n' > CLAUDE.md
    run_agentsync sync --only claude >/dev/null

    run run_agentsync rollback
    [ "$status" -eq 130 ]
    [[ "$output" == *"Cancelled"* ]]
    grep -q '# Project Agent' CLAUDE.md
}

@test "rollback rejects backup IDs containing path traversal" {
    run run_agentsync rollback "../$(cat .ai/backups/.latest)" --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid backup ID"* ]]
}
