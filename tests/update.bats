#!/usr/bin/env bats
# Tests for the self-healing install-dir reconcile on `agentsync update`
# (lib/helpers/update.sh::_update_reconcile_install). Uses a local bare remote —
# no network — to exercise fast-forward, auto-stash of drift, and hard-reset.

load test_helper

setup() {
    # shellcheck disable=SC1090,SC1091
    source "$REPO_ROOT/lib/helpers/update.sh"

    UPSTREAM="$(mktemp -d "${TMPDIR:-/tmp}/agentsync_upstream.XXXXXX")"
    INSTALL="$(mktemp -d "${TMPDIR:-/tmp}/agentsync_install.XXXXXX")"

    git init --quiet --bare "$UPSTREAM"
    git clone --quiet "$UPSTREAM" "$INSTALL" 2>/dev/null
    (
        cd "$INSTALL"
        git config user.email "test@test.com"
        git config user.name "Test"
        git symbolic-ref HEAD refs/heads/main
        echo "v1" > file.txt
        git add file.txt
        git commit --quiet -m "initial"
        git push --quiet -u origin main
    )
    git -C "$UPSTREAM" symbolic-ref HEAD refs/heads/main
}

teardown() {
    [[ -n "${UPSTREAM:-}" ]] && [[ -d "$UPSTREAM" ]] && rm -rf "$UPSTREAM"
    [[ -n "${INSTALL:-}" ]] && [[ -d "$INSTALL" ]] && rm -rf "$INSTALL"
}

# Push one commit to origin/main from a throwaway clone, then fetch it into the
# install dir so origin/main is one commit ahead of the install's HEAD.
_advance_upstream() {
    local content="$1"
    local work
    work="$(mktemp -d "${TMPDIR:-/tmp}/agentsync_work.XXXXXX")"
    git clone --quiet "$UPSTREAM" "$work" 2>/dev/null
    (
        cd "$work"
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "$content" > file.txt
        git add file.txt
        git commit --quiet -m "upstream change"
        git push --quiet origin main
    )
    rm -rf "$work"
    git -C "$INSTALL" fetch --quiet origin main
}

_install_head() { git -C "$INSTALL" rev-parse HEAD; }
_install_origin() { git -C "$INSTALL" rev-parse origin/main; }

@test "update: reconcile fast-forwards a clean install dir" {
    _advance_upstream "v2"
    run _update_reconcile_install "$INSTALL"
    [ "$status" -eq 0 ]
    [ "$(_install_head)" = "$(_install_origin)" ]
    [ "$(cat "$INSTALL/file.txt")" = "v2" ]
    [[ "$output" != *stashed* ]]
}

@test "update: reconcile sets aside a local edit that would block the merge" {
    echo "my local hack" > "$INSTALL/file.txt"
    _advance_upstream "v2"
    run _update_reconcile_install "$INSTALL"
    [ "$status" -eq 0 ]
    [ "$(_install_head)" = "$(_install_origin)" ]
    [ "$(cat "$INSTALL/file.txt")" = "v2" ]
    [[ "$output" == *stashed* ]]
    git -C "$INSTALL" stash list | grep -q "agentsync-update-autostash"
}

@test "update: reconcile preserves untracked files (e.g. .update_cache)" {
    echo "cache" > "$INSTALL/.update_cache"
    _advance_upstream "v2"
    run _update_reconcile_install "$INSTALL"
    [ "$status" -eq 0 ]
    [ -f "$INSTALL/.update_cache" ]
    [ "$(cat "$INSTALL/.update_cache")" = "cache" ]
}

@test "update: reconcile hard-resets a diverged install dir onto the release" {
    (
        cd "$INSTALL"
        echo "local divergent" > other.txt
        git add other.txt
        git commit --quiet -m "local-only commit"
    )
    _advance_upstream "v2"
    run _update_reconcile_install "$INSTALL"
    [ "$status" -eq 0 ]
    [ "$(_install_head)" = "$(_install_origin)" ]
    [ "$(cat "$INSTALL/file.txt")" = "v2" ]
    [ ! -f "$INSTALL/other.txt" ]
}
