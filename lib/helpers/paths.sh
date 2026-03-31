#!/usr/bin/env bash
# Path resolution utilities for AgentSync sync engine.
# Depends on globals: REPO_ROOT, REPO_ROOT_CANONICAL, DEFAULT_REPO_ROOT (set in sync.sh)

# Normalize a path lexically into an absolute path.
# Works even if the target does not exist yet.
normalize_absolute_path() {
    local path="$1"
    if [[ "$path" != /* ]]; then
        path="$REPO_ROOT/$path"
    fi

    local -a segments normalized_segments
    IFS='/' read -r -a segments <<< "$path"
    normalized_segments=()

    local segment
    for segment in "${segments[@]}"; do
        case "$segment" in
            ""|".")
                continue
                ;;
            "..")
                if [[ ${#normalized_segments[@]} -gt 0 ]]; then
                    unset 'normalized_segments[${#normalized_segments[@]}-1]'
                fi
                ;;
            *)
                normalized_segments+=("$segment")
                ;;
        esac
    done

    local normalized="/"
    if [[ ${#normalized_segments[@]} -gt 0 ]]; then
        normalized="/${normalized_segments[0]}"
        local index
        for ((index = 1; index < ${#normalized_segments[@]}; index++)); do
            normalized="$normalized/${normalized_segments[$index]}"
        done
    fi

    echo "$normalized"
}

is_path_within_repo_root() {
    local candidate_path="$1"
    [[ "$candidate_path" == "$REPO_ROOT_CANONICAL" || "$candidate_path" == "$REPO_ROOT_CANONICAL/"* ]]
}

resolve_existing_ancestor() {
    local path="$1"
    local current="$path"
    while [[ ! -e "$current" ]]; do
        local parent
        parent=$(dirname "$current")
        if [[ "$parent" == "$current" ]]; then
            break
        fi
        current="$parent"
    done

    echo "$current"
}

canonicalize_with_existing_ancestor() {
    local path="$1"
    local existing_ancestor
    existing_ancestor=$(resolve_existing_ancestor "$path")

    local existing_ancestor_canonical
    if [[ -d "$existing_ancestor" ]]; then
        existing_ancestor_canonical=$(cd -P "$existing_ancestor" 2>/dev/null && pwd) || return 1
    else
        local ancestor_parent
        ancestor_parent=$(dirname "$existing_ancestor")
        local ancestor_parent_canonical
        ancestor_parent_canonical=$(cd -P "$ancestor_parent" 2>/dev/null && pwd) || return 1
        existing_ancestor_canonical="$ancestor_parent_canonical/$(basename "$existing_ancestor")"
    fi

    if [[ "$path" == "$existing_ancestor" ]]; then
        echo "$existing_ancestor_canonical"
        return 0
    fi

    local suffix="${path#"$existing_ancestor"}"
    if [[ -n "$suffix" ]] && [[ "$suffix" != /* ]]; then
        suffix="/$suffix"
    fi

    normalize_absolute_path "$existing_ancestor_canonical$suffix"
}

resolve_dest_path() {
    local raw_path="$1"
    local label="$2"

    if [[ -z "$raw_path" ]]; then
        log_error "$label is empty"
        return 1
    fi

    local abs_path
    abs_path=$(normalize_absolute_path "$raw_path")
    local canonical_path
    canonical_path=$(canonicalize_with_existing_ancestor "$abs_path") || {
        log_error "Failed to canonicalize $label path: $raw_path"
        return 1
    }

    if ! is_path_within_repo_root "$canonical_path"; then
        log_error "$label resolves outside repository root: $raw_path -> $canonical_path"
        return 1
    fi

    echo "$abs_path"
}

is_path_safe_source() {
    local candidate_path="$1"
    if [[ "$candidate_path" == "$REPO_ROOT_CANONICAL" || "$candidate_path" == "$REPO_ROOT_CANONICAL/"* ]]; then
        return 0
    fi
    if [[ "$candidate_path" == "$DEFAULT_REPO_ROOT" || "$candidate_path" == "$DEFAULT_REPO_ROOT/"* ]]; then
        return 0
    fi
    return 1
}

resolve_source_path() {
    local raw_path="$1"
    local label="$2"

    if [[ -z "$raw_path" ]]; then
        log_error "$label is empty"
        return 1
    fi

    # First try resolving relative to REPO_ROOT (the user project)
    local abs_path_target
    abs_path_target=$(normalize_absolute_path "$raw_path")
    local canonical_path_target
    canonical_path_target=$(canonicalize_with_existing_ancestor "$abs_path_target") 2>/dev/null || true

    if [[ -n "$canonical_path_target" ]] && [[ -e "$canonical_path_target" ]] && is_path_safe_source "$canonical_path_target"; then
        echo "$abs_path_target"
        return 0
    fi

    # Fallback to DEFAULT_REPO_ROOT (the shipped package templates)
    local abs_path_fallback
    if [[ "$raw_path" == /* ]]; then
        abs_path_fallback="$raw_path"
    else
        abs_path_fallback="$DEFAULT_REPO_ROOT/$raw_path"
    fi

    local canonical_path_fallback
    canonical_path_fallback=$(canonicalize_with_existing_ancestor "$abs_path_fallback") 2>/dev/null || true

    if [[ -n "$canonical_path_fallback" ]] && is_path_safe_source "$canonical_path_fallback"; then
        echo "$abs_path_fallback"
        return 0
    fi

    # If neither exists/valid, log error based on the primary target
    if [[ -n "$canonical_path_target" ]]; then
        if ! is_path_safe_source "$canonical_path_target"; then
            log_error "$label resolves outside safe source roots: $raw_path -> $canonical_path_target"
            return 1
        fi
    fi

    echo "$abs_path_target"
    return 0
}

to_repo_relative_path() {
    local abs_path="$1"
    if [[ "$abs_path" == "$REPO_ROOT" ]]; then
        echo "."
        return 0
    fi

    if [[ "$abs_path" == "$REPO_ROOT/"* ]]; then
        echo "${abs_path#$REPO_ROOT/}"
        return 0
    fi

    log_error "Path is outside repository root: $abs_path"
    return 1
}
