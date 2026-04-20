#!/usr/bin/env bats
# Tests for agentsync release.

load test_helper

setup_file() {
    # Build a seeded copy of the repo once. Each test clones via APFS
    # clonefile, which is near-instant and isolates concurrent tests.
    TEST_SEED="$(mktemp -d "${TMPDIR:-/tmp}/agentsync_release_seed.XXXXXX")"
    export TEST_SEED

    # clonefile the whole repo when on APFS; fall back to cp -R.
    if ! cp -c -R "$REPO_ROOT"/. "$TEST_SEED/" 2>/dev/null; then
        cp -R "$REPO_ROOT"/. "$TEST_SEED/"
    fi

    (
        cd "$TEST_SEED"
        rm -rf .git
        git init --quiet
        git config user.email "test@test.com"
        git config user.name "Test"
        git add -A
        git commit -m "initial" --quiet

        echo "1.0.0" > VERSION
        git add VERSION
        git commit -m "set version" --quiet
    )
}

teardown_file() { teardown_seed_project; }

setup() {
    clone_seed
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
