#!/usr/bin/env bats
load test_helper

setup() {
    setup_test_project
    run_agentsync init --no-detect >/dev/null
    enable_tools codex
    CATALOG="$TEST_PROJECT/catalog/mcp"
    mkdir -p "$CATALOG" .ai/src/tools/codex
    cp -R "$REPO_ROOT/tests/fixtures/mcp_library/stdio" "$CATALOG/stdio"
    cp -R "$REPO_ROOT/tests/fixtures/mcp_library/http" "$CATALOG/http"
}
teardown() { teardown_test_project; }

@test "Codex library preview and apply do not write native config" {
    run run_agentsync mcp use http stdio --tool codex --library "$CATALOG"
    [ "$status" -eq 0 ]
    [ ! -e .ai/src/tools/codex/mcp.json ]
    [ ! -e .codex/config.toml ]
    run run_agentsync mcp use http stdio --tool codex --library "$CATALOG" --apply
    [ "$status" -eq 0 ]
    [ -f .ai/src/tools/codex/mcp.json ]
    [ ! -e .codex/config.toml ]
}

@test "Codex sync prepends MCP without changing root settings or nested tables" {
    printf '%s\n' '# retained' 'model = "example"' '[features]' 'example = true' > .ai/src/tools/codex/settings.toml
    run run_agentsync mcp use http stdio --tool codex --library "$CATALOG" --apply
    [ "$status" -eq 0 ]
    run run_agentsync sync --only codex
    [ "$status" -eq 0 ]
    tail -n +2 .codex/config.toml > retained.toml
    cmp retained.toml .ai/src/tools/codex/settings.toml
    grep -q '^mcp_servers = ' .codex/config.toml
    grep -q 'command = "printf"' .codex/config.toml
    python3 -c '
import json, pathlib, tomllib
data = tomllib.loads(pathlib.Path(".codex/config.toml").read_text())
source = json.loads(pathlib.Path(".ai/src/tools/codex/mcp.json").read_text())["mcpServers"]
expected = {name: {k:v for k,v in value.items() if k != "type"} for name,value in source.items()}
assert data["mcp_servers"] == expected
assert data["model"] == "example" and data["features"] == {"example": True}
'
    local before
    before=$(file_sha256 .codex/config.toml)
    run run_agentsync sync --only codex
    [ "$status" -eq 0 ]
    [ "$before" = "$(file_sha256 .codex/config.toml)" ]
}

@test "Codex settings only still copy verbatim including existing MCP" {
    printf '%s\n' '[mcp_servers.mine]' 'command = "keep"' > .ai/src/tools/codex/settings.toml
    run run_agentsync sync --only codex
    [ "$status" -eq 0 ]
    cmp .ai/src/tools/codex/settings.toml .codex/config.toml
}

@test "Codex use refuses settings MCP ownership before creating a source" {
    printf '%s\n' '[mcp_servers.mine]' 'command = "keep"' > .ai/src/tools/codex/settings.toml
    run run_agentsync mcp use http --tool codex --library "$CATALOG" --apply
    [ "$status" -ne 0 ]
    [[ "$output" == *'ownership conflict'* ]]
    [ ! -e .ai/src/tools/codex/mcp.json ]
}

@test "Codex sync rejects conflicting settings and preserves destination" {
    run_agentsync mcp use http --tool codex --library "$CATALOG" --apply >/dev/null
    mkdir -p .codex
    printf '%s\n' '# keep destination' > .codex/config.toml
    local before
    before=$(file_sha256 .codex/config.toml)
    printf '%s\n' '[mcp_servers.mine]' 'command = "keep"' > .ai/src/tools/codex/settings.toml
    run run_agentsync sync --only codex
    [ "$status" -ne 0 ]
    [[ "$output" == *'ownership conflict'* ]]
    [ "$before" = "$(file_sha256 .codex/config.toml)" ]
    run run_agentsync doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *'Codex MCP ownership conflict'* ]]
}

@test "Codex ownership guard rejects escaped keys and inline dotted forms" {
    local line
    for line in 'mcp_servers.mine.command = "keep"' '"mcp_servers" = {}' '["m\u0063p_servers".mine]' "['mcp_servers'.mine]"; do
        printf '%s\n' "$line" > .ai/src/tools/codex/settings.toml
        run run_agentsync mcp use http --tool codex --library "$CATALOG" --apply
        [ "$status" -ne 0 ]
        [ ! -e .ai/src/tools/codex/mcp.json ]
    done
}

@test "Codex rejects unsupported MCP fields without replacing config" {
    printf '%s\n' '{"mcpServers":{"mine":{"command":"keep","args":[],"env":{"TOKEN":"fake"}}}}' > .ai/src/tools/codex/mcp.json
    mkdir -p .codex
    printf '%s\n' '# keep destination' > .codex/config.toml
    local before
    before=$(file_sha256 .codex/config.toml)
    run run_agentsync sync --only codex
    [ "$status" -ne 0 ]
    [[ "$output" == *'Cannot convert Codex'* ]]
    [ "$before" = "$(file_sha256 .codex/config.toml)" ]
}

@test "Codex rejects an appended raw NUL MCP source without replacing config" {
    printf '%s\0' '{"mcpServers":{"mine":{"command":"keep","args":[]}}}' > .ai/src/tools/codex/mcp.json
    mkdir -p .codex
    printf '%s\n' '# keep destination' > .codex/config.toml
    local before
    before=$(file_sha256 .codex/config.toml)

    run run_agentsync sync --only codex

    [ "$status" -ne 0 ]
    [[ "$output" == *"raw NUL"* ]]
    [ "$before" = "$(file_sha256 .codex/config.toml)" ]
}

@test "Codex dry run validates but does not replace native config" {
    run_agentsync mcp use http --tool codex --library "$CATALOG" --apply >/dev/null
    mkdir -p .codex
    printf '%s\n' '# keep destination' > .codex/config.toml
    local before
    before=$(file_sha256 .codex/config.toml)
    run run_agentsync sync --only codex --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *'Would compose Codex'* ]]
    [ "$before" = "$(file_sha256 .codex/config.toml)" ]
}

@test "Codex composed output cannot be adopted into settings" {
    run_agentsync mcp use http --tool codex --library "$CATALOG" --apply >/dev/null
    run run_agentsync sync --only codex
    [ "$status" -eq 0 ]
    printf '%s\n' '# edit' >> .codex/config.toml
    run run_agentsync adopt .codex/config.toml
    [ "$status" -ne 0 ]
    [[ "$output" == *'multi-source output'* ]]
}

@test "Codex supports settings that end without newline and full-line MCP comments" {
    printf '%s\n' '# [mcp_servers.example]' > .ai/src/tools/codex/settings.toml
    printf '%s' 'model = "example"' >> .ai/src/tools/codex/settings.toml
    run_agentsync mcp use http --tool codex --library "$CATALOG" --apply >/dev/null
    run run_agentsync sync --only codex
    [ "$status" -eq 0 ]
    tail -n +2 .codex/config.toml > retained.toml
    cmp retained.toml .ai/src/tools/codex/settings.toml
}

@test "Codex disabled MCP target is respected by use doctor sync and adopt" {
    printf '%s\n' 'targets:' '  mcp:' '    enabled: false' > .ai/src/tools/codex.yaml
    run run_agentsync mcp use http --tool codex --library "$CATALOG" --apply
    [ "$status" -ne 0 ]
    [[ "$output" == *'Enable the MCP target'* ]]
    [ ! -e .ai/src/tools/codex/mcp.json ]
    printf '%s\n' '{"mcpServers":{"dormant":{"command":"keep","args":[]}}}' > .ai/src/tools/codex/mcp.json
    printf '%s\n' '[mcp_servers.mine]' 'command = "active"' > .ai/src/tools/codex/settings.toml
    run run_agentsync sync --only codex
    [ "$status" -eq 0 ]
    cmp .ai/src/tools/codex/settings.toml .codex/config.toml
    run run_agentsync doctor
    [[ "$output" != *'Codex MCP ownership conflict'* ]]
    printf '%s\n' '# user edit' >> .codex/config.toml
    run run_agentsync adopt --yes .codex/config.toml
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
    cmp .ai/src/tools/codex/settings.toml .codex/config.toml
    grep -q 'dormant' .ai/src/tools/codex/mcp.json
}
