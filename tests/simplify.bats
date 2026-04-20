#!/usr/bin/env bats
# Tests for agentsync simplify.

load test_helper

setup_file() {
    seed_project
}

teardown_file() {
    teardown_seed_project
}

setup() {
    clone_seed
}

teardown() {
    teardown_test_project
}

# ── No-override path ──────────────────────────────────────────────────────────

@test "simplify with no overrides prints friendly message" {
    run run_agentsync simplify
    [ "$status" -eq 0 ]
    [[ "$output" == *"No user overrides"* ]]
}

@test "simplify rejects unknown tool name" {
    run_agentsync customize claude --full >/dev/null
    run run_agentsync simplify bogus_tool_xyz
    [ "$status" -ne 0 ]
    [[ "$output" == *"No override found"* ]]
}

@test "simplify rejects unknown flag" {
    run run_agentsync simplify --whatever
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown flag"* ]]
}

# ── Dry-run preview ───────────────────────────────────────────────────────────

@test "simplify is dry-run by default (does not mutate files)" {
    run_agentsync customize cursor --full >/dev/null
    local before_hash
    before_hash=$(cksum .ai/src/tools/cursor.yaml | awk '{print $1,$2}')

    run run_agentsync simplify
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dry run"* ]]

    local after_hash
    after_hash=$(cksum .ai/src/tools/cursor.yaml | awk '{print $1,$2}')
    [ "$before_hash" = "$after_hash" ]
}

@test "simplify dry-run flags redundant fields and file-would-delete" {
    run_agentsync customize cursor --full >/dev/null

    run run_agentsync simplify
    [ "$status" -eq 0 ]
    [[ "$output" == *"Redundant"* ]]
    [[ "$output" == *"targets.rules.dest"* ]]
    [[ "$output" == *"would delete the override file"* ]]
}

@test "simplify dry-run reports remove-count when some fields stay" {
    run_agentsync customize cursor --full >/dev/null
    # Mutate one field so not every field is redundant. parse_yaml_value
    # returns the first match, so overwrite the file rather than appending.
    cat > .ai/src/tools/cursor.yaml <<'YAML'
name: "Cursor"
enabled: true

targets:
  rules:
    dest: ".cursor/rules"
    extension: ".mdc"
YAML

    run run_agentsync simplify
    [ "$status" -eq 0 ]
    [[ "$output" == *"would remove"* ]]
    [[ "$output" != *"would delete the override file"* ]]
}

# ── --apply removes redundant fields ─────────────────────────────────────────

@test "simplify --apply removes redundant fields and keeps diverging ones" {
    run_agentsync customize cursor --full >/dev/null
    # Override rules.extension so it diverges from base.
    cat > .ai/src/tools/cursor.yaml <<'YAML'
name: "Cursor"
enabled: true

targets:
  rules:
    dest: ".cursor/rules"
    extension: ".mdcustom"
YAML

    run run_agentsync simplify --apply -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"Removed"* ]]

    [ -f ".ai/src/tools/cursor.yaml" ]
    grep -q "extension: \".mdcustom\"" .ai/src/tools/cursor.yaml
    grep -q "^enabled: true" .ai/src/tools/cursor.yaml
    ! grep -q "^name:" .ai/src/tools/cursor.yaml
    ! grep -q "dest: \".cursor/rules\"" .ai/src/tools/cursor.yaml
}

@test "simplify --apply -y deletes override when all fields match base" {
    run_agentsync customize cursor --full >/dev/null
    [ -f ".ai/src/tools/cursor.yaml" ]

    run run_agentsync simplify --apply -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"Deleted"* ]]
    [ ! -f ".ai/src/tools/cursor.yaml" ]
}

@test "simplify --apply keeps empty file when no -y and no TTY" {
    run_agentsync customize cursor --full >/dev/null

    run run_agentsync simplify --apply
    [ "$status" -eq 0 ]
    [ -f ".ai/src/tools/cursor.yaml" ]
    [[ "$output" == *"Kept empty file"* ]]
    # Post-removal, file should have no real key: value content.
    ! grep -Eq '^[[:space:]]*[a-zA-Z0-9_-]+:[[:space:]]+\S' .ai/src/tools/cursor.yaml
}

# ── Idempotency ───────────────────────────────────────────────────────────────

@test "simplify --apply is idempotent (second run is a no-op)" {
    run_agentsync customize cursor --full >/dev/null
    cat > .ai/src/tools/cursor.yaml <<'YAML'
name: "Cursor"
enabled: true

targets:
  rules:
    dest: ".cursor/rules"
    extension: ".mdcustom"
YAML

    run_agentsync simplify --apply -y >/dev/null
    local snapshot
    snapshot=$(cksum .ai/src/tools/cursor.yaml | awk '{print $1,$2}')

    run run_agentsync simplify --apply -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"No redundant fields"* ]]

    local after
    after=$(cksum .ai/src/tools/cursor.yaml | awk '{print $1,$2}')
    [ "$snapshot" = "$after" ]
}

# ── Per-tool filter ───────────────────────────────────────────────────────────

@test "simplify <tool> only touches that tool" {
    run_agentsync customize cursor --full >/dev/null
    run_agentsync customize claude --full >/dev/null
    [ -f ".ai/src/tools/cursor.yaml" ]
    [ -f ".ai/src/tools/claude.yaml" ]

    run run_agentsync simplify cursor --apply -y
    [ "$status" -eq 0 ]

    # cursor override deleted, claude untouched.
    [ ! -f ".ai/src/tools/cursor.yaml" ]
    [ -f ".ai/src/tools/claude.yaml" ]
}

@test "simplify <tool> only reports that tool in dry-run" {
    run_agentsync customize cursor --full >/dev/null
    run_agentsync customize claude --full >/dev/null

    run run_agentsync simplify cursor
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cursor"* ]]
    [[ "$output" != *"Claude Code"* ]]
}

# ── Phase 6: payload overrides (hooks / mcp / settings) ─────────────────────
#
# These tests hand-place scaffolded-but-unchanged payload copies that mirror
# what `init --tools cursor` would produce. Setup already ran a minimal init,
# so we only need to add the payloads to exercise the simplify path.

_scaffold_cursor_payloads() {
    local base_hooks base_mcp
    base_hooks="$REPO_ROOT/lib/templates/hooks/cursor.json"
    base_mcp="$REPO_ROOT/lib/templates/mcp/cursor.json"
    mkdir -p .ai/src/hooks .ai/src/mcp
    cp "$base_hooks" .ai/src/hooks/cursor.json
    cp "$base_mcp"   .ai/src/mcp/cursor.json
}

@test "simplify --apply removes byte-identical payload overrides" {
    _scaffold_cursor_payloads
    [ -f ".ai/src/hooks/cursor.json" ]
    [ -f ".ai/src/mcp/cursor.json" ]

    run run_agentsync simplify --apply -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"Payload overrides"* ]]

    # Scaffolded-but-unchanged copies are gone; sync now uses base directly.
    [ ! -f ".ai/src/hooks/cursor.json" ]
    [ ! -f ".ai/src/mcp/cursor.json" ]
}

@test "simplify keeps payload overrides that diverge from base" {
    _scaffold_cursor_payloads
    echo '{"marker":"USER_EDIT"}' > .ai/src/hooks/cursor.json

    run run_agentsync simplify --apply -y
    [ "$status" -eq 0 ]

    # Diverged override preserved; unchanged MCP removed.
    [ -f ".ai/src/hooks/cursor.json" ]
    grep -q "USER_EDIT" .ai/src/hooks/cursor.json
    [ ! -f ".ai/src/mcp/cursor.json" ]
}

@test "simplify dry-run on payloads reports byte-identical files" {
    _scaffold_cursor_payloads

    run run_agentsync simplify
    [ "$status" -eq 0 ]
    [[ "$output" == *"Byte-identical"* ]]
    [[ "$output" == *"would delete"* ]]

    # Dry-run must not mutate.
    [ -f ".ai/src/hooks/cursor.json" ]
    [ -f ".ai/src/mcp/cursor.json" ]
}
