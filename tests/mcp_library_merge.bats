#!/usr/bin/env bats
# Merge-specific MCP library behavior. Remote CI owns execution of this suite.

load test_helper

setup() {
    setup_test_project
    run_agentsync init --no-detect >/dev/null
    enable_tools claude kimi
    CATALOG="$TEST_PROJECT/catalog/mcp"
    mkdir -p "$CATALOG" .ai/src/tools/claude
    cp -R "$REPO_ROOT/tests/fixtures/mcp_library/stdio" "$CATALOG/stdio"
    cp -R "$REPO_ROOT/tests/fixtures/mcp_library/http" "$CATALOG/http"
}

teardown() { teardown_test_project; }

@test "merge rejects an appended raw NUL without changing its source" {
    printf '%s\0' '{"mcpServers":{"mine":{"command":"keep","args":[]}}}' > .ai/src/tools/claude/mcp.json
    local before
    before=$(file_sha256 .ai/src/tools/claude/mcp.json)

    run run_agentsync mcp use http --tool claude --merge --apply --library "$CATALOG"

    [ "$status" -ne 0 ]
    [[ "$output" == *"raw NUL"* ]]
    [ "$before" = "$(file_sha256 .ai/src/tools/claude/mcp.json)" ]
}

@test "merge preserves distinct NUL and SOH keys and string values" {
    printf '%s\n' '{"mcpServers":{},"mcpSer\u0000vers":{"x\u0000y":"nul\u0000data","x\u0001y":"soh\u0001data"},"mcpSer\u0001vers":"other"}' > .ai/src/tools/claude/mcp.json
    cp .ai/src/tools/claude/mcp.json expected-before.json
    run run_agentsync mcp use http --tool claude --merge --apply --library "$CATALOG"
    [ "$status" -eq 0 ]
    python3 -c 'import json,pathlib; expected=json.loads(pathlib.Path("expected-before.json").read_text()); expected["mcpServers"]["http"]={"type":"http","url":"https://example.invalid/mcp"}; actual=json.loads(pathlib.Path(".ai/src/tools/claude/mcp.json").read_text()); assert actual == expected, (actual, expected)'
}

backup_state() {
    # init may already have a backup; compare content rather than assuming none.
    [ -d .ai/backups ] || return 0
    find .ai/backups -type f -exec cksum {} \; | LC_ALL=C sort
}

@test "merge preview reports selected actions without exposing foreign source data" {
    printf '%s\n' '{"mcpServers":{"mine":{"command":"keep","args":[],"env":{"TOKEN":"private-value"}},"remote":{"url":"https://example.invalid/old","headers":{"Authorization":"Bearer private-header"}}},"foreign":{"retain":[true,{"nested":"value"}]}}' > .ai/src/tools/claude/mcp.json
    local before
    before=$(file_sha256 .ai/src/tools/claude/mcp.json)

    run run_agentsync mcp use http --tool claude --merge --library "$CATALOG"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Preview: add http"* ]]
    [[ "$output" != *"private-value"* ]]
    [[ "$output" != *"private-header"* ]]
    [ "$before" = "$(file_sha256 .ai/src/tools/claude/mcp.json)" ]
}

@test "merge apply preserves unrelated root and server data" {
    printf '%s\n' '{"mcpServers":{"mine":{"command":"keep","args":[],"env":{"TOKEN":"private-value"}},"remote":{"url":"https://example.invalid/old","headers":{"Authorization":"Bearer private-header"}}},"foreign":{"retain":[true,{"nested":"value"}]}}' > .ai/src/tools/claude/mcp.json

    run run_agentsync mcp use http --tool claude --merge --apply --library "$CATALOG"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Merged MCP source"* ]]
    python3 -c 'import json, pathlib; d=json.loads(pathlib.Path(".ai/src/tools/claude/mcp.json").read_text()); assert d["foreign"] == {"retain": [True, {"nested": "value"}]}; assert d["mcpServers"]["mine"]["env"] == {"TOKEN": "private-value"}; assert d["mcpServers"]["remote"]["headers"] == {"Authorization": "Bearer private-header"}; assert d["mcpServers"]["http"] == {"type": "http", "url": "https://example.invalid/mcp"}'
    [ -d .ai/backups ]
}

@test "merge requires explicit replacement for a selected differing server" {
    printf '%s\n' '{"mcpServers":{"http":{"url":"https://example.invalid/old"},"mine":{"command":"keep","args":[]}}}' > .ai/src/tools/claude/mcp.json
    local before
    before=$(file_sha256 .ai/src/tools/claude/mcp.json)

    run run_agentsync mcp use http --tool claude --merge --library "$CATALOG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--replace http"* ]]
    [ "$before" = "$(file_sha256 .ai/src/tools/claude/mcp.json)" ]

    run run_agentsync mcp use http --tool claude --merge --replace http --apply --library "$CATALOG"
    [ "$status" -eq 0 ]
    python3 -c 'import json, pathlib; d=json.loads(pathlib.Path(".ai/src/tools/claude/mcp.json").read_text()); assert d["mcpServers"]["http"]["url"] == "https://example.invalid/mcp"; assert d["mcpServers"]["mine"]["command"] == "keep"'
}

@test "merge accepts an exact canonical effective declaration" {
    printf '%s\n' 'targets:' '  mcp:' '    source: .ai/src/tools/claude/mcp.json' > .ai/src/tools/claude.yaml
    printf '%s\n' '{"mcpServers":{}}' > .ai/src/tools/claude/mcp.json

    run run_agentsync mcp use http --tool claude --merge --apply --library "$CATALOG"

    [ "$status" -eq 0 ]
    python3 -c 'import json, pathlib; d=json.loads(pathlib.Path(".ai/src/tools/claude/mcp.json").read_text()); assert d["mcpServers"]["http"] == {"type": "http", "url": "https://example.invalid/mcp"}'
}

@test "identical merge leaves the source and backup store untouched" {
    printf '%s\n' '{"mcpServers":{"http":{"type":"http","url":"https://example.invalid/mcp"}}}' > .ai/src/tools/claude/mcp.json
    local before
    before=$(file_sha256 .ai/src/tools/claude/mcp.json)
    local backups_before
    backups_before=$(backup_state)

    run run_agentsync mcp use http --tool claude --merge --apply --library "$CATALOG"

    [ "$status" -eq 0 ]
    [[ "$output" == *"already matches"* ]]
    [ "$before" = "$(file_sha256 .ai/src/tools/claude/mcp.json)" ]
    [ "$backups_before" = "$(backup_state)" ]
}

@test "merge refuses a canonical source symlink" {
    run_agentsync mcp render http --library "$CATALOG" > existing.json
    mkdir -p .ai/src/tools/claude
    create_test_symlink "$TEST_PROJECT/existing.json" .ai/src/tools/claude/mcp.json
    local backups_before
    backups_before=$(backup_state)

    run run_agentsync mcp use http --tool claude --merge --library "$CATALOG"

    [ "$status" -ne 0 ]
    [[ "$output" == *"through a symlink"* ]]
    [ -L .ai/src/tools/claude/mcp.json ]
    [ "$backups_before" = "$(backup_state)" ]
}

@test "staged merge size includes its final newline before backup" {
    run env MCP_LIBRARY_MAX_SOURCE_BYTES=5 bash -c '
        source "$1/lib/helpers/cli_colors.sh"
        source "$1/lib/helpers/mcp_library.sh"
        source "$1/lib/helpers/mcp_library_bind.sh"
        printf "12345\\n" > "$2"
        _mcp_library_staged_source_within_limit "$2"
    ' bash "$REPO_ROOT" "$TEST_PROJECT/staged.json"

    [ "$status" -ne 0 ]
    [[ "$output" == *"exceeds 5 byte limit"* ]]
}

@test "merge apply fails closed when its per-target lock already exists" {
    printf '%s\n' '{"mcpServers":{}}' > .ai/src/tools/claude/mcp.json
    mkdir .ai/src/tools/claude/mcp.json.mcp-library.lock
    local before
    before=$(file_sha256 .ai/src/tools/claude/mcp.json)
    local backups_before
    backups_before=$(backup_state)

    run run_agentsync mcp use http --tool claude --merge --apply --library "$CATALOG"

    [ "$status" -ne 0 ]
    [[ "$output" == *"locked by another merge"* ]]
    [ "$before" = "$(file_sha256 .ai/src/tools/claude/mcp.json)" ]
    [ -d .ai/src/tools/claude/mcp.json.mcp-library.lock ]
    [ "$backups_before" = "$(backup_state)" ]
}

@test "merge refuses publication when the source changes during backup" {
    printf '%s\n' '{"mcpServers":{"mine":{"command":"keep","args":[]}}}' > .ai/src/tools/claude/mcp.json
    cp .ai/src/tools/claude/mcp.json expected-before.json
    printf '%s\n' '{"mcpServers":{"mine":{"command":"raced","args":[]}}}' > raced.json

    run bash -c '
        set -euo pipefail
        repo="$1" project="$2" catalog="$3"
        cd "$project"
        source "$repo/lib/helpers/cli_colors.sh"
        source "$repo/lib/helpers/paths.sh"
        source "$repo/lib/helpers/yaml.sh"
        source "$repo/lib/helpers/project_config.sh"
        source "$repo/lib/helpers/tool_resolver.sh"
        source "$repo/lib/helpers/backup.sh"
        source "$repo/lib/helpers/mcp_library.sh"
        source "$repo/lib/helpers/mcp_library_bind.sh"
        _need() { :; }
        REPO_ROOT="$project"
        REPO_ROOT_CANONICAL="$project"
        DEFAULT_REPO_ROOT="$repo"
        _AGENTSYNC_ENGINE_ROOT="$repo"
        PROJECT_CONFIG_PATH="$project/.ai/agent_sync.yaml"
        eval "$(declare -f backup_create | sed "1s/^backup_create/real_backup_create/")"
        backup_create() {
            real_backup_create "$@" || return 1
            cp "$REPO_ROOT/raced.json" "$REPO_ROOT/.ai/src/tools/claude/mcp.json"
        }
        cmd_mcp_library_bind use http --tool claude --merge --apply --library "$catalog"
    ' bash "$REPO_ROOT" "$TEST_PROJECT" "$CATALOG"

    [ "$status" -ne 0 ]
    [[ "$output" == *"changed after preview"* ]]
    python3 -c 'import json, pathlib; assert json.loads(pathlib.Path(".ai/src/tools/claude/mcp.json").read_text())["mcpServers"]["mine"]["command"] == "raced"'
    local backup
    backup=$(find .ai/backups -type f -path '*/files/.ai/src/tools/claude/mcp.json' -print -quit)
    [ -n "$backup" ]
    cmp expected-before.json "$backup"
}

@test "merge signal cleanup removes its registered files and lock" {
    printf '%s\n' '{"mcpServers":{"mine":{"command":"keep","args":[]}}}' > .ai/src/tools/claude/mcp.json
    mkdir signal-tmp
    mkdir signal-bin
    local system_rmdir
    system_rmdir=$(command -v rmdir)
    [ -n "$system_rmdir" ]
    cat > signal-bin/rmdir <<'SH'
#!/bin/sh
printf 'rmdir target=%s executable=%s\n' "$1" "$MCP_LIBRARY_SYSTEM_RMDIR" >> "$MCP_LIBRARY_CLEANUP_TRACE"
[ "$1" != "--" ] || exit 64
"$MCP_LIBRARY_SYSTEM_RMDIR" "$@"
rc=$?
printf 'rmdir status=%s\n' "$rc" >> "$MCP_LIBRARY_CLEANUP_TRACE"
exit "$rc"
SH
    chmod 700 signal-bin/rmdir

    run env PATH="$TEST_PROJECT/signal-bin:$PATH" MCP_LIBRARY_CLEANUP_TRACE="$TEST_PROJECT/cleanup-trace" MCP_LIBRARY_SYSTEM_RMDIR="$system_rmdir" TMPDIR="$TEST_PROJECT/signal-tmp" bash -c '
        set -euo pipefail
        repo="$1" project="$2" catalog="$3"
        cd "$project"
        source "$repo/lib/helpers/cli_colors.sh"
        source "$repo/lib/helpers/paths.sh"
        source "$repo/lib/helpers/yaml.sh"
        source "$repo/lib/helpers/project_config.sh"
        source "$repo/lib/helpers/tool_resolver.sh"
        source "$repo/lib/helpers/backup.sh"
        source "$repo/lib/helpers/mcp_library.sh"
        source "$repo/lib/helpers/mcp_library_bind.sh"
        _need() { :; }
        REPO_ROOT="$project"
        REPO_ROOT_CANONICAL="$project"
        DEFAULT_REPO_ROOT="$repo"
        _AGENTSYNC_ENGINE_ROOT="$repo"
        PROJECT_CONFIG_PATH="$project/.ai/agent_sync.yaml"
        _mcp_library_staged_source_within_limit() {
            printf "registered lock=%s\n" "$cleanup_lock" >&2
            trap -p EXIT TERM >&2
            sh -c "kill -TERM \"\$PPID\""
        }
        cmd_mcp_library_bind use http --tool claude --merge --apply --library "$catalog"
    ' bash "$REPO_ROOT" "$TEST_PROJECT" "$CATALOG"

    printf '%s\n' "$output" >&3
    if [ -f cleanup-trace ]; then cat cleanup-trace >&3; fi
    [ "$status" -eq 143 ]
    [ ! -e .ai/src/tools/claude/mcp.json.mcp-library.lock ]
    [ -z "$(find signal-tmp -mindepth 1 -maxdepth 1 -print -quit)" ]
    [ -z "$(find .ai/src/tools/claude -name '.mcp-library.*' -print -quit)" ]
}

@test "merge rejects invalid replacement requests and alternate source declarations" {
    printf '%s\n' '{"mcpServers":{}}' > .ai/src/tools/claude/mcp.json

    run run_agentsync mcp use http --tool claude --replace http --library "$CATALOG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--replace requires --merge"* ]]

    run run_agentsync mcp use http --tool claude --merge --replace stdio --library "$CATALOG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Replacement id is not selected"* ]]

    printf '%s\n' '{}' > .ai/src/mcp.json
    run run_agentsync mcp use http --tool claude --merge --library "$CATALOG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"would be shadowed"* ]]
}

@test "merge rejects malformed and escaped-equivalent duplicate existing JSON" {
    printf '%s\n' '{"mcpServers":{"mine":{"command":"keep","args":[]},"\u006dine":{"command":"other","args":[]}}}' > .ai/src/tools/claude/mcp.json
    local before
    before=$(file_sha256 .ai/src/tools/claude/mcp.json)

    run run_agentsync mcp use http --tool claude --merge --library "$CATALOG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"duplicate JSON key 'mine'"* ]]
    [ "$before" = "$(file_sha256 .ai/src/tools/claude/mcp.json)" ]

    printf '%s\n' '{"mcpServers":{"mine":' > .ai/src/tools/claude/mcp.json
    run run_agentsync mcp use http --tool claude --merge --library "$CATALOG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unterminated"* || "$output" == *"invalid JSON"* ]]
}

@test "Kimi applies and syncs the canonical HTTP MCP source unchanged" {
    run run_agentsync mcp use http --tool kimi --library "$CATALOG" --apply

    [ "$status" -eq 0 ]
    [ -f .ai/src/tools/kimi/mcp.json ]
    [ ! -e .kimi-code/mcp.json ]

    run run_agentsync sync --only kimi

    [ "$status" -eq 0 ]
    cmp .ai/src/tools/kimi/mcp.json .kimi-code/mcp.json
    python3 -c 'import json, pathlib; d=json.loads(pathlib.Path(".kimi-code/mcp.json").read_text()); assert d == {"mcpServers": {"http": {"type": "http", "url": "https://example.invalid/mcp"}}}'
}
