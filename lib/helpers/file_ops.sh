#!/usr/bin/env bash
# Basic file operation utilities for AgentSync sync engine.
# Cross-platform compatible (Unix/macOS/Git Bash)
# Depends on: logging.sh, filters.sh

# Ensure directory exists.
# Usage: ensure_dir "/path/to/dir"
ensure_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
    fi
}

# Remove a file or directory if it exists.
# Usage: cleanup_path "/path/to/target" "dry_run"
cleanup_path() {
    local target="$1"
    local dry_run="${2:-false}"

    if [[ -e "$target" ]]; then
        if [[ "$dry_run" == "true" ]]; then
            log_step "Would remove: $target (dry-run)"
        else
            rm -rf "$target"
            log_step "Removed: $target"
        fi
        return 0
    fi
    return 1
}

# Copy a single file, creating parent directories as needed.
# Usage: copy_file "source" "dest" ["dry_run"]
copy_file() {
    local src="$1"
    local dest="$2"
    local dry_run="${3:-false}"

    if [[ ! -f "$src" ]]; then
        log_warning "Source file not found: $src"
        return 1
    fi

    if [[ "$dry_run" == "true" ]]; then
        log_step "$src → $dest (dry-run)"
        return 0
    fi

    ensure_dir "$(dirname "$dest")"
    rm -f "$dest" 2>/dev/null || true
    cp "$src" "$dest"

    if declare -f manifest_record_write >/dev/null 2>&1; then
        manifest_record_write "$dest"
    fi

    log_step "$src → $dest"
}

# Decide whether an extraneous destination entry may be pruned during a sync.
# Inside a manifest-aware sync run, an entry the sync never generated (absent
# from the loaded manifest) is treated as user-authored and preserved unless the
# run is forced. Outside such a run — primitive or standalone callers such as
# unit tests — the legacy "destination is fully owned by sync" behavior applies.
# Returns 0 = safe to prune, 1 = preserve (looks user-authored).
# Usage: sync_may_prune "/abs/dest/path"
sync_may_prune() {
    local dest_path="$1"
    [[ "${SYNC_MANIFEST_ACTIVE:-false}" == "true" ]] || return 0
    [[ "${FORCE_SYNC:-false}" == "true" ]] && return 0
    declare -f manifest_lookup >/dev/null 2>&1 || return 0
    declare -f to_repo_relative_path >/dev/null 2>&1 || return 0
    local rel
    rel=$(to_repo_relative_path "$dest_path" 2>/dev/null) || return 0
    manifest_lookup "$rel" >/dev/null 2>&1 && return 0
    return 1
}

# Warn that an untracked destination entry was kept, and tally it for the run
# summary. Goes through log_warning (stdout) so it is never silent.
# Usage: sync_note_preserved "<shown_path>" "<dry_run>"
sync_note_preserved() {
    local shown="$1"
    local dry_run="${2:-false}"
    if [[ "$dry_run" == "true" ]]; then
        log_warning "Would keep $shown (not from .ai/src/; --force to prune)"
    else
        log_warning "Kept $shown (not from .ai/src/; move it into .ai/src/, or re-run with --force to prune)"
    fi
    SYNC_PRESERVED_COUNT=$(( ${SYNC_PRESERVED_COUNT:-0} + 1 ))
}

# Sync a directory recursively with differential cleanup.
# Files present at source (and matching filters) are copied; extraneous dest
# files are removed when sync owns them (see sync_may_prune — user-added files
# are preserved unless --force). Usage:
#   sync_dir "source_dir" "dest_dir" "dry_run" "include" "exclude"
sync_dir() {
    local src="$1"
    local dest="$2"
    local dry_run="${3:-false}"
    local include="${4:-}"
    local exclude="${5:-}"

    if [[ ! -d "$src" ]]; then
        log_warning "Source directory not found: $src"
        return 1
    fi

    if [[ "$dry_run" != "true" ]]; then
        ensure_dir "$dest"
    fi

    local source_items=""
    local count_copy=0

    for item in "$src"/*; do
        [[ -e "$item" ]] || continue
        local basename
        basename=$(basename "$item")

        if matches_filter "$basename" "$include" "$exclude"; then
            source_items="$source_items|$basename|"

            if [[ "$dry_run" == "true" ]]; then
                count_copy=$((count_copy + 1))
            else
                rm -rf "${dest:?}/$basename" 2>/dev/null || true
                cp -r "$item" "$dest/$basename"
                if declare -f manifest_record_write >/dev/null 2>&1; then
                    if [[ -d "$dest/$basename" ]]; then
                        manifest_record_tree "$dest/$basename"
                    else
                        manifest_record_write "$dest/$basename"
                    fi
                fi
                count_copy=$((count_copy + 1))
            fi
        fi
    done

    local count_clean=0
    for dest_item in "$dest"/*; do
        [[ -e "$dest_item" ]] || continue
        local basename
        basename=$(basename "$dest_item")

        if [[ "$source_items" != *"|$basename|"* ]]; then
            # Items the source filter would have skipped (include miss or
            # explicit exclude hit) are not owned by this sync_dir call —
            # leave them so another step (e.g. sync_commands_as_skills)
            # can manage its own subset of the destination.
            if ! matches_filter "$basename" "$include" "$exclude"; then
                continue
            fi
            if ! sync_may_prune "$dest_item"; then
                sync_note_preserved "$dest/$basename" "$dry_run"
                continue
            fi
            if [[ "$dry_run" == "true" ]]; then
                log_step "Would remove: $dest/$basename (extraneous)"
            else
                rm -rf "$dest_item"
                log_step "Removed: $dest/$basename"
            fi
            count_clean=$((count_clean + 1))
        fi
    done

    local extra=""
    [[ -n "$include" ]] && extra="${extra}, include='$include'"
    if [[ "$dry_run" == "true" ]]; then
        log_step "$src/ → $dest/ ($count_copy updates, $count_clean cleanups)${extra} (dry-run)"
    else
        log_step "$src/ → $dest/ ($count_copy updates, $count_clean cleanups)${extra}"
    fi
}
