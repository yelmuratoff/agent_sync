#!/usr/bin/env bats

load test_helper

setup_file() { seed_project --no-detect; }
teardown_file() { teardown_seed_project; }
setup() {
    clone_seed
    enable_tools opencode
}
teardown() { teardown_test_project; }

write_shared_mcp() {
    printf '%s\n' "$1" > .ai/src/mcp.json
}

assert_json() {
    python3 -c "import json,sys; data=json.load(open(sys.argv[1])); assert $2" "$1"
}

@test "opencode: shared local MCP is composed into settings" {
    mkdir -p .ai/src/tools/opencode
    printf '%s\n' '{"$schema":"https://opencode.ai/config.json","theme":"system"}' > .ai/src/tools/opencode/settings.json
    write_shared_mcp '{"mcpServers":{"github":{"command":"npx","args":["-y","@github/mcp"],"env":{"TOKEN":"${GITHUB_TOKEN}"}}}}'

    run run_agentsync sync

    [ "$status" -eq 0 ]
    assert_json opencode.json "data['theme'] == 'system'"
    assert_json opencode.json "data['mcp']['github'] == {'type':'local','command':['npx','-y','@github/mcp'],'environment':{'TOKEN':'\${GITHUB_TOKEN}'}}"
}

@test "opencode: per-tool MCP overrides the shared source" {
    write_shared_mcp '{"mcpServers":{"shared":{"command":"shared"}}}'
    mkdir -p .ai/src/tools/opencode
    printf '%s\n' '{"mcpServers":{"private":{"command":"private"}}}' > .ai/src/tools/opencode/mcp.json

    run run_agentsync sync

    [ "$status" -eq 0 ]
    assert_json opencode.json "set(data['mcp']) == {'private'}"
}

@test "opencode: settings-owned MCP is preserved without a canonical source" {
    mkdir -p .ai/src/tools/opencode
    printf '%s\n' '{"mcp":{"native":{"type":"local","command":["native"]}}}' > .ai/src/tools/opencode/settings.json

    run run_agentsync sync

    [ "$status" -eq 0 ]
    cmp -s .ai/src/tools/opencode/settings.json opencode.json
}

@test "opencode: remote MCP preserves supported options" {
    write_shared_mcp '{"mcpServers":{"docs":{"type":"sse","url":"https://example.test/mcp","headers":{"Authorization":"Bearer {env:TOKEN}"},"enabled":false,"timeout":9000,"oauth":false}}}'

    run run_agentsync sync

    [ "$status" -eq 0 ]
    assert_json opencode.json "data['mcp']['docs'] == {'type':'remote','url':'https://example.test/mcp','headers':{'Authorization':'Bearer {env:TOKEN}'},'enabled':False,'timeout':9000,'oauth':False}"
}

@test "opencode: rejects non-object mcpServers" {
    write_shared_mcp '{"mcpServers":[]}'

    run run_agentsync sync

    [ "$status" -ne 0 ]
    [[ "$output" == *"mcpServers must be an object"* ]]
}

@test "opencode: rejects a non-object server" {
    write_shared_mcp '{"mcpServers":{"x":[]}}'

    run run_agentsync sync

    [ "$status" -ne 0 ]
    [[ "$output" == *"server 'x' must be an object"* ]]
}

@test "opencode: validates server field types" {
    write_shared_mcp '{"mcpServers":{"x":{"command":7}}}'

    run run_agentsync sync

    [ "$status" -ne 0 ]
    [[ "$output" == *"server 'x' field 'command' must be a string"* ]]
}

@test "opencode: rejects ambiguous transport" {
    write_shared_mcp '{"mcpServers":{"x":{"command":"a","url":"https://x"}}}'

    run run_agentsync sync

    [ "$status" -ne 0 ]
    [[ "$output" == *"server 'x' must define exactly one transport"* ]]
}

@test "opencode: rejects unsupported fields" {
    write_shared_mcp '{"mcpServers":{"x":{"command":"a","bogus":true}}}'

    run run_agentsync sync

    [ "$status" -ne 0 ]
    [[ "$output" == *"server 'x' has unsupported field 'bogus'"* ]]
}

@test "opencode: validates collection and option types" {
    local input expected
    while IFS=$'\t' read -r input expected; do
        write_shared_mcp "$input"
        run run_agentsync sync
        [ "$status" -ne 0 ]
        [[ "$output" == *"$expected"* ]]
    done <<'CASES'
{"mcpServers":{"x":{"command":"x","args":[1]}}}	field 'args' must contain only strings
{"mcpServers":{"x":{"command":"x","env":{"A":1}}}}	field 'env' values must be strings
{"mcpServers":{"x":{"url":"https://x","headers":{"A":1}}}}	field 'headers' values must be strings
{"mcpServers":{"x":{"command":"x","enabled":"yes"}}}	field 'enabled' must be a boolean
{"mcpServers":{"x":{"command":"x","timeout":-1}}}	field 'timeout' must be a non-negative number
{"mcpServers":{"x":{"url":"https://x","oauth":"yes"}}}	field 'oauth' must be a boolean or object
CASES
}

@test "opencode: enforces transport-specific fields and types" {
    local input expected
    while IFS=$'\t' read -r input expected; do
        write_shared_mcp "$input"
        run run_agentsync sync
        [ "$status" -ne 0 ]
        [[ "$output" == *"$expected"* ]]
    done <<'CASES'
{"mcpServers":{"x":{"command":"x","type":"sse"}}}	must be stdio for a local server
{"mcpServers":{"x":{"url":"https://x","type":"stdio"}}}	is not a supported remote transport
{"mcpServers":{"x":{"command":"x","headers":{}}}}	contains remote-only fields
{"mcpServers":{"x":{"url":"https://x","args":[]}}}	contains local-only fields
{"mcpServers":{"x":{"enabled":true}}}	must define exactly one transport
CASES
}

@test "opencode: preserves valid JSON escapes" {
    write_shared_mcp '{"mcp\u0053ervers":{"escaped\u002dname":{"comm\u0061nd":"tool\\bin","args":["line\nvalue"],"env":{"QUOTE":"a\"b"}}}}'

    run run_agentsync sync

    [ "$status" -eq 0 ]
    assert_json opencode.json "data['mcp']['escaped-name']['command'] == ['tool\\\\bin','line\\nvalue']"
    assert_json opencode.json "data['mcp']['escaped-name']['environment']['QUOTE'] == 'a\"b'"
}

@test "opencode: rejects unsupported canonical top-level fields" {
    write_shared_mcp '{"mcpServers":{},"version":1}'

    run run_agentsync sync

    [ "$status" -ne 0 ]
    [[ "$output" == *"unsupported top-level field 'version'"* ]]
}

@test "opencode: rejects duplicate keys" {
    write_shared_mcp '{"mcpServers":{"x":{"command":"a","command":"b"}}}'

    run run_agentsync sync

    [ "$status" -ne 0 ]
    [[ "$output" == *"duplicate server field 'command'"* ]]
}

@test "opencode: rejects settings and canonical MCP ownership conflict" {
    mkdir -p .ai/src/tools/opencode
    printf '%s\n' '{"mcp":{"native":{"type":"local","command":["native"]}}}' > .ai/src/tools/opencode/settings.json
    write_shared_mcp '{"mcpServers":{"x":{"command":"x"}}}'

    run run_agentsync sync

    [ "$status" -ne 0 ]
    [[ "$output" == *"both define OpenCode MCP ownership"* ]]
    [[ "$output" == *".ai/src/tools/opencode/settings.json"* ]]
    [[ "$output" == *".ai/src/mcp.json"* ]]
}

@test "opencode: malformed MCP leaves destination and manifest unchanged" {
    run_agentsync sync >/dev/null
    printf '%s\n' 'ORIGINAL' > opencode.json
    local manifest_before
    manifest_before=$(shasum -a 256 .ai/.sync-manifest | awk '{print $1}')
    write_shared_mcp '{"mcpServers":'

    run run_agentsync sync --force

    [ "$status" -ne 0 ]
    [ "$(cat opencode.json)" = "ORIGINAL" ]
    [ "$(shasum -a 256 .ai/.sync-manifest | awk '{print $1}')" = "$manifest_before" ]
}

@test "opencode: dry-run validates malformed MCP" {
    write_shared_mcp '{"mcpServers":'

    run run_agentsync sync --dry-run

    [ "$status" -ne 0 ]
    [ ! -e opencode.json ]
}

@test "opencode: dry-run composes without writing" {
    write_shared_mcp '{"mcpServers":{"x":{"command":"x"}}}'

    run run_agentsync sync --dry-run

    [ "$status" -eq 0 ]
    [ ! -e opencode.json ]
}

@test "opencode: repeated composition is byte-identical" {
    write_shared_mcp '{"mcpServers":{"x":{"command":"x","enabled":true,"timeout":12}}}'
    run_agentsync sync >/dev/null
    local config_before manifest_before
    config_before=$(shasum -a 256 opencode.json | awk '{print $1}')
    manifest_before=$(shasum -a 256 .ai/.sync-manifest | awk '{print $1}')

    run_agentsync sync >/dev/null

    [ "$(shasum -a 256 opencode.json | awk '{print $1}')" = "$config_before" ]
    [ "$(shasum -a 256 .ai/.sync-manifest | awk '{print $1}')" = "$manifest_before" ]
}
