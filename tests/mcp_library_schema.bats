#!/usr/bin/env bats
# Parser-only MCP library schema v2 coverage. All inputs are regular files.

load test_helper

setup() {
    setup_test_project
    FIXTURES="$REPO_ROOT/tests/fixtures/mcp_library_v2"
    PARSER="$REPO_ROOT/lib/helpers/mcp_library_parser.awk"
}

teardown() {
    teardown_test_project
}

run_parser() {
    local manifest="$1"
    local mode="${2:-validate}"
    local variant="${3:-}"

    LC_ALL=C awk \
        -v max_depth=16 \
        -v max_bytes=131072 \
        -v expected_id=example \
        -v output_mode="$mode" \
        -v selected_variant="$variant" \
        -f "$PARSER" "$manifest"
}

write_manifest() {
    MANIFEST="$TEST_PROJECT/manifest.json"
    printf '%s' "$1" > "$MANIFEST"
}

@test "NUL cannot alias schema keys IDs or transport types" {
    local base='{"schema_version":1,"id":"example","title":"x","connection":{"type":"stdio","command":"printf","args":[]},"requirements":{"binaries":[],"inputs":[]}}'
    local candidate
    for candidate in \
        "${base/\"example\"/\"ex\\u0000ample\"}" \
        "${base/\"stdio\"/\"st\\u0000dio\"}" \
        "${base/\"connection\"/\"connec\\u0000tion\"}" \
        "${base/\"command\"/\"comm\\u0000and\"}"; do
        write_manifest "$candidate"
        run run_parser "$MANIFEST" validate
        [ "$status" -ne 0 ]
    done
}

@test "metadata preserves the distinction between NUL and SOH" {
    write_manifest '{"schema_version":1,"id":"example","title":"nul\u0000soh\u0001","connection":{"type":"stdio","command":"printf","args":[]},"requirements":{"binaries":[],"inputs":[]}}'
    run run_parser "$MANIFEST" metadata
    [ "$status" -eq 0 ]
    [[ "$output" == *'nul\u0000soh\u0001'* ]]
}

@test "v1 validation and metadata stay selection-neutral" {
    local manifest="$FIXTURES/v1/manifest.json"

    run run_parser "$manifest" validate recommended
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run run_parser "$manifest" metadata recommended
    [ "$status" -eq 0 ]
    [ "$output" = $'example\tV1 example' ]

    run run_parser "$manifest" server
    [ "$status" -eq 0 ]
    [ "$output" = '{"command":"printf","args":["hello","quote: \"","line\nbreak","Grüße","nul\u0000data"]}' ]

    # Reinsert the canonical stdio fragment into a manifest: this proves the
    # server result remains JSON data, including quote, newline, Unicode, and
    # NUL escapes, rather than a shell-oriented representation.
    write_manifest "{\"schema_version\":1,\"id\":\"example\",\"title\":\"roundtrip\",\"connection\":{\"type\":\"stdio\",${output#\{},\"requirements\":{\"binaries\":[],\"inputs\":[]}}"
    run run_parser "$MANIFEST" validate
    [ "$status" -eq 0 ]

    run run_parser "$manifest" selection
    [ "$status" -eq 0 ]
    [ "$output" = $'default\tstdio\tunknown' ]
}

@test "v2 recommended resolves only for server and selection output" {
    local manifest="$FIXTURES/recommended-remote/manifest.json"

    run run_parser "$manifest" metadata recommended
    [ "$status" -eq 0 ]
    [ "$output" = $'example\tSynthetic remote example' ]

    run run_parser "$manifest" server
    [ "$status" -eq 0 ]
    [ "$output" = '{"command":"example-local","args":["--base"]}' ]

    run run_parser "$manifest" server recommended
    [ "$status" -eq 0 ]
    [ "$output" = '{"type":"http","url":"https://example.invalid/uvx"}' ]

    run run_parser "$manifest" selection recommended
    [ "$status" -eq 0 ]
    [ "$output" = $'uvx\thttp\tvendor' ]
}

@test "v2 explicit local alternative has a canonical stdio connection" {
    local manifest="$FIXTURES/local-alternative/manifest.json"

    run run_parser "$manifest" server uvx
    [ "$status" -eq 0 ]
    [ "$output" = '{"command":"uvx","args":["example-mcp"]}' ]

    run run_parser "$manifest" selection uvx
    [ "$status" -eq 0 ]
    [ "$output" = $'uvx\tstdio\tunknown' ]
}

@test "validation rejects invalid alternatives even when default is selected" {
    write_manifest '{"schema_version":2,"id":"example","title":"x","connection":{"type":"stdio","command":"base","args":[]},"requirements":{"binaries":[],"inputs":[]},"alternatives":{"uvx":{"connection":{"type":"stdio","command":"uvx"},"requirements":{"binaries":[],"inputs":[]}}}}'

    run run_parser "$MANIFEST" server default

    [ "$status" -ne 0 ]
    [[ "$output" == *"stdio connection requires field 'args'"* ]]
}

@test "guidance must be complete, refer to an existing alternative, and contain a real date" {
    write_manifest '{"schema_version":2,"id":"example","title":"x","connection":{"type":"stdio","command":"base","args":[]},"requirements":{"binaries":[],"inputs":[]},"guidance":{"recommended":"uvx","authority":"vendor","source":"https://example.invalid","checked_at":"2026-02-29","reason":"x"}}'

    run run_parser "$MANIFEST" validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"guidance.checked_at"* ]]

    write_manifest '{"schema_version":2,"id":"example","title":"x","connection":{"type":"stdio","command":"base","args":[]},"requirements":{"binaries":[],"inputs":[]},"alternatives":{"uvx":{"connection":{"type":"stdio","command":"uvx","args":[]},"requirements":{"binaries":[],"inputs":[]}}},"guidance":{"recommended":"missing","authority":"vendor","source":"https://example.invalid","checked_at":"2026-09-16","reason":"x"}}'
    run run_parser "$MANIFEST" validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"unavailable alternative"* ]]

    write_manifest '{"schema_version":2,"id":"example","title":"x","connection":{"type":"stdio","command":"base","args":[]},"requirements":{"binaries":[],"inputs":[]},"guidance":{"recommended":"default","authority":"vendor","source":"https://","checked_at":"2026-09-16","reason":"x"}}'
    run run_parser "$MANIFEST" validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"guidance.source"* ]]
}

@test "reserved, malformed, and unsupported alternatives are rejected" {
    write_manifest '{"schema_version":2,"id":"example","title":"x","connection":{"type":"stdio","command":"base","args":[]},"requirements":{"binaries":[],"inputs":[]},"alternatives":{"default":{"connection":{"type":"stdio","command":"uvx","args":[]},"requirements":{"binaries":[],"inputs":[]}}}}'

    run run_parser "$MANIFEST" validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"non-reserved variant id"* ]]

    write_manifest '{"schema_version":2,"id":"example","title":"x","connection":{"type":"stdio","command":"base","args":[]},"requirements":{"binaries":[],"inputs":[]},"alternatives":{"uvx":{"connection":{"type":"stdio","command":"uvx","args":[]},"requirements":{"binaries":[],"inputs":["TOKEN"]}}}}'
    run run_parser "$MANIFEST" validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"requirements.inputs is unsupported"* ]]
}

@test "recommended never falls back and requested variants are checked before lookup" {
    local manifest="$FIXTURES/v1/manifest.json"

    run run_parser "$manifest" server recommended
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires guidance"* ]]

    run run_parser "$manifest" server missing
    [ "$status" -ne 0 ]
    [[ "$output" == *"is unavailable"* ]]

    run run_parser "$manifest" server '../uvx'
    [ "$status" -ne 0 ]
    [[ "$output" == *"safe variant id"* ]]
}

@test "guidance source controls cannot reach selection output" {
    write_manifest '{"schema_version":2,"id":"example","title":"x","connection":{"type":"stdio","command":"base","args":[]},"requirements":{"binaries":[],"inputs":[]},"guidance":{"recommended":"default","authority":"vendor","source":"https://example.invalid/\u000aescape","checked_at":"2026-09-16","reason":"x"}}'

    run run_parser "$MANIFEST" selection recommended
    [ "$status" -ne 0 ]
    [[ "$output" == *"guidance.source"* ]]
    [[ "$output" != *$'\n'"escape"* ]]
}
