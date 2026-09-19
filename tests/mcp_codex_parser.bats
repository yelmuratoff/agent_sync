#!/usr/bin/env bats
# Parser-only Codex MCP source coverage. Inputs are regular files.

load test_helper

setup() {
    setup_test_project
    PARSER="$REPO_ROOT/lib/helpers/mcp_library_parser.awk"
    SOURCE="$TEST_PROJECT/codex-source.json"
}

teardown() {
    teardown_test_project
}

write_source() {
    printf '%s' "$1" > "$SOURCE"
}

run_codex_parser() {
    local awk_bin="$1"
    local source="$2"

    LC_ALL=C "$awk_bin" \
        -v max_depth=16 \
        -v max_bytes=131072 \
        -v output_mode=codex-source \
        -f "$PARSER" "$source"
}

available_awk_variants() {
    printf '%s\n' awk
    command -v mawk >/dev/null 2>&1 && printf '%s\n' mawk
    command -v gawk >/dev/null 2>&1 && printf '%s\n' gawk
}

assert_toml_json() {
    local rendered="$1"
    local expected="$2"
    local toml_file="$TEST_PROJECT/settings.toml"

    printf '%s\n' "$rendered" > "$toml_file"
    python3 -c '
import json
import sys
import tomllib

with open(sys.argv[1], "rb") as source:
    actual = tomllib.load(source)
expected = json.loads(sys.argv[2])
assert actual == expected, (actual, expected)
' "$toml_file" "$expected"
}

@test "codex-source emits TOML that round-trips stdio and HTTP data" {
    write_source '{"mcpServers":{"alpha":{"command":"printf","args":["quote: \"","line\nbreak","nul\u0000data","C1 \u009b","Grüße"]},"remote":{"type":"http","url":"https://example.invalid/mcp"}}}'

    local awk_bin rendered
    while IFS= read -r awk_bin; do
        run run_codex_parser "$awk_bin" "$SOURCE"
        [ "$status" -eq 0 ]
        rendered="$output"
        [[ "$rendered" == 'mcp_servers = {'* ]]
        [[ "$rendered" == *'"C1 \u009b"'* ]]

        run assert_toml_json "$rendered" '{"mcp_servers":{"alpha":{"command":"printf","args":["quote: \"","line\nbreak","nul\u0000data","C1 \u009b","Grüße"]},"remote":{"url":"https://example.invalid/mcp"}}}'
        [ "$status" -eq 0 ]
    done < <(available_awk_variants)
}

@test "codex-source permits an empty server map" {
    write_source '{"mcpServers":{}}'

    local awk_bin
    while IFS= read -r awk_bin; do
        run run_codex_parser "$awk_bin" "$SOURCE"
        [ "$status" -eq 0 ]
        [ "$output" = 'mcp_servers = { }' ]

        run assert_toml_json "$output" '{"mcp_servers":{}}'
        [ "$status" -eq 0 ]
    done < <(available_awk_variants)
}

@test "codex-source rejects more than 256 servers before TOML output" {
    local n
    {
        printf '%s' '{"mcpServers":{'
        for ((n = 0; n < 257; n++)); do
            ((n > 0)) && printf ','
            printf '"server%s":{"command":"printf","args":[]}' "$n"
        done
        printf '%s' '}}'
    } > "$SOURCE"

    run run_codex_parser awk "$SOURCE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"mcpServers exceeds entry limit 256"* ]]
    [[ "$output" != *"mcp_servers ="* ]]
}

@test "codex-source rejects unknown fields and ambiguous connections without TOML output" {
    write_source '{"mcpServers":{"alpha":{"command":"printf","args":[],"env":{}}}}'

    run run_codex_parser awk "$SOURCE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown Codex MCP server field 'env'"* ]]
    [[ "$output" != *"mcp_servers ="* ]]

    write_source '{"mcpServers":{"alpha":{"type":"http","url":"https://example.invalid","command":"printf","args":[]}}}'
    run run_codex_parser awk "$SOURCE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"http Codex MCP server must not define command or args"* ]]
    [[ "$output" != *"mcp_servers ="* ]]
}

@test "codex-source rejects unsafe ids, root fields, and escaped-equivalent duplicates" {
    write_source '{"mcpServers":{"bad/id":{"command":"printf","args":[]}}}'
    run run_codex_parser awk "$SOURCE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Codex MCP server id must match"* ]]

    write_source '{"mcpServers":{},"extra":true}'
    run run_codex_parser awk "$SOURCE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown Codex MCP source root field 'extra'"* ]]

    write_source '{"mcpServers":{"alpha":{"command":"printf","args":[]},"\u0061lpha":{"command":"other","args":[]}}}'
    run run_codex_parser awk "$SOURCE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"duplicate JSON key 'alpha'"* ]]
    [[ "$output" != *"mcp_servers ="* ]]
}
