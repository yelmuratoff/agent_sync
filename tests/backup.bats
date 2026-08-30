#!/usr/bin/env bats
# Tests for transactional target backups.

load test_helper

setup() {
    setup_test_project
    source "$REPO_ROOT/lib/helpers/backup.sh"
    BACKUP_OUTSIDE=""
}

teardown() {
    [[ -n "${BACKUP_OUTSIDE:-}" ]] && _rm_rf_resilient "$BACKUP_OUTSIDE"
    teardown_test_project
}

# A complete snapshot with an arbitrary id. Age pruning reads the id's timestamp
# prefix, so an id from 2020 stays old no matter when the suite runs.
_fake_snapshot() {
    local id="$1"
    mkdir -p ".ai/backups/$id/files"
    printf 'schema=1\noperation=sync\ncreated_at=%s\n' "${id%%-*}" > ".ai/backups/$id/metadata"
    printf 'missing\tAGENTS.md\n' > ".ai/backups/$id/targets.tsv"
    : > ".ai/backups/$id/.complete"
}

@test "backup restores existing targets and removes targets created later" {
    mkdir -p ".claude"
    printf 'before\n' > "AGENTS.md"
    printf 'settings-before\n' > ".claude/settings.json"

    local snapshot
    snapshot=$(backup_create \
        "$TEST_PROJECT" \
        "sync" \
        "$TEST_PROJECT/AGENTS.md" \
        "$TEST_PROJECT/.claude/settings.json" \
        "$TEST_PROJECT/.claude/rules")

    printf 'after\n' > "AGENTS.md"
    printf 'settings-after\n' > ".claude/settings.json"
    mkdir -p ".claude/rules"
    printf 'generated\n' > ".claude/rules/core.md"

    backup_restore "$TEST_PROJECT" "$snapshot"

    [ "$(cat AGENTS.md)" = "before" ]
    [ "$(cat .claude/settings.json)" = "settings-before" ]
    [ ! -e ".claude/rules" ]
}

@test "backup collapses nested and duplicate targets into one snapshot root" {
    mkdir -p ".amazonq/rules"
    printf 'context\n' > ".amazonq/rules/00-context.md"
    printf 'rule\n' > ".amazonq/rules/core.md"

    local snapshot
    snapshot=$(backup_create \
        "$TEST_PROJECT" \
        "sync" \
        "$TEST_PROJECT/.amazonq/rules/00-context.md" \
        "$TEST_PROJECT/.amazonq/rules" \
        "$TEST_PROJECT/.amazonq/rules")

    [ "$(wc -l < "$snapshot/targets.tsv" | tr -d ' ')" -eq 1 ]
    grep -q $'^present\t.amazonq/rules$' "$snapshot/targets.tsv"
    [ -f "$snapshot/files/.amazonq/rules/00-context.md" ]
    [ -f "$snapshot/files/.amazonq/rules/core.md" ]
}

@test "backup supports target paths containing spaces" {
    mkdir -p "tool config"
    printf 'before\n' > "tool config/settings file.json"

    local snapshot
    snapshot=$(backup_create \
        "$TEST_PROJECT" \
        "sync" \
        "$TEST_PROJECT/tool config/settings file.json")

    printf 'after\n' > "tool config/settings file.json"
    backup_restore "$TEST_PROJECT" "$snapshot"

    [ "$(cat "tool config/settings file.json")" = "before" ]
}

@test "backup rejects the repository root and paths outside it" {
    run backup_create "$TEST_PROJECT" "sync" "$TEST_PROJECT"
    [ "$status" -ne 0 ]

    run backup_create "$TEST_PROJECT" "sync" "$(dirname "$TEST_PROJECT")"
    [ "$status" -ne 0 ]

    run backup_create "$TEST_PROJECT" "sync" "$TEST_PROJECT/.ai"
    [ "$status" -ne 0 ]
}

@test "backup snapshots are ignored and latest resolves the newest complete snapshot" {
    printf 'one\n' > "AGENTS.md"
    local first second
    first=$(backup_create "$TEST_PROJECT" "init" "$TEST_PROJECT/AGENTS.md")
    second=$(backup_create "$TEST_PROJECT" "sync" "$TEST_PROJECT/AGENTS.md")

    [ "$first" != "$second" ]
    [ "$(backup_latest "$TEST_PROJECT")" = "$second" ]
    git check-ignore -q "$second/.complete"
}

@test "backup restore refuses an intermediate symlink outside the project" {
    local snapshot
    snapshot=$(backup_create "$TEST_PROJECT" "sync" "$TEST_PROJECT/.claude/rules")

    BACKUP_OUTSIDE="$(mktemp -d "${TMPDIR:-/tmp}/agentsync_backup_outside.XXXXXX")"
    mkdir -p "$BACKUP_OUTSIDE/rules"
    printf 'outside\n' > "$BACKUP_OUTSIDE/rules/sentinel"
    create_test_symlink "$BACKUP_OUTSIDE" .claude

    run backup_restore "$TEST_PROJECT" "$snapshot"
    [ "$status" -ne 0 ]
    [ -f "$BACKUP_OUTSIDE/rules/sentinel" ]
}

@test "backup refuses a store reached through a symlink outside the project" {
    BACKUP_OUTSIDE="$(mktemp -d "${TMPDIR:-/tmp}/agentsync_backup_store.XXXXXX")"
    create_test_symlink "$BACKUP_OUTSIDE" .ai
    printf 'source\n' > AGENTS.md

    run backup_create "$TEST_PROJECT" "sync" "$TEST_PROJECT/AGENTS.md"
    [ "$status" -ne 0 ]
    [ ! -e "$BACKUP_OUTSIDE/backups" ]
}

@test "backup pruning keeps the latest bounded history" {
    printf 'source\n' > AGENTS.md
    local first latest
    first=$(backup_create "$TEST_PROJECT" "init" "$TEST_PROJECT/AGENTS.md")
    backup_create "$TEST_PROJECT" "sync" "$TEST_PROJECT/AGENTS.md" >/dev/null
    latest=$(backup_create "$TEST_PROJECT" "sync" "$TEST_PROJECT/AGENTS.md")

    backup_prune "$TEST_PROJECT" 2

    [ ! -e "$first" ]
    [ -d "$latest" ]
    [ "$(backup_latest "$TEST_PROJECT")" = "$latest" ]
    [ "$(find .ai/backups -type f -name .complete | wc -l | tr -d ' ')" -eq 2 ]
}

@test "backup pruning removes snapshots older than the age limit" {
    printf 'source\n' > AGENTS.md
    _fake_snapshot "20200101T000000Z-sync-1"
    local latest
    latest=$(backup_create "$TEST_PROJECT" "sync" "$TEST_PROJECT/AGENTS.md")

    backup_prune "$TEST_PROJECT" 10 30

    [ ! -e ".ai/backups/20200101T000000Z-sync-1" ]
    [ -d "$latest" ]
    [ "$(backup_latest "$TEST_PROJECT")" = "$latest" ]
}

@test "backup age pruning never empties the store" {
    _fake_snapshot "20200101T000000Z-sync-1"
    printf '%s\n' "20200101T000000Z-sync-1" > .ai/backups/.latest

    backup_prune "$TEST_PROJECT" 10 1

    [ -d ".ai/backups/20200101T000000Z-sync-1" ]
    [ "$(backup_latest "$TEST_PROJECT")" = "$TEST_PROJECT/.ai/backups/20200101T000000Z-sync-1" ]
}

@test "backup a zero age limit disables age pruning" {
    printf 'source\n' > AGENTS.md
    _fake_snapshot "20200101T000000Z-sync-1"
    backup_create "$TEST_PROJECT" "sync" "$TEST_PROJECT/AGENTS.md" >/dev/null

    backup_prune "$TEST_PROJECT" 10 0

    [ -d ".ai/backups/20200101T000000Z-sync-1" ]
}

@test "backup a zero count limit still applies the age limit" {
    printf 'source\n' > AGENTS.md
    _fake_snapshot "20200101T000000Z-sync-1"
    local latest
    latest=$(backup_create "$TEST_PROJECT" "sync" "$TEST_PROJECT/AGENTS.md")

    backup_prune "$TEST_PROJECT" 0 30

    [ ! -e ".ai/backups/20200101T000000Z-sync-1" ]
    [ -d "$latest" ]
}

@test "backup a snapshot with an unparseable name is never age-pruned" {
    printf 'source\n' > AGENTS.md
    _fake_snapshot "not-a-timestamp"
    backup_create "$TEST_PROJECT" "sync" "$TEST_PROJECT/AGENTS.md" >/dev/null

    backup_prune "$TEST_PROJECT" 10 1

    [ -d ".ai/backups/not-a-timestamp" ]
}

@test "backup_create reclaims an abandoned staging directory" {
    printf 'source\n' > AGENTS.md
    backup_create "$TEST_PROJECT" "init" "$TEST_PROJECT/AGENTS.md" >/dev/null

    mkdir -p ".ai/backups/.tmp.sync.abandoned/files"
    touch -t 202001010000 ".ai/backups/.tmp.sync.abandoned"

    local latest
    latest=$(backup_create "$TEST_PROJECT" "sync" "$TEST_PROJECT/AGENTS.md")

    [ ! -e ".ai/backups/.tmp.sync.abandoned" ]
    [ -d "$latest" ]
}

@test "backup_create leaves a staging directory from a live run alone" {
    printf 'source\n' > AGENTS.md
    mkdir -p ".ai/backups/.tmp.sync.inflight/files"

    backup_create "$TEST_PROJECT" "sync" "$TEST_PROJECT/AGENTS.md" >/dev/null

    [ -d ".ai/backups/.tmp.sync.inflight" ]
}

@test "backup_create reclaims abandoned metadata temp files" {
    printf 'source\n' > AGENTS.md
    backup_create "$TEST_PROJECT" "init" "$TEST_PROJECT/AGENTS.md" >/dev/null

    : > ".ai/backups/.latest.tmp.stale"
    : > ".ai/backups/.gitignore.tmp.stale"
    touch -t 202001010000 ".ai/backups/.latest.tmp.stale" ".ai/backups/.gitignore.tmp.stale"

    backup_create "$TEST_PROJECT" "sync" "$TEST_PROJECT/AGENTS.md" >/dev/null

    [ ! -e ".ai/backups/.latest.tmp.stale" ]
    [ ! -e ".ai/backups/.gitignore.tmp.stale" ]
    [ -f ".ai/backups/.latest" ] && [ ! -L ".ai/backups/.latest" ]
    [ "$(cat .ai/backups/.gitignore)" = "*" ]
}

@test "backup metadata updates do not follow symlinks out of the store" {
    printf 'source\n' > AGENTS.md
    backup_create "$TEST_PROJECT" "init" "$TEST_PROJECT/AGENTS.md" >/dev/null

    BACKUP_OUTSIDE="$(mktemp -d "${TMPDIR:-/tmp}/agentsync_backup_metadata.XXXXXX")"
    printf 'outside-ignore\n' > "$BACKUP_OUTSIDE/ignore"
    printf 'outside-latest\n' > "$BACKUP_OUTSIDE/latest"
    rm .ai/backups/.gitignore
    create_test_symlink "$BACKUP_OUTSIDE/ignore" .ai/backups/.gitignore
    create_test_symlink "$BACKUP_OUTSIDE/latest" ".ai/backups/.latest.tmp.$$"

    backup_create "$TEST_PROJECT" "sync" "$TEST_PROJECT/AGENTS.md" >/dev/null

    [ "$(cat "$BACKUP_OUTSIDE/ignore")" = "outside-ignore" ]
    [ "$(cat "$BACKUP_OUTSIDE/latest")" = "outside-latest" ]
    [ ! -L .ai/backups/.gitignore ]
}

@test "backup restore rejects a snapshot directory symlink" {
    printf 'source\n' > AGENTS.md
    backup_create "$TEST_PROJECT" "init" "$TEST_PROJECT/AGENTS.md" >/dev/null

    BACKUP_OUTSIDE="$(mktemp -d "${TMPDIR:-/tmp}/agentsync_backup_snapshot.XXXXXX")"
    mkdir -p "$BACKUP_OUTSIDE/files"
    printf 'present\tAGENTS.md\n' > "$BACKUP_OUTSIDE/targets.tsv"
    printf 'outside\n' > "$BACKUP_OUTSIDE/files/AGENTS.md"
    : > "$BACKUP_OUTSIDE/.complete"
    create_test_symlink "$BACKUP_OUTSIDE" .ai/backups/forged

    run backup_restore "$TEST_PROJECT" "forged"
    [ "$status" -ne 0 ]
    [ "$(cat AGENTS.md)" = "source" ]
}
