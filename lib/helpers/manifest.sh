#!/usr/bin/env bash
# Sync manifest — content-addressed record of every file written by `agentsync sync`.
# Lets sync detect manual edits in destination files (drift) and refuse to
# silently overwrite them. Pure bash 3.2, no associative arrays, no JSON parser.
#
# Format: one line per output file, "<rel_path>\t<sha256>", LC_ALL=C sorted.
# Path: $REPO_ROOT/.ai/.sync-manifest. Committed to git so CI catches drift.
#
# Depends on: logging.sh, paths.sh (to_repo_relative_path).

# Globals owned by this module
MANIFEST_KEYS=()                # parallel arrays: rel paths from previous sync
MANIFEST_VALUES=()              # corresponding sha256 hashes
SYNC_TOUCHED_PATHS=()           # rel paths written during this run
SYNC_TOUCHED_SET="|"            # pipe-delimited dedup set: |path1|path2|
SYNC_DRIFT_DETECTED=()          # rel paths whose dest differs from manifest
SYNC_BASELINE_INITIALIZED="false"

manifest_path() {
    echo "$REPO_ROOT/.ai/.sync-manifest"
}

# Echo the available SHA-256 command, or empty if none is installed.
_manifest_hash_cmd() {
    if command -v sha256sum >/dev/null 2>&1; then
        echo "sha256sum"
    elif command -v shasum >/dev/null 2>&1; then
        echo "shasum -a 256"
    fi
}

# Compute sha256 of a file. Echoes the bare hash, returns 1 if no tool found.
# Usage: manifest_compute_hash "/abs/path"
manifest_compute_hash() {
    local file="$1"
    [[ -f "$file" ]] || return 1

    local tool out
    tool=$(_manifest_hash_cmd)
    [[ -n "$tool" ]] || return 1
    # $tool may be "shasum -a 256" — intentional word split.
    # shellcheck disable=SC2086
    out=$($tool "$file" 2>/dev/null) || return 1
    echo "${out%% *}"
}

# Hash many files in as few processes as possible. Reads NUL-separated paths on
# stdin, prints one "<hash>  <path>" line per file, preserving input order
# (xargs keeps order and splits batches to respect ARG_MAX). Emits nothing when
# no hash tool exists. Callers pre-filter to existing files.
_manifest_hash_stream() {
    local tool
    tool=$(_manifest_hash_cmd)
    [[ -n "$tool" ]] || return 0
    # $tool may be "shasum -a 256" — intentional word split.
    # shellcheck disable=SC2086
    xargs -0 $tool 2>/dev/null
}

# Linear lookup in MANIFEST_KEYS/VALUES. Echoes hash, returns 1 if missing.
# Usage: manifest_lookup "rel/path"
manifest_lookup() {
    local key="$1"
    local i
    for ((i = 0; i < ${#MANIFEST_KEYS[@]}; i++)); do
        if [[ "${MANIFEST_KEYS[$i]}" == "$key" ]]; then
            echo "${MANIFEST_VALUES[$i]}"
            return 0
        fi
    done
    return 1
}

# Load existing manifest from disk into MANIFEST_KEYS/VALUES.
# If no manifest exists, marks the run as a baseline initialization.
manifest_load() {
    MANIFEST_KEYS=()
    MANIFEST_VALUES=()
    SYNC_BASELINE_INITIALIZED="false"

    local mfile
    mfile=$(manifest_path)

    if [[ ! -f "$mfile" ]]; then
        SYNC_BASELINE_INITIALIZED="true"
        return 0
    fi

    local rel hash
    while IFS=$'\t' read -r rel hash || [[ -n "$rel" ]]; do
        [[ -z "$rel" ]] && continue
        [[ "$rel" == \#* ]] && continue
        [[ -z "$hash" ]] && continue
        MANIFEST_KEYS+=("$rel")
        MANIFEST_VALUES+=("$hash")
    done < "$mfile"
}

# Compare every entry in the loaded manifest against the current dest file.
# Populates SYNC_DRIFT_DETECTED with rel paths whose hash diverges.
# A missing dest file is NOT drift — sync will simply rewrite it.
manifest_check_drift() {
    SYNC_DRIFT_DETECTED=()
    [[ ${#MANIFEST_KEYS[@]} -gt 0 ]] || return 0
    [[ -n "$(_manifest_hash_cmd)" ]] || return 0

    # Gather every manifest entry whose dest still exists (missing = not drift).
    local -a d_rel=() d_old=() d_abs=()
    local i rel dest_abs
    for ((i = 0; i < ${#MANIFEST_KEYS[@]}; i++)); do
        rel="${MANIFEST_KEYS[$i]}"
        dest_abs="$REPO_ROOT/$rel"
        [[ -f "$dest_abs" ]] || continue
        d_rel+=("$rel")
        d_old+=("${MANIFEST_VALUES[$i]}")
        d_abs+=("$dest_abs")
    done
    [[ ${#d_abs[@]} -gt 0 ]] || return 0

    # Hash them all in one batch, then zip results back by position.
    local -a cur=()
    local line
    while IFS= read -r line; do
        cur+=("${line%% *}")
    done < <(printf '%s\0' "${d_abs[@]}" | _manifest_hash_stream)

    # Unexpected line count → fall back to per-file hashing so correctness holds.
    if [[ ${#cur[@]} -ne ${#d_abs[@]} ]]; then
        cur=()
        for dest_abs in "${d_abs[@]}"; do
            cur+=("$(manifest_compute_hash "$dest_abs" 2>/dev/null || true)")
        done
    fi

    for ((i = 0; i < ${#d_abs[@]}; i++)); do
        [[ -n "${cur[$i]}" ]] || continue
        if [[ "${cur[$i]}" != "${d_old[$i]}" ]]; then
            SYNC_DRIFT_DETECTED+=("${d_rel[$i]}")
        fi
    done
}

# Record that we wrote (or rewrote) a destination file during this run.
# Idempotent — repeated calls for the same path collapse to a single entry.
# Usage: manifest_record_write "/abs/path"
manifest_record_write() {
    local abs_path="$1"
    [[ -z "$abs_path" ]] && return 0

    local rel
    rel=$(to_repo_relative_path "$abs_path" 2>/dev/null) || return 0
    [[ -z "$rel" ]] && return 0

    if [[ "$SYNC_TOUCHED_SET" != *"|$rel|"* ]]; then
        SYNC_TOUCHED_PATHS+=("$rel")
        SYNC_TOUCHED_SET="${SYNC_TOUCHED_SET}${rel}|"
    fi
}

# Was <abs_path> written (or rewritten) earlier in THIS sync run? A file the run
# already produced is a current output, never obsolete — sweep loops use this to
# skip it instead of pruning it (e.g. an AGENTS file the agents step copies into
# a rules dir that the rules step then sweeps). Returns 0 = touched this run.
# Usage: manifest_was_touched "/abs/path"
manifest_was_touched() {
    local abs_path="$1"
    [[ -z "$abs_path" ]] && return 1
    local rel
    rel=$(to_repo_relative_path "$abs_path" 2>/dev/null) || return 1
    [[ -z "$rel" ]] && return 1
    [[ "$SYNC_TOUCHED_SET" == *"|$rel|"* ]]
}

# Record every regular file under a directory (recursively). Used after
# operations like `cp -r` where individual leaf paths weren't tracked.
# Usage: manifest_record_tree "/abs/dir"
manifest_record_tree() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0

    local f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        manifest_record_write "$f"
    done < <(find "$dir" -type f 2>/dev/null)
}

# Update or insert a single manifest entry, preserving every other line.
# Used by `agentsync adopt` after copying dest → source: the dest content
# stayed put, so we record its fresh hash and the next sync sees no drift.
# Usage: manifest_update_entry "<rel_path>" "<sha256>"
manifest_update_entry() {
    local rel="$1"
    local hash="$2"
    [[ -z "$rel" ]] && return 0
    [[ -z "$hash" ]] && return 0

    local mfile
    mfile=$(manifest_path)
    ensure_dir "$(dirname "$mfile")"

    local tmp="${mfile}.tmp.$$"
    : > "$tmp"

    if [[ -f "$mfile" ]]; then
        local existing_rel existing_hash
        while IFS=$'\t' read -r existing_rel existing_hash || [[ -n "$existing_rel" ]]; do
            [[ -z "$existing_rel" ]] && continue
            [[ "$existing_rel" == "$rel" ]] && continue
            printf '%s\t%s\n' "$existing_rel" "$existing_hash" >> "$tmp"
        done < "$mfile"
    fi

    printf '%s\t%s\n' "$rel" "$hash" >> "$tmp"
    LC_ALL=C sort -u -o "$tmp" "$tmp"
    mv "$tmp" "$mfile"
}

# Write the new manifest atomically. Result = union of:
#   1. Old entries whose dest file still exists and wasn't touched this run
#      (preserves entries for tools skipped via --only/--skip).
#   2. Freshly-hashed entries for every path we wrote this run.
# Entries whose dest no longer exists (cleanup, manual delete) are dropped.
# When the resulting set is empty, the manifest file itself is removed.
manifest_write() {
    [[ "${DRY_RUN:-false}" == "true" ]] && return 0

    local mfile
    mfile=$(manifest_path)
    ensure_dir "$(dirname "$mfile")"

    local tmp="${mfile}.tmp.$$"
    : > "$tmp"

    local i rel old_hash abs hash
    for ((i = 0; i < ${#MANIFEST_KEYS[@]}; i++)); do
        rel="${MANIFEST_KEYS[$i]}"
        old_hash="${MANIFEST_VALUES[$i]}"
        abs="$REPO_ROOT/$rel"
        [[ -f "$abs" ]] || continue
        [[ "$SYNC_TOUCHED_SET" == *"|$rel|"* ]] && continue
        printf '%s\t%s\n' "$rel" "$old_hash" >> "$tmp"
    done

    if [[ ${#SYNC_TOUCHED_PATHS[@]} -gt 0 ]]; then
        # Collect touched files that still exist, hash them in one batch, then
        # zip results back by position (xargs preserves order).
        local -a t_rel=() t_abs=()
        for rel in "${SYNC_TOUCHED_PATHS[@]}"; do
            abs="$REPO_ROOT/$rel"
            [[ -f "$abs" ]] || continue
            t_rel+=("$rel")
            t_abs+=("$abs")
        done
        if [[ ${#t_abs[@]} -gt 0 ]]; then
            local -a t_hash=()
            local line
            while IFS= read -r line; do
                t_hash+=("${line%% *}")
            done < <(printf '%s\0' "${t_abs[@]}" | _manifest_hash_stream)
            if [[ ${#t_hash[@]} -ne ${#t_abs[@]} ]]; then
                t_hash=()
                for abs in "${t_abs[@]}"; do
                    t_hash+=("$(manifest_compute_hash "$abs" 2>/dev/null || true)")
                done
            fi
            for ((i = 0; i < ${#t_abs[@]}; i++)); do
                [[ -n "${t_hash[$i]}" ]] || continue
                printf '%s\t%s\n' "${t_rel[$i]}" "${t_hash[$i]}" >> "$tmp"
            done
        fi
    fi

    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        if [[ -f "$mfile" ]]; then
            rm -f "$mfile"
            log_info "Removed .ai/.sync-manifest (no tracked outputs)"
        fi
        return 0
    fi

    LC_ALL=C sort -u -o "$tmp" "$tmp"
    mv "$tmp" "$mfile"

    if [[ "$SYNC_BASELINE_INITIALIZED" == "true" ]]; then
        local count
        count=$(wc -l < "$mfile" 2>/dev/null | tr -d ' ')
        log_info "Initialized .ai/.sync-manifest with ${count:-0} entries — commit it to track drift in CI"
    fi
}
