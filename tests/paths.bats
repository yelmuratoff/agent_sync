#!/usr/bin/env bats
# Tests for paths.sh — the lexical path primitives and the containment checks
# that keep sync from writing outside the project root.
#
# _path_parent_r / _path_leaf_r replace `dirname` / `basename` on the hot path,
# so their agreement with those utilities is asserted directly rather than
# assumed. normalize_absolute_path_r takes a fast path for already-canonical
# input, so both branches are compared against the same expectations.

load test_helper

setup() {
    setup_test_project
    source "$REPO_ROOT/lib/helpers/cli_colors.sh"
    source "$REPO_ROOT/lib/helpers/logging.sh"
    source "$REPO_ROOT/lib/helpers/paths.sh"

    # A real project root is a clean absolute path, and these tests compare
    # against one built by string concatenation. macOS sets $TMPDIR with a
    # trailing slash, so mktemp hands back a path containing "//" that the
    # resolvers correctly collapse — which would fail the comparison, not the code.
    REPO_ROOT="$(cd -P "$TEST_PROJECT" && pwd)"
    REPO_ROOT_CANONICAL="$REPO_ROOT"
    DEFAULT_REPO_ROOT="$REPO_ROOT_CANONICAL/engine"
    mkdir -p "$DEFAULT_REPO_ROOT"
}

teardown() {
    teardown_test_project
}

# ── _path_parent_r / _path_leaf_r vs dirname / basename ─────────────────────

@test "paths: _path_parent_r agrees with dirname" {
    local cases=(
        "/" "/a" "/a/" "/a//" "/a/b" "/a/b/" "/a//b//"
        "a" "a/b" "./a" "../a" "." ".." "/." "/.."
        "/usr//lib//" "/a/b/c/d.md" "/x y/z.md" "/a/.ai/src/rules/core.md"
        "file.md" ".hidden" "/a/b.c/d.e"
    )
    local input
    for input in "${cases[@]}"; do
        _path_parent_r "$input"
        [ "$REPLY" = "$(dirname "$input")" ]
    done
}

@test "paths: _path_parent_r returns . for an empty path, like dirname" {
    _path_parent_r ""
    [ "$REPLY" = "." ]
}

@test "paths: _path_leaf_r agrees with basename" {
    local cases=(
        "/" "/a" "/a/" "/a/b" "/a/b/" "/a//b//"
        "a" "a/b" "/usr//lib//" "/a/b/c/d.md" "/x y/z.md"
        "file.md" ".hidden" "/a/b.c/d.e"
    )
    local input
    for input in "${cases[@]}"; do
        _path_leaf_r "$input"
        [ "$REPLY" = "$(basename "$input")" ]
    done
}

@test "paths: _path_parent_r reaches a fixpoint at / so ancestor walks terminate" {
    _path_parent_r "/"
    [ "$REPLY" = "/" ]
}

# A pathname starting with exactly two slashes is implementation-defined in
# POSIX, and the platforms disagree: `dirname //` is `/` on BSD and `//` under
# MSYS, where it is the UNC prefix. No implementation can match both, so the
# primitives above are not asserted against it. What keeps that safe is that
# normalisation collapses the form first, so they never receive one.
@test "paths: normalization collapses a leading double slash before it reaches the primitives" {
    local case
    for case in "//" "///" "//a" "//a//b"; do
        normalize_absolute_path_r "$case"
        [[ "$REPLY" != //* ]]
    done

    normalize_absolute_path_r "//"
    [ "$REPLY" = "/" ]
    normalize_absolute_path_r "//a//b"
    [ "$REPLY" = "/a/b" ]
}

# ── normalize_absolute_path_r ───────────────────────────────────────────────

@test "paths: normalize leaves an already-canonical absolute path untouched" {
    normalize_absolute_path_r "/a/b/c.md"
    [ "$REPLY" = "/a/b/c.md" ]
}

@test "paths: normalize makes a relative path absolute against REPO_ROOT" {
    normalize_absolute_path_r ".ai/src/rules"
    [ "$REPLY" = "$REPO_ROOT/.ai/src/rules" ]
}

@test "paths: normalize collapses dot, dot-dot, and duplicate separators" {
    normalize_absolute_path_r "/a/./b//c/../d"
    [ "$REPLY" = "/a/b/d" ]

    normalize_absolute_path_r "/a//b//"
    [ "$REPLY" = "/a/b" ]

    normalize_absolute_path_r "/a/b/.."
    [ "$REPLY" = "/a" ]
}

@test "paths: normalize cannot climb above the filesystem root" {
    normalize_absolute_path_r "/../../.."
    [ "$REPLY" = "/" ]
}

@test "paths: normalize echo wrapper matches the REPLY variant" {
    local input="/a/./b/../c"
    normalize_absolute_path_r "$input"
    [ "$(normalize_absolute_path "$input")" = "$REPLY" ]
}

# ── directory canonicalization and its memo ────────────────────────────────

@test "paths: _canon_dir_r resolves a symlinked directory to its target" {
    mkdir -p "$TEST_PROJECT/real"
    create_test_symlink "$TEST_PROJECT/real" "$TEST_PROJECT/link"

    _canon_dir_r "$TEST_PROJECT/link"
    [ "$REPLY" = "$(cd -P "$TEST_PROJECT/real" && pwd)" ]
}

@test "paths: _canon_dir_r returns the same answer when memoized" {
    mkdir -p "$TEST_PROJECT/dir"
    _canon_dir_r "$TEST_PROJECT/dir"
    local first="$REPLY"
    _canon_dir_r "$TEST_PROJECT/dir"
    [ "$REPLY" = "$first" ]
}

@test "paths: _canon_dir_r fails on a missing directory and caches nothing" {
    run _canon_dir_r "$TEST_PROJECT/absent"
    [ "$status" -ne 0 ]

    mkdir -p "$TEST_PROJECT/absent"
    _canon_dir_r "$TEST_PROJECT/absent"
    [ "$REPLY" = "$(cd -P "$TEST_PROJECT/absent" && pwd)" ]
}

@test "paths: canonicalize resolves a path whose leaf does not exist yet" {
    canonicalize_with_existing_ancestor_r "$TEST_PROJECT/not/created/yet.md"
    [ "$REPLY" = "$REPO_ROOT_CANONICAL/not/created/yet.md" ]
}

@test "paths: canonicalize resolves through a symlinked ancestor" {
    mkdir -p "$TEST_PROJECT/real"
    create_test_symlink "$TEST_PROJECT/real" "$TEST_PROJECT/link"

    canonicalize_with_existing_ancestor_r "$TEST_PROJECT/link/deep/file.md"
    [ "$REPLY" = "$(cd -P "$TEST_PROJECT/real" && pwd)/deep/file.md" ]
}

# ── containment: the security invariant ────────────────────────────────────

@test "paths: resolve_dest_path accepts a destination inside the repo root" {
    resolve_dest_path_r ".claude/rules" "test dest"
    [ "$REPLY" = "$REPO_ROOT/.claude/rules" ]
}

@test "paths: resolve_dest_path rejects a traversal escape" {
    run resolve_dest_path_r "../escape" "test dest"
    [ "$status" -ne 0 ]
    [[ "$output" == *"outside repository root"* ]]
}

@test "paths: resolve_dest_path rejects an absolute path outside the repo root" {
    run resolve_dest_path_r "/etc/passwd" "test dest"
    [ "$status" -ne 0 ]
    [[ "$output" == *"outside repository root"* ]]
}

@test "paths: resolve_dest_path rejects an empty path" {
    run resolve_dest_path_r "" "test dest"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is empty"* ]]
}

@test "paths: resolve_dest_path rejects a symlink pointing outside the repo root" {
    local outside
    outside="$(mktemp -d "${TMPDIR:-/tmp}/agentsync_outside.XXXXXX")"
    create_test_symlink "$outside" "$TEST_PROJECT/escape-link"

    run resolve_dest_path_r "escape-link/rules" "test dest"
    _rm_rf_resilient "$outside"

    [ "$status" -ne 0 ]
    [[ "$output" == *"outside repository root"* ]]
}

@test "paths: resolve_dest_path echo wrapper matches the REPLY variant" {
    resolve_dest_path_r ".claude/rules" "test dest"
    [ "$(resolve_dest_path ".claude/rules" "test dest")" = "$REPLY" ]
}

@test "paths: is_path_safe_source allows the repo root and the engine root" {
    is_path_safe_source "$REPO_ROOT_CANONICAL/.ai/src/rules"
    is_path_safe_source "$DEFAULT_REPO_ROOT/lib/templates"
}

@test "paths: is_path_safe_source rejects an unrelated root" {
    run is_path_safe_source "/etc"
    [ "$status" -ne 0 ]
}

# ── repo-relative rendering ────────────────────────────────────────────────

@test "paths: to_repo_relative_path strips the repo root prefix" {
    to_repo_relative_path_r "$REPO_ROOT/.claude/rules/core.md"
    [ "$REPLY" = ".claude/rules/core.md" ]
}

@test "paths: to_repo_relative_path renders the repo root itself as dot" {
    to_repo_relative_path_r "$REPO_ROOT"
    [ "$REPLY" = "." ]
}

@test "paths: to_repo_relative_path fails for a path outside the repo root" {
    run to_repo_relative_path_r "/somewhere/else/file.md"
    [ "$status" -ne 0 ]
    [[ "$output" == *"outside repository root"* ]]
}

@test "paths: resolve_source_path keeps a missing project source in the project" {
    mkdir -p "$DEFAULT_REPO_ROOT/.ai/src/rules"
    resolve_source_path_r ".ai/src/rules" "source.rules"
    [ "$REPLY" = "$REPO_ROOT/.ai/src/rules" ]
}
