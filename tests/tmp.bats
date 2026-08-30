#!/usr/bin/env bats
# Tests for the per-run temp lifecycle.

load test_helper

setup() {
    setup_test_project
    TMP_SANDBOX="$TEST_PROJECT/tmpdir_sandbox"
    mkdir -p "$TMP_SANDBOX"
    export TMPDIR="$TMP_SANDBOX"
    AGENTSYNC_RUN_TMPDIR=""
    AGENTSYNC_RUN_TMPDIR_OWNER=""
    source "$REPO_ROOT/lib/helpers/tmp.sh"
}

teardown() {
    tmp_cleanup || true
    teardown_test_project
}

@test "tmp: prime creates a run dir and cleanup removes it" {
    tmp_prime_run_dir
    [ -d "$AGENTSYNC_RUN_TMPDIR" ]
    [ "$AGENTSYNC_RUN_TMPDIR_OWNER" = "$$" ]

    local run_dir="$AGENTSYNC_RUN_TMPDIR"
    tmp_cleanup
    [ ! -e "$run_dir" ]
}

@test "tmp: tmp_file and tmp_dir land inside the run dir" {
    tmp_prime_run_dir
    local f d
    f=$(tmp_file scratch)
    d=$(tmp_dir workspace)

    [ -f "$f" ]
    [ -d "$d" ]
    [[ "$f" == "$AGENTSYNC_RUN_TMPDIR/"* ]]
    [[ "$d" == "$AGENTSYNC_RUN_TMPDIR/"* ]]

    tmp_cleanup
    [ ! -e "$f" ]
    [ ! -e "$d" ]
}

@test "tmp: a file created inside command substitution is still reclaimed" {
    # The property an array registry cannot provide: most helpers run inside
    # $(...), where an append to a parent array is discarded on subshell exit.
    tmp_prime_run_dir
    local f
    f=$(tmp_file nested)
    [ -f "$f" ]

    tmp_cleanup
    [ ! -e "$f" ]
    [ -z "$(ls -A "$TMP_SANDBOX" 2>/dev/null)" ]
}

@test "tmp: tmp_run_dir fails loudly when unprimed" {
    run tmp_run_dir
    [ "$status" -ne 0 ]
    [[ "$output" == *"not primed"* ]]
}

@test "tmp: tmp_sibling stages beside the destination and is reclaimed" {
    tmp_prime_run_dir
    printf 'original\n' > "$TEST_PROJECT/config.yaml"

    local staged
    staged=$(tmp_sibling "$TEST_PROJECT/config.yaml")
    [ -f "$staged" ]
    [[ "$staged" == "$TEST_PROJECT/config.yaml."* ]]

    tmp_cleanup
    [ ! -e "$staged" ]
    [ -f "$TEST_PROJECT/config.yaml" ]
}

@test "tmp: cleanup is idempotent" {
    tmp_prime_run_dir
    tmp_cleanup
    run tmp_cleanup
    [ "$status" -eq 0 ]
}

@test "tmp: a non-owner never removes the run dir" {
    tmp_prime_run_dir
    local run_dir="$AGENTSYNC_RUN_TMPDIR"

    AGENTSYNC_RUN_TMPDIR_OWNER=1 tmp_cleanup
    [ -d "$run_dir" ]

    AGENTSYNC_RUN_TMPDIR_OWNER="$$" tmp_cleanup
    [ ! -e "$run_dir" ]
}

@test "tmp: an inherited run dir is adopted rather than duplicated" {
    tmp_prime_run_dir
    local parent_dir="$AGENTSYNC_RUN_TMPDIR"

    tmp_prime_run_dir
    [ "$AGENTSYNC_RUN_TMPDIR" = "$parent_dir" ]
    [ "$(find "$TMP_SANDBOX" -maxdepth 1 -type d -name 'agentsync.*' | wc -l)" -eq 1 ]
}

@test "tmp: a symlinked inherited run dir is rejected" {
    local decoy="$TEST_PROJECT/decoy"
    mkdir -p "$decoy"
    create_test_symlink "$decoy" "$TMP_SANDBOX/agentsync.evil"

    AGENTSYNC_RUN_TMPDIR="$TMP_SANDBOX/agentsync.evil"
    AGENTSYNC_RUN_TMPDIR_OWNER=1
    tmp_prime_run_dir

    [ "$AGENTSYNC_RUN_TMPDIR" != "$TMP_SANDBOX/agentsync.evil" ]
    [ "$AGENTSYNC_RUN_TMPDIR_OWNER" = "$$" ]
    [ -d "$decoy" ]
}

@test "tmp: SIGTERM runs cleanup and re-raises as 143" {
    # Self-signal rather than backgrounding: no sleep, no race, and it still
    # asserts both halves of the contract — cleanup ran, status is 128+N.
    local sandbox="$TEST_PROJECT/signal_sandbox"
    mkdir -p "$sandbox"

    TMPDIR="$sandbox" run bash -c "
        source '$REPO_ROOT/lib/helpers/tmp.sh'
        tmp_prime_run_dir
        trap 'tmp_cleanup; trap - TERM; kill -TERM \$\$' TERM
        tmp_file scratch >/dev/null
        kill -TERM \$\$
    "

    # Cleanup is the contract; the exact 128+N status needs a real WIFSIGNALED,
    # which the MSYS emulation layer does not provide.
    [ -z "$(ls -A "$sandbox" 2>/dev/null)" ]
    [ "$status" -ne 0 ]
    [[ "$(uname -s)" != MINGW* && "$(uname -s)" != MSYS* ]] || skip "Windows has no WIFSIGNALED"
    [ "$status" -eq 143 ]
}

@test "tmp: SIGINT runs cleanup and re-raises as 130" {
    # `bats --jobs` runs tests under GNU parallel, which hands children SIGINT
    # as SIG_IGN; bash cannot trap a signal inherited as ignored, so the handler
    # never installs. Detect that and skip rather than assert a runner artifact.
    local sandbox="$TEST_PROJECT/signal_sandbox"
    mkdir -p "$sandbox"

    if [[ -z "$(trap -p INT)" ]]; then
        trap ':' INT
        local trappable="$(trap -p INT)"
        trap - INT
        [[ -n "$trappable" ]] || skip "SIGINT is inherited as ignored under this runner"
    fi

    TMPDIR="$sandbox" run bash -c "
        source '$REPO_ROOT/lib/helpers/tmp.sh'
        tmp_prime_run_dir
        trap 'tmp_cleanup; trap - INT; kill -INT \$\$' INT
        tmp_file scratch >/dev/null
        kill -INT \$\$
    "

    [ -z "$(ls -A "$sandbox" 2>/dev/null)" ]
    [ "$status" -ne 0 ]
    [[ "$(uname -s)" != MINGW* && "$(uname -s)" != MSYS* ]] || skip "Windows has no WIFSIGNALED"
    [ "$status" -eq 130 ]
}

@test "tmp: tmp_sibling carries the destination's mode across the rename" {
    [[ "$(uname -s)" != MINGW* && "$(uname -s)" != MSYS* ]] || skip "Windows ignores chmod bits"
    tmp_prime_run_dir
    printf 'original\n' > "$TEST_PROJECT/config.yaml"
    chmod 644 "$TEST_PROJECT/config.yaml"

    local staged
    staged=$(tmp_sibling "$TEST_PROJECT/config.yaml")
    printf 'rewritten\n' > "$staged"
    mv "$staged" "$TEST_PROJECT/config.yaml"

    run stat -f '%Lp' "$TEST_PROJECT/config.yaml"
    if [ "$status" -ne 0 ]; then
        run stat -c '%a' "$TEST_PROJECT/config.yaml"
    fi
    [ "$output" = "644" ]
}

@test "tmp: tmp_sibling for a new destination does not create it" {
    tmp_prime_run_dir
    local staged
    staged=$(tmp_sibling "$TEST_PROJECT/brand-new.yaml")

    [ -f "$staged" ]
    [ ! -e "$TEST_PROJECT/brand-new.yaml" ]
}

@test "tmp: tmp_sibling stays writable when the destination is read-only" {
    [[ "$(uname -s)" != MINGW* && "$(uname -s)" != MSYS* ]] || skip "Windows ignores chmod bits"
    tmp_prime_run_dir
    printf 'original\n' > "$TEST_PROJECT/locked.yaml"
    chmod 444 "$TEST_PROJECT/locked.yaml"

    local staged
    staged=$(tmp_sibling "$TEST_PROJECT/locked.yaml" 2>/dev/null)
    [ -f "$staged" ]

    # Carrying a 0444 mode across would hand back staging nobody can write.
    printf 'rewritten\n' > "$staged"
    [ "$(cat "$staged")" = "rewritten" ]
}

@test "tmp: cleanup refuses a run dir this helper did not create" {
    tmp_prime_run_dir
    local real="$TEST_PROJECT/precious"
    mkdir -p "$real"
    printf 'keep me\n' > "$real/data.txt"

    # Only the owner check stood between a hand-set value and rm -rf on it.
    AGENTSYNC_RUN_TMPDIR="$real"
    tmp_cleanup

    [ -d "$real" ]
    [ -f "$real/data.txt" ]
}
