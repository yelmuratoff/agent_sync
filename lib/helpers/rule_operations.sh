#!/usr/bin/env bash
# Rule file operations for AgentSync sync engine.
# Cross-platform compatible (Unix/macOS/Git Bash)
# Depends on: logging.sh, filters.sh, file_ops.sh

# Prepend a header to an existing file.
# Usage: add_header "file" "header_text"
add_header() {
    local file="$1"
    local header="$2"

    if [[ ! -f "$file" ]]; then
        log_warning "File not found for header: $file"
        return 1
    fi

    local temp_file="${file}.tmp"

    {
        printf '%b\n' "$header"
        echo ""
        cat "$file"
    } > "$temp_file"

    mv "$temp_file" "$file"
}

# Apply a tool-default frontmatter header to a file.
# - If the file has no frontmatter: prepend header as a new frontmatter block.
# - If the file already has frontmatter: merge — source keys win, header only
#   contributes keys absent from the source. Lets users override per-rule
#   (custom globs/triggers/applyTo) while still inheriting tool defaults.
# Usage: merge_or_prepend_header "file" "header_text"
merge_or_prepend_header() {
    local file="$1"
    local header="$2"

    if [[ ! -f "$file" ]]; then
        log_warning "File not found for header: $file"
        return 1
    fi

    local first_line=""
    IFS= read -r first_line < "$file" || true

    if [[ "$first_line" != "---" ]]; then
        add_header "$file" "$header"
        return
    fi

    local existing_keys="|"
    local in_fm=false
    local saw_close=false
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$saw_close" == "true" ]]; then
            break
        fi
        if [[ "$line" == "---" ]]; then
            if [[ "$in_fm" == "false" ]]; then
                in_fm=true
            else
                saw_close=true
            fi
            continue
        fi
        if [[ "$in_fm" == "true" ]] && [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_-]*): ]]; then
            existing_keys="${existing_keys}${BASH_REMATCH[1]}|"
        fi
    done < "$file"

    local additions=""
    local hline
    while IFS= read -r hline || [[ -n "$hline" ]]; do
        [[ "$hline" == "---" ]] && continue
        [[ -z "$hline" ]] && continue
        if [[ "$hline" =~ ^([A-Za-z_][A-Za-z0-9_-]*): ]]; then
            local key="${BASH_REMATCH[1]}"
            if [[ "$existing_keys" != *"|${key}|"* ]]; then
                additions+="${hline}"$'\n'
            fi
        fi
    done < <(printf '%b' "$header")

    [[ -z "$additions" ]] && return 0

    local temp_file="${file}.tmp"
    local fm_count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "---" ]]; then
            fm_count=$((fm_count + 1))
            if [[ "$fm_count" -eq 2 ]]; then
                printf '%s' "$additions"
            fi
        fi
        printf '%s\n' "$line"
    done < "$file" > "$temp_file"

    mv "$temp_file" "$file"
}

# Append @rules/<filename> import lines into an agents file.
# Usage: append_imports "agents_file" "rules_dir"
append_imports() {
    local agents_file="$1"
    local rules_dir="$2"

    if [[ ! -f "$agents_file" ]]; then
        log_warning "Agents file not found: $agents_file"
        return 1
    fi

    if [[ ! -d "$rules_dir" ]]; then
        log_warning "Rules directory not found for imports: $rules_dir"
        return 1
    fi

    {
        echo ""
        echo "<!-- Auto-generated imports -->"

        for rule_file in "$rules_dir"/*.md; do
            if [[ -f "$rule_file" ]]; then
                local basename
                basename=$(basename "$rule_file")
                echo "@rules/${basename}"
            fi
        done
    } >> "$agents_file"
}

# Merge all matching rule files into a single output file.
# Optionally prepend an agents file as a preamble.
# Usage: merge_rules_to_file "src_dir" "dest_file" "dry_run" "include" "exclude" ["agents_file"]
merge_rules_to_file() {
    local src_dir="$1"
    local dest_file="$2"
    local dry_run="${3:-false}"
    local include="${4:-}"
    local exclude="${5:-}"
    local agents_file="${6:-}"

    if [[ ! -d "$src_dir" ]]; then
        log_warning "Rules source not found: $src_dir"
        return 1
    fi

    local files_to_merge=()
    for src_file in "$src_dir"/*.md; do
        [[ -f "$src_file" ]] || continue
        local basename
        basename=$(basename "$src_file")
        if matches_filter "$basename" "$include" "$exclude"; then
            files_to_merge+=("$src_file")
        fi
    done

    if [[ "$dry_run" == "true" ]]; then
        local extra=""
        [[ -n "$agents_file" ]] && extra=" +agents"
        log_step "$src_dir/ → $dest_file (${#files_to_merge[@]} files merged${extra}) (dry-run)"
        return 0
    fi

    ensure_dir "$(dirname "$dest_file")"
    rm -f "$dest_file" 2>/dev/null || true

    if [[ -n "$agents_file" ]] && [[ -f "$agents_file" ]]; then
        cat "$agents_file" >> "$dest_file"
        echo "" >> "$dest_file"
        echo "---" >> "$dest_file"
        echo "" >> "$dest_file"
    fi

    local first=true
    for src_file in "${files_to_merge[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo "" >> "$dest_file"
            echo "---" >> "$dest_file"
            echo "" >> "$dest_file"
        fi
        cat "$src_file" >> "$dest_file"
    done

    log_step "$src_dir/ → $dest_file (${#files_to_merge[@]} files merged)"
}

# Copy rule files from source to destination, optionally changing extensions and
# adding a header. Performs a full wipe-and-fill (no differential cleanup).
# Usage: copy_rules "src_dir" "dest_dir" "new_extension" "header" "dry_run" "include" "exclude"
copy_rules() {
    local src_dir="$1"
    local dest_dir="$2"
    local new_ext="$3"
    local header="$4"
    local dry_run="${5:-false}"
    local include="${6:-}"
    local exclude="${7:-}"

    if [[ ! -d "$src_dir" ]]; then
        log_warning "Rules source not found: $src_dir"
        return 1
    fi

    local files_to_process=()
    for src_file in "$src_dir"/*.md; do
        [[ -f "$src_file" ]] || continue
        local basename
        basename=$(basename "$src_file")
        if matches_filter "$basename" "$include" "$exclude"; then
            files_to_process+=("$src_file")
        fi
    done

    if [[ "$dry_run" == "true" ]]; then
        local extra=""
        [[ -n "$header" ]] && extra="${extra}, +header"
        [[ -n "$include" ]] && extra="${extra}, include='$include'"
        [[ -n "$exclude" ]] && extra="${extra}, exclude='$exclude'"
        log_step "$src_dir/ → $dest_dir/ (${#files_to_process[@]} files${extra}) (dry-run)"
        return 0
    fi

    rm -rf "$dest_dir" 2>/dev/null || true
    ensure_dir "$dest_dir"

    local count=0
    for src_file in "${files_to_process[@]}"; do
        local basename
        basename=$(basename "$src_file")
        local dest_file

        if [[ -n "$new_ext" ]]; then
            dest_file="${dest_dir}/${basename%.md}${new_ext}"
        else
            dest_file="${dest_dir}/${basename}"
        fi

        cp "$src_file" "$dest_file"

        if [[ -n "$header" ]]; then
            merge_or_prepend_header "$dest_file" "$header"
        fi

        count=$((count + 1))
    done

    local extra=""
    [[ -n "$header" ]] && extra="${extra}, +header"
    log_step "$src_dir/ → $dest_dir/ ($count files${extra})"
}

# Sync rule files with differential cleanup — only removes files that were
# previously managed by this sync (matched by extension or .md suffix).
# Usage: sync_rules "src_dir" "dest_dir" "new_extension" "header" "dry_run" "include" "exclude"
sync_rules() {
    local src_dir="$1"
    local dest_dir="$2"
    local new_ext="$3"
    local header="$4"
    local dry_run="${5:-false}"
    local include="${6:-}"
    local exclude="${7:-}"

    if [[ ! -d "$src_dir" ]]; then
        log_warning "Rules source not found: $src_dir"
        return 1
    fi

    if [[ "$dry_run" != "true" ]]; then
        ensure_dir "$dest_dir"
    fi

    local valid_dest_files=""
    local count_copy=0
    local count_clean=0

    # 1. Copy & track expected output filenames
    for src_file in "$src_dir"/*.md; do
        [[ -f "$src_file" ]] || continue
        local basename
        basename=$(basename "$src_file")

        if matches_filter "$basename" "$include" "$exclude"; then
            local dest_name
            if [[ -n "$new_ext" ]]; then
                dest_name="${basename%.md}${new_ext}"
            else
                dest_name="${basename}"
            fi

            valid_dest_files="$valid_dest_files|$dest_name|"

            if [[ "$dry_run" == "true" ]]; then
                count_copy=$((count_copy + 1))
            else
                local dest_path="$dest_dir/$dest_name"
                cp "$src_file" "$dest_path"
                if [[ -n "$header" ]]; then
                    merge_or_prepend_header "$dest_path" "$header"
                fi
                count_copy=$((count_copy + 1))
            fi
        fi
    done

    # 2. Differential cleanup — remove managed files no longer in source
    for dest_file in "$dest_dir"/*; do
        [[ -f "$dest_file" ]] || continue
        local basename
        basename=$(basename "$dest_file")

        local is_managed=false
        if [[ -n "$new_ext" ]]; then
            [[ "$basename" == *"$new_ext" ]] && is_managed=true
        else
            [[ "$basename" == *.md ]] && is_managed=true
        fi

        if [[ "$is_managed" == "true" ]] && [[ "$valid_dest_files" != *"|$basename|"* ]]; then
            if [[ "$dry_run" == "true" ]]; then
                log_step "Would remove: $dest_dir/$basename (obsolete)"
            else
                rm -f "$dest_file"
                log_step "Removed: $dest_dir/$basename"
            fi
            count_clean=$((count_clean + 1))
        fi
    done

    local extra=""
    [[ -n "$include" ]] && extra="${extra}, include='$include'"
    if [[ "$dry_run" == "true" ]]; then
        log_step "$src_dir/ → $dest_dir/ ($count_copy updates, $count_clean cleanups)${extra} (dry-run)"
    else
        log_step "$src_dir/ → $dest_dir/ ($count_copy updates, $count_clean cleanups)${extra}"
    fi
}
