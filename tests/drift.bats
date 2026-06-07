#!/usr/bin/env bats
# Tests for drift detection — manifest creation, idempotent re-sync,
# refusal to overwrite manual edits, --force override, dest deletion safety,
# tool disable cleanup, doctor drift section.

load test_helper

# Seed a post-sync tree (init + enable claude + sync) once; clone per test.
setup_file() {
    seed_project
    (
        cd "$TEST_SEED"
        AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" enable claude --no-scaffold >/dev/null
        AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    )
}
teardown_file() { teardown_seed_project; }
setup() { clone_seed; }
teardown() { teardown_test_project; }

# ── Manifest creation ───────────────────────────────────────────────────────

@test "drift: manifest is created on first sync" {
    [ -f ".ai/.sync-manifest" ]
}

@test "drift: manifest contains tab-separated path/hash entries" {
    local first_line
    first_line=$(head -1 .ai/.sync-manifest)
    [[ "$first_line" == *$'\t'* ]]
    # SHA-256 is 64 hex chars
    local hash="${first_line#*$'\t'}"
    [ "${#hash}" -eq 64 ]
}

@test "drift: manifest is sorted (LC_ALL=C)" {
    local sorted
    sorted=$(LC_ALL=C sort -c .ai/.sync-manifest 2>&1 || echo "UNSORTED")
    [ -z "$sorted" ]
}

@test "drift: manifest contains expected destinations" {
    grep -q "^CLAUDE.md"$'\t' .ai/.sync-manifest
    grep -q "^.claude/rules/" .ai/.sync-manifest
}

# ── Idempotency ─────────────────────────────────────────────────────────────

@test "drift: second sync produces byte-identical manifest" {
    local first
    first=$(shasum -a 256 .ai/.sync-manifest | awk '{print $1}')
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    local second
    second=$(shasum -a 256 .ai/.sync-manifest | awk '{print $1}')
    [ "$first" = "$second" ]
}

# ── Drift refusal ───────────────────────────────────────────────────────────

@test "drift: manual edit triggers refusal" {
    echo "MANUAL EDIT" >> .claude/rules/core.md
    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync
    [ "$status" -ne 0 ]
    [[ "$output" == *"Manual edits detected"* ]]
    [[ "$output" == *".claude/rules/core.md"* ]]
}

@test "drift: refused sync leaves edited file untouched" {
    echo "MANUAL EDIT" >> .claude/rules/core.md
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null 2>&1 || true
    grep -q "MANUAL EDIT" .claude/rules/core.md
}

@test "drift: refused sync does not rewrite manifest" {
    local before
    before=$(shasum -a 256 .ai/.sync-manifest | awk '{print $1}')
    echo "MANUAL EDIT" >> .claude/rules/core.md
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null 2>&1 || true
    local after
    after=$(shasum -a 256 .ai/.sync-manifest | awk '{print $1}')
    [ "$before" = "$after" ]
}

@test "drift: --force overwrites edited file" {
    echo "MANUAL EDIT" >> .claude/rules/core.md
    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync --force
    [ "$status" -eq 0 ]
    ! grep -q "MANUAL EDIT" .claude/rules/core.md
}

@test "drift: --force updates manifest to new dest hashes" {
    echo "MANUAL EDIT" >> .claude/rules/core.md
    local before
    before=$(shasum -a 256 .ai/.sync-manifest | awk '{print $1}')
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync --force >/dev/null
    local after
    after=$(shasum -a 256 .ai/.sync-manifest | awk '{print $1}')
    # Manifest content should be identical to first run (we restored source content),
    # so hash should match the original baseline.
    [ "$before" = "$after" ]
}

# ── Safe scenarios ──────────────────────────────────────────────────────────

@test "drift: manually deleted dest is rewritten without error" {
    rm .claude/rules/core.md
    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync
    [ "$status" -eq 0 ]
    [ -f ".claude/rules/core.md" ]
}

@test "drift: dry-run does not check drift and does not write manifest" {
    echo "MANUAL EDIT" >> .claude/rules/core.md
    local before
    before=$(shasum -a 256 .ai/.sync-manifest | awk '{print $1}')
    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync --dry-run
    [ "$status" -eq 0 ]
    local after
    after=$(shasum -a 256 .ai/.sync-manifest | awk '{print $1}')
    [ "$before" = "$after" ]
    grep -q "MANUAL EDIT" .claude/rules/core.md
}

# ── Tool disable cleanup ────────────────────────────────────────────────────

@test "drift: disabling a tool drops its entries from the manifest" {
    grep -q "^.claude/" .ai/.sync-manifest
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" disable claude >/dev/null
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    ! grep -q "^.claude/" .ai/.sync-manifest
}

# ── Doctor drift section ────────────────────────────────────────────────────

@test "drift: doctor reports clean manifest when nothing changed" {
    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" doctor
    [[ "$output" == *"match the manifest"* ]]
}

@test "drift: doctor reports edited file as drift" {
    echo "MANUAL EDIT" >> .claude/rules/core.md
    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" doctor
    [[ "$output" == *".claude/rules/core.md"* ]]
    [[ "$output" == *"edited since last sync"* ]]
}

@test "drift: doctor reports deleted file as missing" {
    rm .claude/rules/core.md
    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" doctor
    [[ "$output" == *".claude/rules/core.md"* ]]
    [[ "$output" == *"missing"* ]]
}

# ── User-added files in generated dirs ──────────────────────────────────────

@test "drift: sync preserves a user-added rule in a generated dir" {
    echo "my own rule" > .claude/rules/my-own.md
    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync
    [ "$status" -eq 0 ]
    [ -f ".claude/rules/my-own.md" ]
    [[ "$output" == *"Kept"* ]]
    [[ "$output" == *"my-own.md"* ]]
}

@test "drift: preserved user-added file is not recorded in the manifest" {
    echo "my own rule" > .claude/rules/my-own.md
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    ! grep -q "my-own.md" .ai/.sync-manifest
}

@test "drift: sync --force prunes a user-added rule in a generated dir" {
    echo "my own rule" > .claude/rules/my-own.md
    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync --force
    [ "$status" -eq 0 ]
    [ ! -f ".claude/rules/my-own.md" ]
}

@test "drift: dry-run previews keeping a user-added file without deleting it" {
    echo "my own rule" > .claude/rules/my-own.md
    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Would keep"* ]]
    [ -f ".claude/rules/my-own.md" ]
}

@test "drift: obsolete sync-generated rule is still pruned when removed from source" {
    echo "# Temp" > .ai/src/rules/temp-rule.md
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    [ -f ".claude/rules/temp-rule.md" ]
    rm .ai/src/rules/temp-rule.md
    AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync >/dev/null
    [ ! -f ".claude/rules/temp-rule.md" ]
}

# ── First-run baseline ──────────────────────────────────────────────────────

@test "drift: first-sync baseline message printed" {
    rm .ai/.sync-manifest
    run env AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"Initialized .ai/.sync-manifest"* ]]
    [ -f ".ai/.sync-manifest" ]
}
