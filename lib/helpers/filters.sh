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

    if [[ -n "$exclude" ]]; then
        local pat
        for pat in $exclude; do
            # shellcheck disable=SC2053
            if [[ $filename == $pat ]]; then
                return 1
            fi
        done
    fi

    if [[ -z "$include" ]]; then
        return 0
    fi

    local pat
    for pat in $include; do
        # shellcheck disable=SC2053
        if [[ $filename == $pat ]]; then
            return 0
        fi
    done

    return 1
}
