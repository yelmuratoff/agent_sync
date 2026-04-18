#!/usr/bin/env bats
# Tests for snapshot-based conflict detection on `agentsync update`.
# Exercises lib/helpers/snapshot.sh directly against a fake install-dir + project,
# plus the --strict flag on `cmd_update` via argument validation.

load test_helper

setup() {
    setup_test_project

    # Shell-level fixture: fake install dir with its own tool catalog.
    FAKE_INSTALL="$(mktemp -d "${TMPDIR:-/tmp}/agentsync_fake_install.XXXXXX")"
    mkdir -p "$FAKE_INSTALL/lib/templates/tools"
    mkdir -p "$FAKE_INSTALL/lib/helpers"

    SNAPSHOT_DIR="$FAKE_INSTALL/.snapshot"

    # Source the modules under test. Resolve paths against the real repo.
    # shellcheck disable=SC1090,SC1091
    source "$REPO_ROOT/lib/helpers/yaml.sh"
    # shellcheck disable=SC1090,SC1091
    source "$REPO_ROOT/lib/helpers/snapshot.sh"
}

teardown() {
    [[ -n "${FAKE_INSTALL:-}" ]] && [[ -d "$FAKE_INSTALL" ]] && rm -rf "$FAKE_INSTALL"
    teardown_test_project
}

# ── helpers ──────────────────────────────────────────────────────────────────

# Write a minimal base tool YAML to the fake install dir.
_write_base_tool() {
    local name="$1"
    local rules_dest="$2"
    cat > "$FAKE_INSTALL/lib/templates/tools/${name}.yaml" <<YAML
name: $name
enabled: true
targets:
  rules:
    dest: "$rules_dest"
    extension: .md
YAML
}

# Write a user override in the project dir for a given field.
_write_user_override() {
    local name="$1"
    local rules_dest="$2"
    mkdir -p .ai/src/tools
    cat > ".ai/src/tools/${name}.yaml" <<YAML
targets:
  rules:
    dest: "$rules_dest"
YAML
}

# ── snapshot_save ────────────────────────────────────────────────────────────

@test "snapshot_save copies tool catalog" {
    _write_base_tool claude ".claude/rules"
    snapshot_save "$FAKE_INSTALL" "$SNAPSHOT_DIR"
    [ -f "$SNAPSHOT_DIR/tools/claude.yaml" ]
    grep -q '.claude/rules' "$SNAPSHOT_DIR/tools/claude.yaml"
}

@test "snapshot_save fails when install_dir has no catalog" {
    run snapshot_save "$FAKE_INSTALL/nonexistent" "$SNAPSHOT_DIR"
    [ "$status" -ne 0 ]
}

@test "snapshot_save overwrites stale snapshot" {
    _write_base_tool claude ".claude/rules"
    snapshot_save "$FAKE_INSTALL" "$SNAPSHOT_DIR"
    # Mutate base, re-snapshot — old file should be replaced, not appended.
    _write_base_tool claude ".claude/rules-v2"
    snapshot_save "$FAKE_INSTALL" "$SNAPSHOT_DIR"
    grep -q '.claude/rules-v2' "$SNAPSHOT_DIR/tools/claude.yaml"
}

# ── snapshot_diff ────────────────────────────────────────────────────────────

@test "snapshot_diff is empty when nothing changed" {
    _write_base_tool claude ".claude/rules"
    snapshot_save "$FAKE_INSTALL" "$SNAPSHOT_DIR"
    run snapshot_diff "$SNAPSHOT_DIR" "$FAKE_INSTALL"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "snapshot_diff emits TSV for changed fields" {
    _write_base_tool claude ".claude/rules"
    snapshot_save "$FAKE_INSTALL" "$SNAPSHOT_DIR"
    _write_base_tool claude ".claude/rules-v2"
    run snapshot_diff "$SNAPSHOT_DIR" "$FAKE_INSTALL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude"*"targets.rules.dest"*".claude/rules"*".claude/rules-v2"* ]]
}

@test "snapshot_diff handles tools added in new release" {
    _write_base_tool claude ".claude/rules"
    snapshot_save "$FAKE_INSTALL" "$SNAPSHOT_DIR"
    _write_base_tool cursor ".cursor/rules"
    run snapshot_diff "$SNAPSHOT_DIR" "$FAKE_INSTALL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cursor"* ]]
}

# ── snapshot_find_conflicts ──────────────────────────────────────────────────

@test "snapshot_find_conflicts returns empty when no user override exists" {
    _write_base_tool claude ".claude/rules"
    snapshot_save "$FAKE_INSTALL" "$SNAPSHOT_DIR"
    _write_base_tool claude ".claude/rules-v2"
    run bash -c "
        source '$REPO_ROOT/lib/helpers/yaml.sh'
        source '$REPO_ROOT/lib/helpers/snapshot.sh'
        snapshot_diff '$SNAPSHOT_DIR' '$FAKE_INSTALL' \
            | snapshot_find_conflicts '$TEST_PROJECT'
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "snapshot_find_conflicts detects override on a changed field" {
    _write_base_tool claude ".claude/rules"
    _write_user_override claude ".claude/my-rules"
    snapshot_save "$FAKE_INSTALL" "$SNAPSHOT_DIR"
    _write_base_tool claude ".claude/rules-v2"

    run bash -c "
        source '$REPO_ROOT/lib/helpers/yaml.sh'
        source '$REPO_ROOT/lib/helpers/snapshot.sh'
        snapshot_diff '$SNAPSHOT_DIR' '$FAKE_INSTALL' \
            | snapshot_find_conflicts '$TEST_PROJECT'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude"* ]]
    [[ "$output" == *"targets.rules.dest"* ]]
    [[ "$output" == *".claude/my-rules"* ]]
    [[ "$output" == *".claude/rules-v2"* ]]
}

@test "snapshot_find_conflicts ignores fields the user didn't override" {
    # User override on extension; upstream changes dest — no conflict.
    _write_base_tool claude ".claude/rules"
    mkdir -p .ai/src/tools
    cat > .ai/src/tools/claude.yaml <<'YAML'
targets:
  rules:
    extension: .mdc
YAML
    snapshot_save "$FAKE_INSTALL" "$SNAPSHOT_DIR"
    _write_base_tool claude ".claude/rules-v2"

    run bash -c "
        source '$REPO_ROOT/lib/helpers/yaml.sh'
        source '$REPO_ROOT/lib/helpers/snapshot.sh'
        snapshot_diff '$SNAPSHOT_DIR' '$FAKE_INSTALL' \
            | snapshot_find_conflicts '$TEST_PROJECT'
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── snapshot_write_pending_resolutions ───────────────────────────────────────

@test "snapshot_write_pending_resolutions writes a valid YAML queue" {
    mkdir -p .ai
    local tsv
    tsv=$(printf 'claude\ttargets.rules.dest\t.claude/rules\t.claude/rules-v2\t.claude/my-rules\n')
    printf '%s\n' "$tsv" \
        | snapshot_write_pending_resolutions "$TEST_PROJECT" "0.7.0" "0.8.0"
    [ -f .ai/.pending-resolutions.yaml ]
    grep -q 'schema: 1' .ai/.pending-resolutions.yaml
    grep -q 'from_version: "0.7.0"' .ai/.pending-resolutions.yaml
    grep -q 'to_version: "0.8.0"' .ai/.pending-resolutions.yaml
    grep -q 'tool: "claude"' .ai/.pending-resolutions.yaml
    grep -q 'field: "targets.rules.dest"' .ai/.pending-resolutions.yaml
    grep -q 'base_before: ".claude/rules"' .ai/.pending-resolutions.yaml
    grep -q 'base_after: ".claude/rules-v2"' .ai/.pending-resolutions.yaml
    grep -q 'your_override: ".claude/my-rules"' .ai/.pending-resolutions.yaml
}

@test "snapshot_write_pending_resolutions no-ops when .ai/ missing" {
    # Project dir without .ai/
    local tsv
    tsv=$(printf 'claude\ttargets.rules.dest\tfoo\tbar\tbaz\n')
    printf '%s\n' "$tsv" \
        | snapshot_write_pending_resolutions "$TEST_PROJECT" "a" "b"
    [ ! -f .ai/.pending-resolutions.yaml ]
}

@test "snapshot_write_pending_resolutions escapes quotes and backslashes" {
    mkdir -p .ai
    local tsv
    tsv=$(printf 'claude\ttargets.rules.header\tone\tquoted "hi"\tback\\slash\n')
    printf '%s\n' "$tsv" \
        | snapshot_write_pending_resolutions "$TEST_PROJECT" "0.7.0" "0.8.0"
    grep -q 'base_after: "quoted \\"hi\\""' .ai/.pending-resolutions.yaml
    grep -q 'your_override: "back\\\\slash"' .ai/.pending-resolutions.yaml
}

# ── snapshot_read_pending_pairs ──────────────────────────────────────────────

@test "snapshot_read_pending_pairs returns empty when no queue file" {
    run snapshot_read_pending_pairs "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "snapshot_read_pending_pairs extracts tool/field pairs" {
    mkdir -p .ai
    cat > .ai/.pending-resolutions.yaml <<'YAML'
schema: 1
conflicts:
  - tool: "claude"
    field: "targets.rules.dest"
    base_before: "a"
    base_after: "b"
    your_override: "c"
  - tool: "cursor"
    field: "targets.rules.extension"
    base_before: ".md"
    base_after: ".mdc"
    your_override: ".md"
YAML
    run snapshot_read_pending_pairs "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude"* ]]
    [[ "$output" == *"targets.rules.dest"* ]]
    [[ "$output" == *"cursor"* ]]
    [[ "$output" == *"targets.rules.extension"* ]]
}

# ── snapshot_clear_pending ───────────────────────────────────────────────────

@test "snapshot_clear_pending removes queue file" {
    mkdir -p .ai
    echo "schema: 1" > .ai/.pending-resolutions.yaml
    snapshot_clear_pending "$TEST_PROJECT"
    [ ! -f .ai/.pending-resolutions.yaml ]
}

@test "snapshot_clear_pending is safe when file is missing" {
    run snapshot_clear_pending "$TEST_PROJECT"
    [ "$status" -eq 0 ]
}

# ── cmd_update arg parsing ───────────────────────────────────────────────────

@test "update --help prints usage without network" {
    run run_agentsync update --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--strict"* ]]
}

@test "update rejects unknown flag" {
    run run_agentsync update --bogus
    [ "$status" -eq 2 ]
    [[ "$output" == *"Unknown flag"* ]]
}
