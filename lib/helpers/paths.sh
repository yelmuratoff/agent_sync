#!/usr/bin/env bash
# Path resolution utilities for AgentSync sync engine.
# Depends on globals: REPO_ROOT, REPO_ROOT_CANONICAL, DEFAULT_REPO_ROOT (set in sync.sh)
#
# Each resolver has two shapes: a `_r` variant returning through $REPLY, and an
# echo wrapper for the `$(...)` call sites. Hot loops use `_r`.

# Canonical source.* roots the project config names outside the project. Only
# widens is_path_safe_source; destinations never consult it.
EXPLICIT_SOURCE_ROOTS=()
# Canonical AGENTSYNC_INTERNAL_SOURCE_BASE_ROOT while check's isolated sync runs.
SOURCE_BASE_ROOT_CANONICAL=""

# Set REPLY to the absolute, lexically normalised path of a source.* value.
# Relative values resolve from the project root, which check's isolated sync
# receives as AGENTSYNC_INTERNAL_SOURCE_BASE_ROOT.
source_abs_path_r() {
    local raw_path="$1"
    [[ "$raw_path" == /* ]] || raw_path="${AGENTSYNC_INTERNAL_SOURCE_BASE_ROOT:-$REPO_ROOT}/$raw_path"
    normalize_absolute_path_r "$raw_path"
}

# Return 0 when canonical <path> is, or is below, a directory listed in the
# colon-separated AGENTSYNC_EXTERNAL_SOURCE_ROOTS. Only the environment can
# trust an outside root, so a cloned project cannot grant itself read access.
_external_source_trusted() {
    local path="$1"
    local remaining="${AGENTSYNC_EXTERNAL_SOURCE_ROOTS:-}" entry
    while [[ -n "$remaining" ]]; do
        entry="${remaining%%:*}"
        if [[ "$remaining" == *:* ]]; then
            remaining="${remaining#*:}"
        else
            remaining=""
        fi
        [[ "$entry" == /* ]] || continue
        _canon_dir_r "$entry" || continue
        if [[ "$path" == "$REPLY" || "$path" == "$REPLY/"* ]]; then
            return 0
        fi
    done
    return 1
}

# Classify an explicit source.* value. Returns 0 when it is written under the
# project, where a symlink resolving outside stays refused; 1 for an acceptable
# outside root; 2 when that root is /, $HOME, or the project root or one of its
# ancestors; 3 when it is outside the project but not in
# AGENTSYNC_EXTERNAL_SOURCE_ROOTS. REPLY is the canonical path for 1, 2, and 3.
explicit_source_root_r() {
    local raw_path="$1"
    local project_root="${SOURCE_BASE_ROOT_CANONICAL:-$REPO_ROOT_CANONICAL}"

    source_abs_path_r "$raw_path"
    local abs_path="$REPLY"
    local project_path="${AGENTSYNC_INTERNAL_SOURCE_BASE_ROOT:-$REPO_ROOT}"
    [[ "$abs_path" == "$project_path/"* ]] && return 0
    canonicalize_with_existing_ancestor_r "$abs_path" 2>/dev/null || return 0
    local canonical_path="$REPLY"
    [[ "$canonical_path" == "$project_root/"* ]] && return 0

    local home_canonical=""
    if [[ -n "${HOME:-}" ]] && _canon_dir_r "$HOME"; then
        home_canonical="$REPLY"
    fi
    REPLY="$canonical_path"
    if [[ "$canonical_path" == "/" || "$canonical_path" == "$home_canonical" || \
          "$canonical_path" == "$project_root" || "$project_root" == "$canonical_path/"* ]]; then
        return 2
    fi
    _external_source_trusted "$canonical_path" || { REPLY="$canonical_path"; return 3; }
    REPLY="$canonical_path"
    return 1
}

# Allowlist every source.* value <config> sets explicitly outside the project
# under a trusted root. Defaults and auto-detected layouts are never registered.
# Returns 1 after log_error when a value names a refused or untrusted root.
register_explicit_source_roots() {
    local config="$1"
    EXPLICIT_SOURCE_ROOTS=()
    SOURCE_BASE_ROOT_CANONICAL=""
    if [[ -n "${AGENTSYNC_INTERNAL_SOURCE_BASE_ROOT:-}" ]]; then
        if ! _canon_dir_r "$AGENTSYNC_INTERNAL_SOURCE_BASE_ROOT"; then
            log_error "Source base root not found: $AGENTSYNC_INTERNAL_SOURCE_BASE_ROOT"
            return 1
        fi
        SOURCE_BASE_ROOT_CANONICAL="$REPLY"
    fi
    [[ -n "$config" && -f "$config" ]] || return 0

    local key raw_path status
    for key in agents rules skills tools commands subagents; do
        parse_yaml_value_r "$config" "source.$key"
        raw_path="$REPLY"
        [[ -n "$raw_path" ]] || continue
        status=0
        explicit_source_root_r "$raw_path" || status=$?
        case "$status" in
            1) EXPLICIT_SOURCE_ROOTS+=("$REPLY") ;;
            2)
                log_error "source.$key must not be the filesystem root, the home directory, or the project root or its ancestor: $raw_path -> $REPLY"
                return 1
                ;;
            3)
                log_error "source.$key points outside the project at $REPLY, which AGENTSYNC_EXTERNAL_SOURCE_ROOTS does not list; add that directory (or a parent) to the variable to read from it"
                return 1
                ;;
        esac
    done
}

# Parent directory of a path. Matches `dirname` for every path this module
# handles; a pathname starting with exactly two slashes is implementation-defined
# in POSIX and normalisation collapses it before it can reach here.
_path_parent_r() {
    local path="$1"
    if [[ -z "$path" ]]; then
        REPLY="."
        return 0
    fi
    while [[ "$path" == */ ]] && [[ "$path" != "/" ]]; do
        path="${path%/}"
    done
    if [[ "$path" == "/" ]]; then
        REPLY="/"
        return 0
    fi
    if [[ "$path" != */* ]]; then
        REPLY="."
        return 0
    fi
    path="${path%/*}"
    while [[ "$path" == */ ]] && [[ "$path" != "/" ]]; do
        path="${path%/}"
    done
    [[ -z "$path" ]] && path="/"
    REPLY="$path"
}

# Final component of a path. Matches `basename` with no suffix argument, under
# the same two-slash caveat as _path_parent_r.
_path_leaf_r() {
    local path="$1"
    while [[ "$path" == */ ]] && [[ "$path" != "/" ]]; do
        path="${path%/}"
    done
    if [[ "$path" == "/" ]]; then
        REPLY="/"
        return 0
    fi
    REPLY="${path##*/}"
}

# Memo for `cd -P <dir> && pwd`. A key is a directory that existed when first
# probed, so a directory sync creates later arrives under its own key and cannot
# hit a stale entry. Failures are not cached.
_PATH_CANON_KEYS=()
_PATH_CANON_VALUES=()

_canon_dir_r() {
    local dir="$1"
    local count=${#_PATH_CANON_KEYS[@]}
    local index
    for ((index = 0; index < count; index++)); do
        if [[ "${_PATH_CANON_KEYS[index]}" == "$dir" ]]; then
            REPLY="${_PATH_CANON_VALUES[index]}"
            return 0
        fi
    done

    local canonical
    canonical=$(cd -P "$dir" 2>/dev/null && pwd) || return 1
    [[ -n "$canonical" ]] || return 1
    _PATH_CANON_KEYS+=("$dir")
    _PATH_CANON_VALUES+=("$canonical")
    REPLY="$canonical"
}

# Normalize a path lexically into an absolute path.
# Works even if the target does not exist yet.
normalize_absolute_path_r() {
    local path="$1"
    if [[ "$path" != /* ]]; then
        path="$REPO_ROOT/$path"
    fi

    # Already lexically canonical — no empty, "." or ".." segment to collapse.
    case "$path" in
        */ | *//* | */./* | */../* | */. | */..) ;;
        *)
            REPLY="$path"
            return 0
            ;;
    esac

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

    REPLY="$normalized"
}

normalize_absolute_path() {
    normalize_absolute_path_r "$1"
    echo "$REPLY"
}

is_path_within_repo_root() {
    local candidate_path="$1"
    [[ "$candidate_path" == "$REPO_ROOT_CANONICAL" || "$candidate_path" == "$REPO_ROOT_CANONICAL/"* ]]
}

resolve_existing_ancestor_r() {
    local current="$1"
    local parent
    while [[ ! -e "$current" ]]; do
        _path_parent_r "$current"
        parent="$REPLY"
        if [[ "$parent" == "$current" ]]; then
            break
        fi
        current="$parent"
    done

    REPLY="$current"
}

resolve_existing_ancestor() {
    resolve_existing_ancestor_r "$1"
    echo "$REPLY"
}

canonicalize_with_existing_ancestor_r() {
    local path="$1"
    resolve_existing_ancestor_r "$path"
    local existing_ancestor="$REPLY"

    local existing_ancestor_canonical
    if [[ -d "$existing_ancestor" ]]; then
        _canon_dir_r "$existing_ancestor" || return 1
        existing_ancestor_canonical="$REPLY"
    else
        _path_parent_r "$existing_ancestor"
        _canon_dir_r "$REPLY" || return 1
        local ancestor_parent_canonical="$REPLY"
        _path_leaf_r "$existing_ancestor"
        existing_ancestor_canonical="$ancestor_parent_canonical/$REPLY"
    fi

    if [[ "$path" == "$existing_ancestor" ]]; then
        REPLY="$existing_ancestor_canonical"
        return 0
    fi

    local suffix="${path#"$existing_ancestor"}"
    if [[ -n "$suffix" ]] && [[ "$suffix" != /* ]]; then
        suffix="/$suffix"
    fi

    normalize_absolute_path_r "$existing_ancestor_canonical$suffix"
}

canonicalize_with_existing_ancestor() {
    canonicalize_with_existing_ancestor_r "$1" || return 1
    echo "$REPLY"
}

resolve_dest_path_r() {
    local raw_path="$1"
    local label="$2"

    if [[ -z "$raw_path" ]]; then
        log_error "$label is empty"
        return 1
    fi

    normalize_absolute_path_r "$raw_path"
    local abs_path="$REPLY"

    if ! canonicalize_with_existing_ancestor_r "$abs_path"; then
        log_error "Failed to canonicalize $label path: $raw_path"
        return 1
    fi
    local canonical_path="$REPLY"

    if ! is_path_within_repo_root "$canonical_path"; then
        log_error "$label resolves outside repository root: $raw_path -> $canonical_path"
        return 1
    fi

    REPLY="$abs_path"
}

resolve_dest_path() {
    resolve_dest_path_r "$1" "$2" || return 1
    echo "$REPLY"
}

# Set REPLY to the canonical path a symlink finally points at, following chains
# and resolving relative targets from the link's physical directory. Returns 1
# for a chain longer than 40 links or an unreadable link.
_source_link_target_r() {
    local path="$1" target hops=0
    while [[ -L "$path" ]]; do
        [[ $hops -lt 40 ]] || return 1
        hops=$((hops + 1))
        target=$(readlink "$path") || return 1
        if [[ "$target" != /* ]]; then
            _path_parent_r "$path"
            _canon_dir_r "$REPLY" || return 1
            target="$REPLY/$target"
        fi
        path="$target"
    done
    canonicalize_with_existing_ancestor_r "$path"
}

# Return 1 after log_error when a symlink at or below any <root> resolves
# outside the safe source roots and AGENTSYNC_EXTERNAL_SOURCE_ROOTS does not
# list its target. Copying follows links, so a committed link must never reach
# a file outside what the project or the user's environment trusts. Directory
# links that stay safe are scanned in turn.
refuse_escaping_source_links() {
    local -a pending=("$@")
    local visited="|" index=0 root link target
    while [[ $index -lt ${#pending[@]} ]]; do
        root="${pending[index]}"
        index=$((index + 1))
        [[ -n "$root" ]] || continue
        if [[ $index -gt 256 ]]; then
            log_error "Too many nested symlinks under the source directories to check them safely"
            return 1
        fi

        local -a links=()
        if [[ -L "$root" ]]; then
            links=("$root")
        elif [[ -d "$root" ]]; then
            while IFS= read -r -d '' link; do
                links+=("$link")
            done < <(find "$root" -type l -print0 2>/dev/null)
        fi

        for link in "${links[@]+"${links[@]}"}"; do
            if ! _source_link_target_r "$link"; then
                log_error "Cannot resolve source symlink: ${link#"$REPO_ROOT/"}"
                return 1
            fi
            target="$REPLY"
            if ! is_path_safe_source "$target" && ! _external_source_trusted "$target"; then
                log_error "Source symlink ${link#"$REPO_ROOT/"} resolves outside the project: $target; add that directory (or a parent) to AGENTSYNC_EXTERNAL_SOURCE_ROOTS to read it"
                return 1
            fi
            if [[ -d "$target" && "$visited" != *"|$target|"* ]]; then
                visited+="$target|"
                pending+=("$target")
            fi
        done
    done
}

is_path_safe_source() {
    local candidate_path="$1"
    if [[ "$candidate_path" == "$REPO_ROOT_CANONICAL" || "$candidate_path" == "$REPO_ROOT_CANONICAL/"* ]]; then
        return 0
    fi
    if [[ "$candidate_path" == "$DEFAULT_REPO_ROOT" || "$candidate_path" == "$DEFAULT_REPO_ROOT/"* ]]; then
        return 0
    fi
    if [[ -n "$SOURCE_BASE_ROOT_CANONICAL" ]] && \
       [[ "$candidate_path" == "$SOURCE_BASE_ROOT_CANONICAL" || "$candidate_path" == "$SOURCE_BASE_ROOT_CANONICAL/"* ]]; then
        return 0
    fi
    local explicit_root
    for explicit_root in "${EXPLICIT_SOURCE_ROOTS[@]+"${EXPLICIT_SOURCE_ROOTS[@]}"}"; do
        if [[ "$candidate_path" == "$explicit_root" || "$candidate_path" == "$explicit_root/"* ]]; then
            return 0
        fi
    done
    # `shared:` overlay places child + parent files into a tmpdir; sync reads
    # from there. The tmpdir is owned by shared.sh and torn down on EXIT.
    if [[ -n "${SHARED_OVERLAY_DIR_CANONICAL:-}" ]] && \
       { [[ "$candidate_path" == "$SHARED_OVERLAY_DIR_CANONICAL" ]] || \
         [[ "$candidate_path" == "$SHARED_OVERLAY_DIR_CANONICAL/"* ]]; }; then
        return 0
    fi
    # Per-profile overlay tmpdir — same contract as the shared overlay, but a
    # separate global so a profile pass can compose on top of an active shared:.
    if [[ -n "${PROFILE_OVERLAY_DIR_CANONICAL:-}" ]] && \
       { [[ "$candidate_path" == "$PROFILE_OVERLAY_DIR_CANONICAL" ]] || \
         [[ "$candidate_path" == "$PROFILE_OVERLAY_DIR_CANONICAL/"* ]]; }; then
        return 0
    fi
    # Engine-owned base source overlay tmpdir — same contract again.
    if [[ -n "${BASE_SRC_OVERLAY_DIR_CANONICAL:-}" ]] && \
       { [[ "$candidate_path" == "$BASE_SRC_OVERLAY_DIR_CANONICAL" ]] || \
         [[ "$candidate_path" == "$BASE_SRC_OVERLAY_DIR_CANONICAL/"* ]]; }; then
        return 0
    fi
    return 1
}

resolve_source_path_r() {
    local raw_path="$1"
    local label="$2"

    if [[ -z "$raw_path" ]]; then
        log_error "$label is empty"
        return 1
    fi

    source_abs_path_r "$raw_path"
    local abs_path_target="$REPLY"
    local canonical_path_target=""
    if canonicalize_with_existing_ancestor_r "$abs_path_target" 2>/dev/null; then
        canonical_path_target="$REPLY"
    fi

    if [[ -n "$canonical_path_target" ]] && ! is_path_safe_source "$canonical_path_target"; then
        log_error "$label resolves outside safe source roots: $raw_path -> $canonical_path_target"
        return 1
    fi

    REPLY="$abs_path_target"
    return 0
}

resolve_source_path() {
    resolve_source_path_r "$1" "$2" || return 1
    echo "$REPLY"
}

# Walk up from a starting directory looking for a sibling `.ai/src/` directory,
# stopping at the first hit or the start's git repository boundary (whichever
# first). Does not climb past filesystem root. Skips the start directory
# itself so a project never claims itself as its own parent.
# Echoes the absolute path to the parent `.ai/src/` on success; returns 1 if
# no parent is found within the bounded search.
#
# Usage: find_parent_ai_src <start_dir>
find_parent_ai_src() {
    local start="$1"
    [[ -d "$start" ]] || return 1

    local current
    current=$(cd "$start" && pwd)

    # Determine the start's own git repo root (if any). We are willing to
    # climb to siblings inside the same repo, but not out of it.
    local start_git_root=""
    local probe="$current"
    while [[ -n "$probe" ]] && [[ "$probe" != "/" ]]; do
        if [[ -d "$probe/.git" || -f "$probe/.git" ]]; then
            start_git_root="$probe"
            break
        fi
        probe=$(dirname "$probe")
    done

    local parent
    parent=$(dirname "$current")
    while [[ "$parent" != "$current" ]]; do
        # Refuse to leave the start's git repo: if we have a git root and
        # `parent` is neither it nor inside it, stop the walk.
        if [[ -n "$start_git_root" ]] \
           && [[ "$parent" != "$start_git_root" ]] \
           && [[ "$parent" != "$start_git_root"/* ]]; then
            return 1
        fi
        if [[ -d "$parent/.ai/src" ]]; then
            echo "$parent/.ai/src"
            return 0
        fi
        current="$parent"
        parent=$(dirname "$current")
    done
    return 1
}

# Detect whether a directory lives inside a `.ai/` source tree (or is one).
# AgentSync writes tool outputs as siblings of `.ai/`, so a run rooted inside
# it would nest generated files under the source dir instead of the project.
# Echoes the project root — the parent of the shallowest `.ai/` segment in the
# path — when the directory is inside such a tree; returns 1 when it is not.
#
# Usage: ai_dir_enclosing_root <dir>
ai_dir_enclosing_root() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1
    dir=$(cd "$dir" && pwd)

    local shallowest_ai="" current="$dir"
    while [[ "$current" != "/" && -n "$current" ]]; do
        if [[ "$(basename "$current")" == ".ai" ]]; then
            shallowest_ai="$current"
        fi
        current=$(dirname "$current")
    done

    [[ -n "$shallowest_ai" ]] || return 1
    dirname "$shallowest_ai"
}

# Find every AgentSync-managed `.ai/` directory below a root, in bottom-up
# alphabetical order (deeper paths first; siblings at the same depth sorted
# by LC_ALL=C path order). Used by `sync --workspace` and `dedupe --workspace`
# so cross-project commands behave deterministically between runs and between
# machines.
#
# A `.ai/` directory is included only when it contains either `src/` or
# `agent_sync.yaml` — bare `.ai/` directories from other tooling are skipped.
#
# Vendored trees carry their own `.ai/`, and syncing into `node_modules` writes
# config a package manager will discard. `.ai/` is pruned once matched, so a
# backup snapshot mirroring a project's `.ai/src` cannot be reported as a
# second project either.
#
# Echoes one absolute path per line. Returns 0 even when nothing is found.
#
# Usage: find_workspace_ai_dirs <root>
find_workspace_ai_dirs() {
    local root="$1"
    [[ -d "$root" ]] || return 0
    root=$(cd "$root" && pwd)

    # Two-key sort: depth descending (deeper first), then alphabetical within
    # each depth. Path-component count via awk -F/ keeps it pure coreutils.
    find "$root" \
            \( -name .git -o -name node_modules \) -prune -o \
            -type d -name ".ai" -prune -print 2>/dev/null \
        | while IFS= read -r d; do
            [[ -d "$d/src" || -f "$d/agent_sync.yaml" ]] || continue
            echo "$d"
          done \
        | LC_ALL=C awk -F/ '{ print NF "\t" $0 }' \
        | LC_ALL=C sort -k1,1rn -k2,2 \
        | cut -f2-
}

to_repo_relative_path_r() {
    local abs_path="$1"
    if [[ "$abs_path" == "$REPO_ROOT" ]]; then
        REPLY="."
        return 0
    fi

    if [[ "$abs_path" == "$REPO_ROOT/"* ]]; then
        REPLY="${abs_path#"$REPO_ROOT"/}"
        return 0
    fi

    REPLY=""
    log_error "Path is outside repository root: $abs_path"
    return 1
}

to_repo_relative_path() {
    to_repo_relative_path_r "$1" || return 1
    echo "$REPLY"
}
