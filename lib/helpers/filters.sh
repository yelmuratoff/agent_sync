#!/usr/bin/env bash
# Filter utilities for AgentSync sync engine.

# Check if a filename matches include/exclude glob patterns.
# Usage: matches_filter "filename" "include_glob" "exclude_glob"
# Returns: 0 if file should be processed, 1 if it should be skipped
matches_filter() {
    local filename="$1"
    local include="$2"
    local exclude="$3"

    # Check exclude first — takes precedence
    if [[ -n "$exclude" ]]; then
        # shellcheck disable=SC2053
        if [[ $filename == $exclude ]]; then
            return 1
        fi
    fi

    # If no include pattern, match everything not excluded
    if [[ -z "$include" ]]; then
        return 0
    fi

    # shellcheck disable=SC2053
    if [[ $filename == $include ]]; then
        return 0
    fi

    return 1
}
