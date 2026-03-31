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

    log_step "$src → $dest"
}

# Sync a directory recursively with differential cleanup.
# Files present at source (and matching filters) are copied; extraneous dest
# files are removed. The destination directory is fully owned by this sync.
# Usage: sync_dir "source_dir" "dest_dir" "dry_run" "include" "exclude"
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
