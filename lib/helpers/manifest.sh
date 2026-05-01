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

# Compute sha256 of a file. Echoes the bare hash, returns 1 if no tool found.
# Usage: manifest_compute_hash "/abs/path"
manifest_compute_hash() {
    local file="$1"
    [[ -f "$file" ]] || return 1

    local out
    if command -v sha256sum >/dev/null 2>&1; then
        out=$(sha256sum "$file" 2>/dev/null) || return 1
    elif command -v shasum >/dev/null 2>&1; then
        out=$(shasum -a 256 "$file" 2>/dev/null) || return 1
    else
        return 1
    fi
    echo "${out%% *}"
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
    local i rel old_hash dest_abs cur_hash
    for ((i = 0; i < ${#MANIFEST_KEYS[@]}; i++)); do
        rel="${MANIFEST_KEYS[$i]}"
        old_hash="${MANIFEST_VALUES[$i]}"
        dest_abs="$REPO_ROOT/$rel"
        [[ -f "$dest_abs" ]] || continue
        cur_hash=$(manifest_compute_hash "$dest_abs") || continue
        if [[ "$cur_hash" != "$old_hash" ]]; then
            SYNC_DRIFT_DETECTED+=("$rel")
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
        for rel in "${SYNC_TOUCHED_PATHS[@]}"; do
            abs="$REPO_ROOT/$rel"
            if [[ -f "$abs" ]]; then
                hash=$(manifest_compute_hash "$abs") || continue
                printf '%s\t%s\n' "$rel" "$hash" >> "$tmp"
            fi
        done
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
