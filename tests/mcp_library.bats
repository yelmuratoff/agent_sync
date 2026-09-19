#!/usr/bin/env bats
# Read-only MCP library format v1.

load test_helper

setup() {
    setup_test_project
    CATALOG="$TEST_PROJECT/catalog/mcp"
    mkdir -p "$CATALOG"
    cp -R "$REPO_ROOT/tests/fixtures/mcp_library/stdio" "$CATALOG/stdio"
    cp -R "$REPO_ROOT/tests/fixtures/mcp_library/http" "$CATALOG/http"
}

teardown() {
    teardown_test_project
}

@test "mcp help does not need a configured library" {
    run run_agentsync mcp --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"agentsync mcp list"* ]]
}

@test "mcp read-only commands do not require a writable TMPDIR" {
    local readonly_tmp="$TEST_PROJECT/readonly-tmp"
    mkdir "$readonly_tmp"
    chmod 500 "$readonly_tmp"

    run env TMPDIR="$readonly_tmp" AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" mcp --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"agentsync mcp list"* ]]

    run env TMPDIR="$readonly_tmp" AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" mcp validate --library "$CATALOG"
    [ "$status" -eq 0 ]

    run env TMPDIR="$readonly_tmp" AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" mcp list --library "$CATALOG"
    [ "$status" -eq 0 ]
    run env TMPDIR="$readonly_tmp" AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" mcp show stdio --library "$CATALOG"
    [ "$status" -eq 0 ]
}

@test "mcp parser helper succeeds in its default validation mode" {
    run bash -c 'source "$1"; _mcp_library_parser "$2"' bash \
        "$REPO_ROOT/lib/helpers/mcp_library.sh" "$CATALOG/stdio/manifest.json"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "mcp rejects missing and explicitly empty library selections" {
    run run_agentsync mcp list
    [ "$status" -ne 0 ]
    [[ "$output" == *"No MCP library selected"* ]]
    run run_agentsync mcp list --library ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"non-empty path"* ]]
}

@test "mcp does not fall back from a missing explicit config" {
    mkdir -p .ai
    printf '%s\n' 'library:' '  mcp:' '    path: catalog/mcp' > .ai/agent_sync.yaml
    export AGENTSYNC_CONFIG_PATH="$TEST_PROJECT/missing.yaml"
    run run_agentsync mcp validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"AGENTSYNC_CONFIG_PATH is set but file not found"* ]]
}

@test "mcp rejects an escaping manifest symlink" {
    mv "$CATALOG/stdio/manifest.json" "$TEST_PROJECT/outside.json"
    create_test_symlink "$TEST_PROJECT/outside.json" "$CATALOG/stdio/manifest.json"
    run run_agentsync mcp show stdio --library "$CATALOG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"outside the selected catalog"* ]]
}

@test "mcp rejects unsafe requested ids and unknown versions" {
    run run_agentsync mcp show ../stdio --library "$CATALOG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unsafe MCP library id"* ]]
    printf '%s\n' '{"schema_version":99,"id":"stdio","title":"x","connection":{"type":"stdio","command":"x","args":[]},"requirements":{"binaries":[],"inputs":[]}}' > "$CATALOG/stdio/manifest.json"
    run run_agentsync mcp validate stdio --library "$CATALOG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsupported schema_version"* ]]
}

@test "mcp rejects an oversized manifest and excessive nesting" {
    awk 'BEGIN { for (i=0; i<131073; i++) printf " " }' > "$CATALOG/stdio/manifest.json"
    run run_agentsync mcp validate stdio --library "$CATALOG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"byte limit"* ]]
    printf '%s\n' '[[[[[[[[[[[[[[[[[0]]]]]]]]]]]]]]]]]' > "$CATALOG/stdio/manifest.json"
    run run_agentsync mcp validate stdio --library "$CATALOG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"depth limit"* ]]
}

@test "mcp accepts exact manifest byte limits with and without a final newline" {
    local manifest="$CATALOG/stdio/manifest.json"
    local prefix='{"schema_version":1,"id":"stdio","title":"'
    local suffix='","connection":{"type":"stdio","command":"x","args":[]},"requirements":{"binaries":[],"inputs":[]}}'
    local no_newline_fill=$((131072 - ${#prefix} - ${#suffix}))
    local newline_fill=$((131071 - ${#prefix} - ${#suffix}))

    LC_ALL=C awk -v count="$no_newline_fill" -v prefix="$prefix" -v suffix="$suffix" \
        'BEGIN { printf "%s", prefix; for (i = 0; i < count; i++) printf "x"; printf "%s", suffix }' > "$manifest"
    run run_agentsync mcp validate stdio --library "$CATALOG"
    [ "$status" -eq 0 ]

    LC_ALL=C awk -v count="$newline_fill" -v prefix="$prefix" -v suffix="$suffix" \
        'BEGIN { printf "%s", prefix; for (i = 0; i < count; i++) printf "x"; printf "%s\n", suffix }' > "$manifest"
    run run_agentsync mcp validate stdio --library "$CATALOG"
    [ "$status" -eq 0 ]

    printf '\n' >> "$manifest"
    run run_agentsync mcp validate stdio --library "$CATALOG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"byte limit"* ]]
}

@test "mcp rejects an oversized catalog rather than reporting valid empty input" {
    local n
    for ((n=0; n<257; n++)); do mkdir "$CATALOG/entry-$n"; done
    run run_agentsync mcp validate --library "$CATALOG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"entry limit"* ]]
}

@test "mcp list reads explicit catalog deterministically without executing servers" {
    run run_agentsync mcp list --library "$CATALOG"

    [ "$status" -eq 0 ]
    [ "$output" = $'http\tRemote docs\nstdio\tLocal printf' ]
}

@test "mcp show accepts --library after id and preserves source JSON" {
    run run_agentsync mcp show stdio --library "$CATALOG"

    [ "$status" -eq 0 ]
    [[ "$output" == *'"hello world", "quote: \\\"", "Grüße"'* ]]
    [[ "$output" == *'"command": "printf"'* ]]
}

@test "mcp validate accepts the requested explicit-library form" {
    run run_agentsync mcp validate --library "$CATALOG"

    [ "$status" -eq 0 ]
    [[ "$output" == *"MCP library is valid"* ]]
}

@test "mcp list escapes title controls instead of writing terminal control bytes" {
    sed 's/"Local printf"/"Local\\n\\tprintf"/' "$CATALOG/stdio/manifest.json" > "$CATALOG/stdio/manifest.json.tmp"
    mv "$CATALOG/stdio/manifest.json.tmp" "$CATALOG/stdio/manifest.json"

    run run_agentsync mcp list --library "$CATALOG"

    [ "$status" -eq 0 ]
    [[ "$output" == *$'stdio\tLocal\\n\\tprintf'* ]]
}

@test "mcp list escapes UTF-8 C1 title controls" {
    sed 's/"Local printf"/"Local\\u0080\\u0085\\u009b\\u009fprintf"/' "$CATALOG/stdio/manifest.json" > "$CATALOG/stdio/manifest.json.tmp"
    mv "$CATALOG/stdio/manifest.json.tmp" "$CATALOG/stdio/manifest.json"

    run run_agentsync mcp list --library "$CATALOG"

    [ "$status" -eq 0 ]
    [[ "$output" == *$'stdio\tLocal\\u0080\\u0085\\u009b\\u009fprintf'* ]]
}

@test "mcp accepts escaped NUL data and rejects malformed JSON forms" {
    local manifest="$CATALOG/stdio/manifest.json"
    printf '%s\n' '{"schema_version":1,"id":"stdio","title":"x","description":"NUL\u0000data","connection":{"type":"stdio","command":"x","args":["\u0000"]},"requirements":{"binaries":[],"inputs":[]}}' > "$manifest"
    run run_agentsync mcp validate stdio --library "$CATALOG"
    [ "$status" -eq 0 ]
    run run_agentsync mcp show stdio --library "$CATALOG"
    [ "$status" -eq 0 ]
    [[ "$output" == *'\u0000'* ]]

    printf '%b' '{"schema_version":1,"id":"stdio","title":"x","description":"raw\0NUL","connection":{"type":"stdio","command":"x","args":[]},"requirements":{"binaries":[],"inputs":[]}}' > "$manifest"
    run run_agentsync mcp validate stdio --library "$CATALOG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"raw NUL"* ]]
    run run_agentsync mcp show stdio --library "$CATALOG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"raw NUL"* ]]

    printf '%s\0' '{"schema_version":1,"id":"stdio","title":"x","connection":{"type":"stdio","command":"x","args":[]},"requirements":{"binaries":[],"inputs":[]}}' > "$manifest"
    run run_agentsync mcp validate stdio --library "$CATALOG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"raw NUL"* ]]
    run run_agentsync mcp show stdio --library "$CATALOG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"raw NUL"* ]]

    printf '%s\n' '{"schema_version":1,"id":"stdio","title":"x",}' > "$manifest"
    run run_agentsync mcp validate stdio --library "$CATALOG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"expected JSON string"* || "$output" == *"expected comma"* ]]

    printf '%s' '{"schema_version":1,"id":"stdio"' > "$manifest"
    run run_agentsync mcp validate stdio --library "$CATALOG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unterminated JSON object"* || "$output" == *"expected comma in JSON object"* ]]
}

@test "mcp validates a selected entry" {
    run run_agentsync mcp validate stdio --library "$CATALOG"

    [ "$status" -eq 0 ]
    [[ "$output" == *"MCP library entry is valid: stdio"* ]]
}

@test "mcp uses library.mcp.path relative to the selected root" {
    mkdir -p .ai
    printf '%s\n' 'library:' '  mcp:' '    path: catalog/mcp' > .ai/agent_sync.yaml

    run run_agentsync mcp validate

    [ "$status" -eq 0 ]
}

@test "mcp rejects malformed JSON and escaped-equivalent duplicate keys" {
    printf '%s\n' '{"schema_version":1,"id":"stdio","\u0069d":"other","title":"x","connection":{"type":"stdio","command":"x","args":[]},"requirements":{"binaries":[],"inputs":[]}}' > "$CATALOG/stdio/manifest.json"

    run run_agentsync mcp validate stdio --library "$CATALOG"

    [ "$status" -ne 0 ]
    [[ "$output" == *"duplicate JSON key 'id'"* ]]
}

@test "mcp rejects duplicate catalog IDs before directory mismatch diagnostics" {
    cp -R "$CATALOG/stdio" "$CATALOG/other"

    run run_agentsync mcp validate --library "$CATALOG"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Duplicate MCP library id 'stdio'"* ]]
}

@test "mcp rejects unknown schema fields and unsupported input binding" {
    printf '%s\n' '{"schema_version":1,"id":"stdio","title":"x","unknown":true,"connection":{"type":"stdio","command":"x","args":[]},"requirements":{"binaries":[],"inputs":[]}}' > "$CATALOG/stdio/manifest.json"
    run run_agentsync mcp validate stdio --library "$CATALOG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown top-level field 'unknown'"* ]]

    printf '%s\n' '{"schema_version":1,"id":"stdio","title":"x","connection":{"type":"stdio","command":"x","args":[]},"requirements":{"binaries":[],"inputs":["TOKEN"]}}' > "$CATALOG/stdio/manifest.json"
    run run_agentsync mcp validate stdio --library "$CATALOG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"requirements.inputs is unsupported"* ]]
}

@test "mcp rejects catalog symlink entries and configured paths escaping root" {
    mkdir -p "$TEST_PROJECT/outside/escape"
    cp "$CATALOG/stdio/manifest.json" "$TEST_PROJECT/outside/escape/manifest.json"
    create_test_symlink "$TEST_PROJECT/outside/escape" "$CATALOG/escape"

    run run_agentsync mcp validate --library "$CATALOG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"must not be a symlink"* ]]

    create_test_symlink /tmp "$TEST_PROJECT/catalog-link"
    mkdir -p .ai
    printf '%s\n' 'library:' '  mcp:' '    path: catalog-link' > .ai/agent_sync.yaml
    run run_agentsync mcp validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"resolves outside the selected root"* ]]
}
