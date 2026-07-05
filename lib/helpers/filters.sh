#!/usr/bin/env bash
# Filter utilities for AgentSync sync engine.

# Check if a filename matches include/exclude glob patterns.
# Both include and exclude accept one or more space-separated globs; the
# filename matches the set if ANY pattern matches it.
# Usage: matches_filter "filename" "include_glob[s]" "exclude_glob[s]"
# Returns: 0 if file should be processed, 1 if it should be skipped
matches_filter() {
    local filename="$1"
    local include="$2"
    local exclude="$3"

    # Split the space-separated globs into arrays with pathname expansion OFF —
    # otherwise a pattern like `*.md` expands against the cwd during the split
    # (the run's cwd is the project root), silently dropping the real pattern.
    # The `[[ == $pat ]]` match below is glob-pattern matching, unaffected by -f.
    local -a inc_pats=() exc_pats=()
    local reglob=1; case $- in *f*) reglob=0 ;; esac
    set -f
    # shellcheck disable=SC2206
    [[ -n "$exclude" ]] && exc_pats=($exclude)
    # shellcheck disable=SC2206
    [[ -n "$include" ]] && inc_pats=($include)
    (( reglob )) && set +f

    local pat
    for pat in ${exc_pats[@]+"${exc_pats[@]}"}; do
        # shellcheck disable=SC2053
        if [[ $filename == $pat ]]; then
            return 1
        fi
    done

    if [[ -z "$include" ]]; then
        return 0
    fi

    for pat in ${inc_pats[@]+"${inc_pats[@]}"}; do
        # shellcheck disable=SC2053
        if [[ $filename == $pat ]]; then
            return 0
        fi
    done

    return 1
}
