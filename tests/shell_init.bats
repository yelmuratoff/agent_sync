#!/usr/bin/env bats
# Tests for agentsync shell-init — the printed shell hook snippet.

load test_helper

setup() { setup_test_project; }
teardown() { teardown_test_project; }

@test "shell-init zsh prints a zsh hook" {
    run run_agentsync shell-init zsh
    [ "$status" -eq 0 ]
    [[ "$output" == *"agentsync shell hook (zsh)"* ]]
    [[ "$output" == *"add-zsh-hook chpwd _agentsync_autosync"* ]]
    [[ "$output" == *"agentsync sync --if-stale"* ]]
}

@test "shell-init bash prints a bash hook" {
    run run_agentsync shell-init bash
    [ "$status" -eq 0 ]
    [[ "$output" == *"agentsync shell hook (bash)"* ]]
    [[ "$output" == *"PROMPT_COMMAND"* ]]
    [[ "$output" == *"agentsync sync --if-stale"* ]]
}

@test "shell-init walks up to the nearest .ai/src" {
    run run_agentsync shell-init bash
    [ "$status" -eq 0 ]
    [[ "$output" == *".ai/src"* ]]
}

@test "shell-init snippet honors the AGENTSYNC_NO_AUTO_SYNC kill switch" {
    run run_agentsync shell-init zsh
    [ "$status" -eq 0 ]
    [[ "$output" == *"AGENTSYNC_NO_AUTO_SYNC"* ]]
}

@test "shell-init: hook never cd's (zsh chpwd recursion regression)" {
    run run_agentsync shell-init zsh
    [ "$status" -eq 0 ]
    # A `cd` inside the chpwd hook would re-fire the hook and recurse.
    [[ "$output" != *"cd "* ]]
    [[ "$output" == *"AGENTSYNC_REPO_ROOT="* ]]
}

@test "shell-init: hook guards against re-entrancy" {
    run run_agentsync shell-init bash
    [ "$status" -eq 0 ]
    [[ "$output" == *"_AGENTSYNC_BUSY"* ]]
}

@test "shell-init: zsh hook does not recurse on cd" {
    command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
    mkdir -p proj/.ai/src
    mkdir -p stub
    printf '#!/bin/sh\nexit 0\n' > stub/agentsync
    chmod +x stub/agentsync
    run env PATH="$PWD/stub:$PATH" zsh -c "
        eval \"\$(AGENTSYNC_HOME='$REPO_ROOT' bash '$AGENTSYNC_BIN' shell-init zsh)\"
        cd '$PWD/proj'
        print OK
    "
    [ "$status" -eq 0 ]
    [[ "$output" != *"maximum nested"* ]]
    [[ "$output" == *"OK"* ]]
}

@test "shell-init auto-detects zsh from \$SHELL" {
    run env SHELL=/usr/bin/zsh AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" shell-init
    [ "$status" -eq 0 ]
    [[ "$output" == *"agentsync shell hook (zsh)"* ]]
}

@test "shell-init auto-detects bash from \$SHELL" {
    run env SHELL=/bin/bash AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" shell-init
    [ "$status" -eq 0 ]
    [[ "$output" == *"agentsync shell hook (bash)"* ]]
}

@test "shell-init errors when the shell is unsupported" {
    run run_agentsync shell-init fish
    [ "$status" -eq 2 ]
}

@test "shell-init errors when the shell cannot be detected" {
    run env SHELL= AGENTSYNC_HOME="$REPO_ROOT" bash "$AGENTSYNC_BIN" shell-init
    [ "$status" -eq 2 ]
}

@test "shell-init --help prints usage" {
    run run_agentsync shell-init --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: agentsync shell-init"* ]]
}

@test "shell-init --help recommends the eval form" {
    run run_agentsync shell-init --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'eval "$(agentsync shell-init zsh)"'* ]]
}
