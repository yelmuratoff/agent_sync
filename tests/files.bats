#!/usr/bin/env bats
# Tests for internal file utilities (sync_dir, sync_rules, merge_rules_to_file, etc.)

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

@test "matches_filter: include glob still matches when cwd holds matching files" {
    # Regression (HIGH-1): the pattern must not undergo pathname expansion
    # against the cwd. With `README.md` present, an unquoted `for pat in $include`
    # would expand `*.md` to `README.md` and drop the real pattern.
    cd "$TEST_PROJECT"
    : > "$TEST_PROJECT/README.md"
    : > "$TEST_PROJECT/other.md"
    run matches_filter "core.md" "*.md" ""
    [ "$status" -eq 0 ]
}

@test "matches_filter: exclude glob still rejects when cwd holds matching files" {
    cd "$TEST_PROJECT"
    : > "$TEST_PROJECT/README.md"
    run matches_filter "secret.md" "" "*.md"
    [ "$status" -eq 1 ]
}

@test "matches_filter: multi-pattern include is unaffected by cwd files" {
    cd "$TEST_PROJECT"
    : > "$TEST_PROJECT/a.md"
    : > "$TEST_PROJECT/b.txt"
    run matches_filter "core.md" "*.txt *.md" ""
    [ "$status" -eq 0 ]
    run matches_filter "core.yaml" "*.txt *.md" ""
    [ "$status" -eq 1 ]
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

# ── merge_or_prepend_header ──────────────────────────────────────────────────

@test "merge_or_prepend_header: prepends when source has no frontmatter" {
    echo "body" > "$TEST_PROJECT/file.md"
    merge_or_prepend_header "$TEST_PROJECT/file.md" "---\nglobs: '**/*'\n---"
    [ "$(head -n1 "$TEST_PROJECT/file.md")" = "---" ]
    grep -q "globs: '\*\*/\*'" "$TEST_PROJECT/file.md"
    grep -q "body" "$TEST_PROJECT/file.md"
}

@test "merge_or_prepend_header: adds missing keys to existing frontmatter" {
    cat > "$TEST_PROJECT/file.md" <<'EOF'
---
description: Custom description
---
body
EOF
    merge_or_prepend_header "$TEST_PROJECT/file.md" "---\nglobs: '**/*'\nalwaysApply: true\n---"
    grep -q "description: Custom description" "$TEST_PROJECT/file.md"
    grep -q "globs: '\*\*/\*'" "$TEST_PROJECT/file.md"
    grep -q "alwaysApply: true" "$TEST_PROJECT/file.md"
    # Single frontmatter block — exactly two `---` markers
    [ "$(grep -c '^---$' "$TEST_PROJECT/file.md")" -eq 2 ]
}

@test "merge_or_prepend_header: source value wins on conflict" {
    cat > "$TEST_PROJECT/file.md" <<'EOF'
---
globs: "**/*.ts"
---
body
EOF
    merge_or_prepend_header "$TEST_PROJECT/file.md" "---\nglobs: '**/*'\nalwaysApply: true\n---"
    # Source's globs preserved; tool default discarded
    grep -q 'globs: "\*\*/\*\.ts"' "$TEST_PROJECT/file.md"
    ! grep -q "globs: '\*\*/\*'" "$TEST_PROJECT/file.md"
    # Non-conflicting key from header still added
    grep -q "alwaysApply: true" "$TEST_PROJECT/file.md"
}

@test "merge_or_prepend_header: no-op when all keys already present" {
    cat > "$TEST_PROJECT/file.md" <<'EOF'
---
globs: "**/*.ts"
alwaysApply: false
---
body
EOF
    local before
    before=$(cat "$TEST_PROJECT/file.md")
    merge_or_prepend_header "$TEST_PROJECT/file.md" "---\nglobs: '**/*'\nalwaysApply: true\n---"
    [ "$(cat "$TEST_PROJECT/file.md")" = "$before" ]
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

@test "merge_rules_to_file: empty rules dir does not abort under set -u" {
    # Regression (HIGH-2): iterating an empty array is a fatal "unbound variable"
    # on bash 3.2 under set -u, and it fires after the dest file is removed.
    set -u
    mkdir -p "$TEST_PROJECT/rules"
    run merge_rules_to_file "$TEST_PROJECT/rules" "$TEST_PROJECT/merged.md"
    [ "$status" -eq 0 ]
}

@test "merge_rules_to_file: empty rules dir still writes prepended agents" {
    set -u
    mkdir -p "$TEST_PROJECT/rules"
    echo "# Agent" > "$TEST_PROJECT/agents.md"
    run merge_rules_to_file "$TEST_PROJECT/rules" "$TEST_PROJECT/merged.md" "false" "" "" "$TEST_PROJECT/agents.md"
    [ "$status" -eq 0 ]
    grep -q "Agent" "$TEST_PROJECT/merged.md"
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

# ── TOML conversion escaping ─────────────────────────────────────────────────

@test "convert_md_command_to_toml: escapes quotes in description" {
    cat > "$TEST_PROJECT/cmd.md" <<'MD'
---
description: Say "hello" to the \user
---
Body.
MD
    convert_md_command_to_toml "$TEST_PROJECT/cmd.md" "$TEST_PROJECT/cmd.toml"
    # The description line must be a valid single-line basic string.
    grep -qF 'description = "Say \"hello\" to the \\user"' "$TEST_PROJECT/cmd.toml"
}

@test "convert_md_agent_to_toml: escapes quotes in name and description" {
    cat > "$TEST_PROJECT/agent.md" <<'MD'
---
name: my"agent
description: A "quoted" agent
---
Body.
MD
    convert_md_agent_to_toml "$TEST_PROJECT/agent.md" "$TEST_PROJECT/agent.toml"
    grep -qF 'name = "my\"agent"' "$TEST_PROJECT/agent.toml"
    grep -qF 'description = "A \"quoted\" agent"' "$TEST_PROJECT/agent.toml"
}

@test "sync_commands_as_toml: differential cleanup removes orphaned toml" {
    mkdir -p "$TEST_PROJECT/cmds"
    printf -- '---\ndescription: A\n---\nBody\n' > "$TEST_PROJECT/cmds/a.md"
    printf -- '---\ndescription: B\n---\nBody\n' > "$TEST_PROJECT/cmds/b.md"
    sync_commands_as_toml "$TEST_PROJECT/cmds" "$TEST_PROJECT/out"
    [ -f "$TEST_PROJECT/out/a.toml" ]
    [ -f "$TEST_PROJECT/out/b.toml" ]
    # Delete a source; re-sync must drop the orphaned generated file.
    rm "$TEST_PROJECT/cmds/b.md"
    sync_commands_as_toml "$TEST_PROJECT/cmds" "$TEST_PROJECT/out"
    [ -f "$TEST_PROJECT/out/a.toml" ]
    [ ! -f "$TEST_PROJECT/out/b.toml" ]
}

@test "sync_agents_as_amazonq_json: differential cleanup removes orphaned json" {
    mkdir -p "$TEST_PROJECT/agents"
    printf -- '---\nname: a\ndescription: A\n---\nBody\n' > "$TEST_PROJECT/agents/a.md"
    printf -- '---\nname: b\ndescription: B\n---\nBody\n' > "$TEST_PROJECT/agents/b.md"
    sync_agents_as_amazonq_json "$TEST_PROJECT/agents" "$TEST_PROJECT/out"
    [ -f "$TEST_PROJECT/out/a.json" ]
    [ -f "$TEST_PROJECT/out/b.json" ]
    rm "$TEST_PROJECT/agents/a.md"
    sync_agents_as_amazonq_json "$TEST_PROJECT/agents" "$TEST_PROJECT/out"
    [ ! -f "$TEST_PROJECT/out/a.json" ]
    [ -f "$TEST_PROJECT/out/b.json" ]
}
