#!/usr/bin/env bats
# Tests for agentsync release.

load test_helper

setup_file() {
    # Minimal engine seed (no .git): release only needs the CLI entry point,
    # its helpers, a VERSION file, and a CHANGELOG for the tag body. Copying the
    # whole repo and carrying its .git made each per-test clone race under
    # `bats --jobs` — the copied index disagreed with the freshly-written working
    # tree, so release's clean-tree check tripped intermittently.
    TEST_SEED="$(mktemp -d "${TMPDIR:-/tmp}/agentsync_release_seed.XXXXXX")"
    export TEST_SEED

    cp -R "$REPO_ROOT/bin" "$TEST_SEED/bin"
    cp -R "$REPO_ROOT/lib" "$TEST_SEED/lib"
    echo "1.0.0" > "$TEST_SEED/VERSION"
    cp "$REPO_ROOT/CHANGELOG.md" "$TEST_SEED/CHANGELOG.md" 2>/dev/null \
        || echo "# Changelog" > "$TEST_SEED/CHANGELOG.md"
}

teardown_file() { teardown_seed_project; }

setup() {
    # Copy the static seed, then git-init fresh so the working tree is
    # deterministically clean: index stat info matches the just-written files,
    # leaving no room for a stale-index false positive in release's clean check.
    TEST_PROJECT="$(mktemp -d "${TMPDIR:-/tmp}/agentsync_clone.XXXXXX")"
    rmdir "$TEST_PROJECT"
    cp -c -R "$TEST_SEED" "$TEST_PROJECT" 2>/dev/null \
        || { rm -rf "$TEST_PROJECT"; cp -R "$TEST_SEED" "$TEST_PROJECT"; }
    cd "$TEST_PROJECT"
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
    git add -A
    git commit -m "seed" --quiet
    export AGENTSYNC_HOME="$TEST_PROJECT"
}

teardown() { teardown_test_project; }

@test "release patch bumps version" {
    echo "y" | bash bin/agentsync.sh release patch --no-push
    local version
    read -r version < VERSION
    [ "$version" = "1.0.1" ]
}

@test "release minor bumps version" {
    echo "y" | bash bin/agentsync.sh release minor --no-push
    local version
    read -r version < VERSION
    [ "$version" = "1.1.0" ]
}

@test "release major bumps version" {
    echo "y" | bash bin/agentsync.sh release major --no-push
    local version
    read -r version < VERSION
    [ "$version" = "2.0.0" ]
}

@test "release creates git tag" {
    echo "y" | bash bin/agentsync.sh release patch --no-push
    git tag -l | grep -q "1.0.1"
}

@test "release creates commit" {
    echo "y" | bash bin/agentsync.sh release patch --no-push
    git log --oneline -1 | grep -q "release: v1.0.1"
}

@test "release default is patch" {
    echo "y" | bash bin/agentsync.sh release --no-push
    local version
    read -r version < VERSION
    [ "$version" = "1.0.1" ]
}

@test "release fails on dirty working tree" {
    echo "uncommitted" > dirty_file.txt
    run bash -c 'echo "y" | bash bin/agentsync.sh release patch --no-push'
    [ "$status" -eq 1 ]
    [[ "$output" == *"not clean"* ]]
}

@test "release fails with unknown bump type" {
    run bash -c 'echo "y" | bash bin/agentsync.sh release banana'
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown bump type"* ]]
}

@test "release can be cancelled" {
    echo "n" | bash bin/agentsync.sh release patch --no-push
    local version
    read -r version < VERSION
    [ "$version" = "1.0.0" ]
}

@test "release --no-push does not push" {
    run bash -c 'echo "y" | bash bin/agentsync.sh release patch --no-push'
    [ "$status" -eq 0 ]
    [[ "$output" == *"local only"* ]]
    [[ "$output" == *"--no-push"* ]]
}
