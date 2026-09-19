#!/usr/bin/env bats
load test_helper

setup() { setup_test_project; }
teardown() { teardown_test_project; }

catalog_check() {
    python3 "$REPO_ROOT/tests/check_mcp_catalog.py" --bash "$BASH" "$@"
}

catalog_expect_status() {
    local expected="$1"
    if [ "$status" -ne "$expected" ]; then
        printf 'catalog checker expected status %s, got %s:\n%s\n' "$expected" "$status" "$output" >&2
        return 1
    fi
}

catalog_expect_contains() {
    local expected="$1"
    if [[ "$output" != *"$expected"* ]]; then
        printf 'catalog checker output did not contain %s:\n%s\n' "$expected" "$output" >&2
        return 1
    fi
}

catalog_expect_not_contains() {
    local unexpected="$1"
    if [[ "$output" == *"$unexpected"* ]]; then
        printf 'catalog checker output unexpectedly contained %s:\n%s\n' "$unexpected" "$output" >&2
        return 1
    fi
}

@test "pilot catalog has sourced requirements for every selectable variant" {
    run catalog_check --as-of 2026-09-16 --fail-stale
    catalog_expect_status 0
    catalog_expect_not_contains "ignored null byte"
    catalog_expect_contains '"id": "octocode"'
    catalog_expect_contains '"id": "context7"'
    catalog_expect_contains '"id": "microsoft-learn"'
}

@test "catalog checker passes explicit Bash and Git Bash paths without executing a shim" {
    local test_script="$TEST_PROJECT/check_catalog_invocation.py"
    cat > "$test_script" <<'PY'
import importlib.util
from pathlib import Path, PureWindowsPath
import sys
from unittest.mock import patch

module_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("check_mcp_catalog", module_path)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)
calls = []

def fake_run(args, **kwargs):
    calls.append((args, kwargs))

with patch.object(checker.subprocess, "run", fake_run), patch.object(
        sys, "argv", [str(module_path), "--bash", "C:/Program Files/Git/usr/bin/bash.exe", "--as-of", "2026-09-16"]):
    assert checker.main() == 0

root = module_path.parents[1]
shell_root = checker.posix_shell_path(root)
assert calls == [(
    ["C:/Program Files/Git/usr/bin/bash.exe", shell_root + "/bin/agentsync.sh", "mcp", "validate", "--library", shell_root + "/catalog/mcp"],
    {"check": True, "stdout": sys.stderr, "env": {**checker.os.environ, "AGENTSYNC_HOME": shell_root}},
)]
assert checker.posix_shell_path_from_resolved(PureWindowsPath("D:/a/agent_sync/catalog/mcp"), "nt") == "/d/a/agent_sync/catalog/mcp"
assert checker.posix_shell_path_from_resolved(PureWindowsPath("//server/share/catalog"), "nt") == "//server/share/catalog"
PY
    run python3 "$test_script" "$REPO_ROOT/tests/check_mcp_catalog.py"
    catalog_expect_status 0
}

@test "requirements sweep reports stale metadata without mutating catalog" {
    cp -R "$REPO_ROOT/catalog/mcp" "$TEST_PROJECT/catalog"
    local before
    before=$(file_sha256 "$TEST_PROJECT/catalog/octocode/manifest.json")
    run catalog_check --catalog "$TEST_PROJECT/catalog" --as-of 2026-12-01 --fail-stale
    catalog_expect_status 1
    catalog_expect_contains '"status": "due"'
    [ "$before" = "$(file_sha256 "$TEST_PROJECT/catalog/octocode/manifest.json")" ]
}

@test "requirements metadata rejects credential values" {
    cp -R "$REPO_ROOT/catalog/mcp" "$TEST_PROJECT/catalog"
    python3 -c 'import json,pathlib; p=pathlib.Path("catalog/octocode/manifest.json"); d=json.loads(p.read_text()); d["extensions"]["agentsync.dev"]["variants"]["default"]["auth"]["environment_any_of"]=["TOKEN=fake"]; p.write_text(json.dumps(d))'
    run catalog_check --catalog "$TEST_PROJECT/catalog" --as-of 2026-09-16
    catalog_expect_status 2
    catalog_expect_contains 'names, never values'
}

@test "evidence URLs reject query and fragment data without printing it" {
    cp -R "$REPO_ROOT/catalog/mcp" "$TEST_PROJECT/catalog"
    local suffix
    for suffix in '?token=private-value' '#token=private-value'; do
        python3 -c 'import json,pathlib,sys; p=pathlib.Path("catalog/octocode/manifest.json"); d=json.loads(p.read_text()); d["extensions"]["agentsync.dev"]["sources"]=["https://docs.example/path"+sys.argv[1]]; p.write_text(json.dumps(d))' "$suffix"
        run catalog_check --catalog "$TEST_PROJECT/catalog" --as-of 2026-09-16
        catalog_expect_status 2
        catalog_expect_contains 'without query or fragment'
        catalog_expect_not_contains 'private-value'
    done
}
