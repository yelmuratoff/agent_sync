#!/usr/bin/env bats
load test_helper

setup() {
    setup_test_project
    run_agentsync init --no-detect >/dev/null
    enable_tools claude opencode
    mkdir -p .ai/src/tools
    CATALOG="$TEST_PROJECT/catalog/mcp"
    mkdir -p "$CATALOG"
    cp -R "$REPO_ROOT/tests/fixtures/mcp_library/stdio" "$CATALOG/stdio"
    cp -R "$REPO_ROOT/tests/fixtures/mcp_library/http" "$CATALOG/http"
}

teardown() { teardown_test_project; }

@test "library render creates a combined MCP source without native writes" {
    run run_agentsync mcp render http stdio --library "$CATALOG"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"mcpServers":{'* ]]
    [[ "$output" == *'"type":"http"'* ]]
    [[ "$output" == *'"command":"printf"'* ]]
    [ ! -f .mcp.json ]
    [ ! -f .ai/src/tools/claude/mcp.json ]
}

@test "library use previews by default without requiring writable TMPDIR" {
    run env TMPDIR="$TEST_PROJECT/absent" AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" mcp use http --tool claude --library "$CATALOG"
    [ "$status" -eq 0 ]
    [[ "$output" == *Preview:* ]]
    [ ! -f .ai/src/tools/claude/mcp.json ]
    [ ! -e "$TEST_PROJECT/absent" ]
}

@test "library source apply is separate from Claude native sync and is idempotent" {
    run run_agentsync mcp use http stdio --tool claude --library "$CATALOG" --apply
    [ "$status" -eq 0 ]
    [ -f .ai/src/tools/claude/mcp.json ]
    [ ! -f .mcp.json ]
    local before
    before=$(file_sha256 .ai/src/tools/claude/mcp.json)
    run run_agentsync mcp use http stdio --tool claude --library "$CATALOG" --apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"already matches"* ]]
    [ "$before" = "$(file_sha256 .ai/src/tools/claude/mcp.json)" ]
    run run_agentsync sync --only claude
    [ "$status" -eq 0 ]
    cmp .ai/src/tools/claude/mcp.json .mcp.json
}

@test "library source reaches the existing OpenCode translator" {
    run run_agentsync mcp use http stdio --tool opencode --library "$CATALOG" --apply
    [ "$status" -eq 0 ] || { printf 'OpenCode source materialization failed:\n%s\n' "$output" >&2; return 1; }
    [ ! -f opencode.json ]
    run run_agentsync sync --only opencode
    [ "$status" -eq 0 ] || { printf 'OpenCode translation failed:\n%s\n' "$output" >&2; return 1; }
    grep -q '"type": "remote"\|"type":"remote"' opencode.json
    grep -q '"type": "local"\|"type":"local"' opencode.json
    grep -q 'printf' opencode.json
    ! grep -q 'mcpServers' opencode.json
}

@test "library use preserves a preexisting native config until explicit sync" {
    printf '%s\n' '{"private":"untouched"}' > .mcp.json
    local before
    before=$(file_sha256 .mcp.json)
    run run_agentsync mcp use http --tool claude --library "$CATALOG" --apply
    [ "$status" -eq 0 ]
    [ "$before" = "$(file_sha256 .mcp.json)" ]
}

@test "library use refuses differing per-tool sources unchanged" {
    mkdir -p .ai/src/tools/claude
    printf '%s\n' '{"mcpServers":{"mine":{"command":"keep"}}}' > .ai/src/tools/claude/mcp.json
    local before
    before=$(file_sha256 .ai/src/tools/claude/mcp.json)
    run run_agentsync mcp use http --tool claude --library "$CATALOG" --apply
    [ "$status" -ne 0 ]
    [[ "$output" == *"source differs"* ]]
    [ "$before" = "$(file_sha256 .ai/src/tools/claude/mcp.json)" ]
}

@test "library use does not shadow shared legacy or alternate sources" {
    local file
    for file in .ai/src/mcp.json .ai/src/mcp/claude.json .ai/src/tools/claude/mcp.toml; do
        mkdir -p "${file%/*}"
        printf '%s\n' '{}' > "$file"
        run run_agentsync mcp use http --tool claude --library "$CATALOG" --apply
        [ "$status" -ne 0 ]
        [[ "$output" == *"would be shadowed"* ]]
        [ ! -e .ai/src/tools/claude/mcp.json ]
        rm "$file"
    done
}

@test "library use refuses shadowing a custom declared source" {
    printf '%s\n' 'targets:' '  mcp:' '    source: custom.json' > .ai/src/tools/claude.yaml
    printf '%s\n' '{}' > custom.json
    run run_agentsync mcp use http --tool claude --library "$CATALOG" --apply
    [ "$status" -ne 0 ]
    [[ "$output" == *"Declared MCP source would be shadowed"* ]]
    [ ! -e .ai/src/tools/claude/mcp.json ]
}

@test "library use refuses a symlink in the target path" {
    mkdir -p elsewhere
    create_test_symlink "$TEST_PROJECT/elsewhere" .ai/src/tools/claude
    run run_agentsync mcp use http --tool claude --library "$CATALOG" --apply
    [ "$status" -ne 0 ]
    [[ "$output" == *"through a symlink"* ]]
    [ ! -e elsewhere/mcp.json ]
}

@test "library use respects a declared source even before it exists" {
    printf '%s\n' 'targets:' '  mcp:' '    source: future-mcp.json' > .ai/src/tools/claude.yaml
    run run_agentsync mcp use http --tool claude --library "$CATALOG" --apply
    [ "$status" -ne 0 ]
    [[ "$output" == *"Declared MCP source would be shadowed"* ]]
    [ ! -e .ai/src/tools/claude/mcp.json ]
    [ ! -e future-mcp.json ]
}

@test "library use accepts an explicit canonical source but rechecks changed declarations" {
    printf '%s\n' 'targets:' '  mcp:' '    source: .ai/src/tools/claude/mcp.json' > .ai/src/tools/claude.yaml
    run run_agentsync mcp use http --tool claude --library "$CATALOG" --apply
    [ "$status" -eq 0 ]
    local before
    before=$(file_sha256 .ai/src/tools/claude/mcp.json)
    printf '%s\n' 'targets:' '  mcp:' '    source: future-mcp.json' > .ai/src/tools/claude.yaml
    run run_agentsync mcp use http --tool claude --library "$CATALOG" --apply
    [ "$status" -ne 0 ]
    [[ "$output" == *"Declared MCP source would be shadowed"* ]]
    [ "$before" = "$(file_sha256 .ai/src/tools/claude/mcp.json)" ]
}

@test "library use refuses even an identical source symlink" {
    run_agentsync mcp render http --library "$CATALOG" > existing.json
    mkdir -p .ai/src/tools/claude
    create_test_symlink "$TEST_PROJECT/existing.json" .ai/src/tools/claude/mcp.json
    run run_agentsync mcp use http --tool claude --library "$CATALOG" --apply
    [ "$status" -ne 0 ]
    [ -L .ai/src/tools/claude/mcp.json ]
}

@test "library use honors an in-project custom source.tools path" {
    printf '%s\n' 'source:' '  tools: custom/tools' 'tools:' '  enabled:' '    - claude' > .ai/agent_sync.yaml
    run run_agentsync mcp use http --tool claude --library "$CATALOG" --apply
    [ "$status" -eq 0 ]
    [ -f custom/tools/claude/mcp.json ]
    [ ! -f .ai/src/tools/claude/mcp.json ]
    run run_agentsync sync --only claude
    [ "$status" -eq 0 ]
    cmp custom/tools/claude/mcp.json .mcp.json
}

@test "library use cannot write an external source.tools path" {
    printf '%s\n' 'source:' '  tools: ../outside' 'tools:' '  enabled:' '    - claude' > .ai/agent_sync.yaml
    run run_agentsync mcp use http --tool claude --library "$CATALOG" --apply
    [ "$status" -ne 0 ]
    [[ "$output" == *"outside the project"* ]]
}

@test "library use fails closed for missing explicit config and disabled clients" {
    run env AGENTSYNC_CONFIG_PATH=missing.yaml AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" mcp use http --tool claude --library "$CATALOG" --apply
    [ "$status" -ne 0 ]
    [[ "$output" == *"file not found"* ]]
    printf '%s\n' 'tools:' '  enabled:' '    - opencode' > .ai/agent_sync.yaml
    run run_agentsync mcp use http --tool claude --library "$CATALOG" --apply
    [ "$status" -ne 0 ]
    [[ "$output" == *"Enable claude explicitly"* ]]
}

@test "library render rejects bad selections before emitting source JSON" {
    local selection
    for selection in '../http' 'http@' 'http@bad/name' 'http@missing'; do
        run run_agentsync mcp render "$selection" --library "$CATALOG"
        [ "$status" -ne 0 ]
        [[ "$output" != *'"mcpServers"'* ]]
    done
    run run_agentsync mcp render http http --library "$CATALOG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Duplicate selected"* ]]
}

@test "library use rejects unsupported tools and conflicting flags" {
    run run_agentsync mcp use http --tool cursor --library "$CATALOG" --apply
    [ "$status" -ne 0 ]
    [[ "$output" == *"not supported yet"* ]]
    run run_agentsync mcp use http --tool claude --library "$CATALOG" --apply --dry-run
    [ "$status" -ne 0 ]
    run run_agentsync mcp render http --library "$CATALOG" --apply
    [ "$status" -ne 0 ]
}

@test "library use validates every selected manifest before any write" {
    printf '%s\n' '{bad' > "$CATALOG/stdio/manifest.json"
    run run_agentsync mcp use http stdio --tool claude --library "$CATALOG" --apply
    [ "$status" -ne 0 ]
    [ ! -e .ai/src/tools/claude/mcp.json ]
}

@test "library recommended remote variant reaches native config only when explicitly selected" {
    mkdir -p "$CATALOG/example"
    cp "$REPO_ROOT/tests/fixtures/mcp_library_v2/recommended-remote/manifest.json" "$CATALOG/example/manifest.json"
    run run_agentsync mcp render example --library "$CATALOG"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"command":"example-local"'* ]]
    run run_agentsync mcp use example@recommended --tool opencode --library "$CATALOG" --apply
    [ "$status" -eq 0 ]
    grep -q '"type":"http"' .ai/src/tools/opencode/mcp.json
    ! grep -q 'example-local\|guidance\|authority' .ai/src/tools/opencode/mcp.json
    run run_agentsync sync --only opencode
    [ "$status" -eq 0 ]
    grep -q '"type": "remote"\|"type":"remote"' opencode.json
}

@test "library cannot invent a recommendation for a v1 entry" {
    run run_agentsync mcp use http@recommended --tool claude --library "$CATALOG" --apply
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires guidance"* ]]
    [ ! -e .ai/src/tools/claude/mcp.json ]
}
