#!/usr/bin/env bash
# File operation utilities for AI Sync Script
# Cross-platform compatible (Unix/macOS/Git Bash)

# Ensure directory exists
# Usage: ensure_dir "/path/to/dir"
ensure_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
    fi
}

# Cleanup a file or directory if it exists
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

# Copy file with cleanup (rm + cp)
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
    
    # Ensure parent directory exists
    ensure_dir "$(dirname "$dest")"
    
    # Cleanup and copy
    rm -f "$dest" 2>/dev/null || true
    cp "$src" "$dest"
    
    log_step "$src → $dest"
}

# Sync directory recursively with safe differential cleanup
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
    
    # 1. Identify valid source items (relative paths)
    local source_items=""
    local count_copy=0
    
    # Iterate source to find what to copy
    for item in "$src"/*; do
        [[ -e "$item" ]] || continue
        local basename
        basename=$(basename "$item")
        
        if matches_filter "$basename" "$include" "$exclude"; then
            source_items="$source_items|$basename|"
            
            if [[ "$dry_run" == "true" ]]; then
                count_copy=$((count_copy + 1))
            else
                # Recursive copy (overwrite)
                rm -rf "${dest:?}/$basename" 2>/dev/null || true
                cp -r "$item" "$dest/$basename"
                count_copy=$((count_copy + 1))
            fi
        fi
    done
    
    # 2. Differential Cleanup
    local count_clean=0
    
    for dest_item in "$dest"/*; do
        [[ -e "$dest_item" ]] || continue
        local basename
        basename=$(basename "$dest_item")
        
        # Destination directory is owned by sync. Remove anything no longer selected.
        # This guarantees stale generated entries are cleaned up when filters change.
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

# Add header to file content
# Usage: add_header "file" "header_text"
add_header() {
    local file="$1"
    local header="$2"
    local temp_file
    
    if [[ ! -f "$file" ]]; then
        log_warning "File not found for header: $file"
        return 1
    fi
    
    # Create temp file in same directory for cross-platform compatibility
    temp_file="${file}.tmp"
    
    # Write header (interpret \n escape sequences) + newline + original content
    {
        printf '%b\n' "$header"
        echo ""
        cat "$file"
    } > "$temp_file"
    
    mv "$temp_file" "$file"
}

# Append imports to a file (for Claude)
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
    
    # Append imports section
    {
        echo ""
        echo "<!-- Auto-generated imports -->"
        
        # Find all .md files in rules dir and create @rules/filename imports
        for rule_file in "$rules_dir"/*.md; do
            if [[ -f "$rule_file" ]]; then
                local basename
                basename=$(basename "$rule_file")
                echo "@rules/${basename}"
            fi
        done
    } >> "$agents_file"
}

# Merge all rule files into a single output file
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

    # Prepend AGENTS.md content if provided
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

# Convert a markdown command file to Gemini TOML format
# Usage: convert_md_command_to_toml "src_file" "dest_file" "dry_run"
convert_md_command_to_toml() {
    local src_file="$1"
    local dest_file="$2"
    local dry_run="${3:-false}"

    if [[ "$dry_run" == "true" ]]; then
        log_step "$src_file → $dest_file (md→toml) (dry-run)"
        return 0
    fi

    ensure_dir "$(dirname "$dest_file")"
    _parse_md_frontmatter "$src_file"

    local description="$_FM_DESCRIPTION"
    local body="$_FM_BODY"

    # Convert !`cmd` syntax to !{cmd} syntax (Gemini format)
    body=$(echo "$body" | sed 's/!`\([^`]*\)`/!{\1}/g')

    # Convert $ARGUMENTS to {{args}} (Gemini format)
    body=$(echo "$body" | sed 's/\$ARGUMENTS/{{args}}/g')

    {
        if [[ -n "$description" ]]; then
            echo "description = \"$description\""
        fi
        echo "prompt = \"\"\""
        printf '%s' "$body"
        echo "\"\"\""
    } > "$dest_file"
}

# Sync commands with MD→TOML conversion
# Usage: sync_commands_as_toml "src_dir" "dest_dir" "dry_run"
sync_commands_as_toml() {
    local src_dir="$1"
    local dest_dir="$2"
    local dry_run="${3:-false}"

    if [[ ! -d "$src_dir" ]]; then
        return 0
    fi

    local count=0
    for src_file in "$src_dir"/*.md; do
        [[ -f "$src_file" ]] || continue
        local basename
        basename=$(basename "$src_file" .md)
        local dest_file="$dest_dir/$basename.toml"
        convert_md_command_to_toml "$src_file" "$dest_file" "$dry_run"
        count=$((count + 1))
    done

    if [[ $count -gt 0 ]]; then
        log_step "$src_dir/ → $dest_dir/ ($count commands, md→toml)"
    fi
}

# Parse YAML frontmatter from a markdown file.
# Sets variables: _FM_NAME, _FM_DESCRIPTION, _FM_BODY
# Usage: _parse_md_frontmatter "file"
_parse_md_frontmatter() {
    local src_file="$1"
    _FM_NAME=""
    _FM_DESCRIPTION=""
    _FM_BODY=""

    local in_frontmatter=false
    local frontmatter_done=false
    local in_multiline_desc=false

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$frontmatter_done" == "false" ]]; then
            if [[ "$line" == "---" ]] && [[ "$in_frontmatter" == "false" ]]; then
                in_frontmatter=true
                continue
            elif [[ "$line" == "---" ]] && [[ "$in_frontmatter" == "true" ]]; then
                frontmatter_done=true
                in_multiline_desc=false
                continue
            elif [[ "$in_frontmatter" == "true" ]]; then
                # Handle multi-line description continuation (indented lines)
                if [[ "$in_multiline_desc" == "true" ]]; then
                    if [[ "$line" =~ ^[[:space:]]+(.*) ]]; then
                        local cont="${BASH_REMATCH[1]}"
                        if [[ -n "$_FM_DESCRIPTION" ]]; then
                            _FM_DESCRIPTION="$_FM_DESCRIPTION $cont"
                        else
                            _FM_DESCRIPTION="$cont"
                        fi
                        continue
                    else
                        in_multiline_desc=false
                    fi
                fi

                if [[ "$line" =~ ^name:[[:space:]]*(.*) ]]; then
                    _FM_NAME="${BASH_REMATCH[1]}"
                    _FM_NAME="${_FM_NAME#\"}" ; _FM_NAME="${_FM_NAME%\"}"
                    _FM_NAME="${_FM_NAME#\'}" ; _FM_NAME="${_FM_NAME%\'}"
                elif [[ "$line" =~ ^description:[[:space:]]*\>$ ]]; then
                    # YAML folded scalar: description: >
                    in_multiline_desc=true
                    _FM_DESCRIPTION=""
                elif [[ "$line" =~ ^description:[[:space:]]*(.*) ]]; then
                    _FM_DESCRIPTION="${BASH_REMATCH[1]}"
                    _FM_DESCRIPTION="${_FM_DESCRIPTION#\"}" ; _FM_DESCRIPTION="${_FM_DESCRIPTION%\"}"
                    _FM_DESCRIPTION="${_FM_DESCRIPTION#\'}" ; _FM_DESCRIPTION="${_FM_DESCRIPTION%\'}"
                fi
                continue
            else
                frontmatter_done=true
            fi
        fi
        _FM_BODY+="$line"$'\n'
    done < "$src_file"
}

# Convert a markdown agent file to Codex TOML format
# Usage: convert_md_agent_to_toml "src_file" "dest_file" "dry_run"
convert_md_agent_to_toml() {
    local src_file="$1"
    local dest_file="$2"
    local dry_run="${3:-false}"

    if [[ "$dry_run" == "true" ]]; then
        log_step "$src_file → $dest_file (agent md→toml) (dry-run)"
        return 0
    fi

    ensure_dir "$(dirname "$dest_file")"
    _parse_md_frontmatter "$src_file"

    local name="${_FM_NAME:-$(basename "$src_file" .md)}"
    local description="$_FM_DESCRIPTION"
    local body="$_FM_BODY"

    {
        echo "name = \"$name\""
        if [[ -n "$description" ]]; then
            echo "description = \"$description\""
        fi
        echo "developer_instructions = \"\"\""
        printf '%s' "$body"
        echo "\"\"\""
    } > "$dest_file"
}

# Sync agents with MD→TOML conversion
# Usage: sync_agents_as_toml "src_dir" "dest_dir" "dry_run"
sync_agents_as_toml() {
    local src_dir="$1"
    local dest_dir="$2"
    local dry_run="${3:-false}"

    if [[ ! -d "$src_dir" ]]; then
        return 0
    fi

    local count=0
    for src_file in "$src_dir"/*.md; do
        [[ -f "$src_file" ]] || continue
        local basename
        basename=$(basename "$src_file" .md)
        local dest_file="$dest_dir/$basename.toml"
        convert_md_agent_to_toml "$src_file" "$dest_file" "$dry_run"
        count=$((count + 1))
    done

    if [[ $count -gt 0 ]]; then
        log_step "$src_dir/ → $dest_dir/ ($count agents, md→toml)"
    fi
}

# Check if file matches include/exclude patterns
# Usage: matches_filter "filename" "include_glob" "exclude_glob"
matches_filter() {
    local filename="$1"
    local include="$2"
    local exclude="$3"
    
    # Default to match if no include pattern
    local matches_include=true
    if [[ -n "$include" ]]; then
        # Check against include pattern
        # shellcheck disable=SC2053
        if [[ $filename != $include ]]; then
            matches_include=false
        fi
    fi
    
    # Check exclude pattern
    if [[ -n "$exclude" ]]; then
        # shellcheck disable=SC2053
        if [[ $filename == $exclude ]]; then
            return 1 # Excluded
        fi
    fi
    
    if [[ "$matches_include" == "true" ]]; then
        return 0 # Matched
    else
        return 1 # Not matched
    fi
}

# Copy rules with optional extension change, header, and filtering
# Usage: copy_rules "src_dir" "dest_dir" "new_extension" "header" "dry_run" "include" "exclude"
# Pass empty string "" for optional args to skip
copy_rules() {
    local src_dir="$1"
    local dest_dir="$2"
    local new_ext="$3"
    local header="$4"
    local dry_run="${5:-false}"
    local include="${6:-}"
    local exclude="${7:-}"
    local count=0
    
    if [[ ! -d "$src_dir" ]]; then
        log_warning "Rules source not found: $src_dir"
        return 1
    fi
    
    # Prepare list of files to process (for counting in dry-run)
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
    
    # Ensure destination exists
    # We don't wipe the whole directory if filtering is used, to allow mixing sources?
    # No, clean sync philosophy says we own the directory. Filtering is for what goes IN.
    # But if we have multiple sources filling one dir, full wipe hurts.
    # For now, stick to simple "wipe and fill" logic. if filtering reduces set, so be it.
    rm -rf "$dest_dir" 2>/dev/null || true
    if [[ "$dry_run" != "true" ]]; then
        ensure_dir "$dest_dir"
    fi
    
    # Process valid files
    for src_file in "${files_to_process[@]}"; do
        local basename
        basename=$(basename "$src_file")
        local dest_file
        
        # Handle extension change
        if [[ -n "$new_ext" ]]; then
            dest_file="${dest_dir}/${basename%.md}${new_ext}"
        else
            dest_file="${dest_dir}/${basename}"
        fi
        
        # Copy file
        cp "$src_file" "$dest_file"
        
        # Add header if specified
        if [[ -n "$header" ]]; then
            add_header "$dest_file" "$header"
        fi
        
        count=$((count + 1))
    done
    
    local extra=""
    [[ -n "$header" ]] && extra="${extra}, +header"
    log_step "$src_dir/ → $dest_dir/ ($count files${extra})"
}

# Sync rules with safe differential sync
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
    
    # 1. Copy & Track expected files
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
                    add_header "$dest_path" "$header"
                fi
                count_copy=$((count_copy + 1))
            fi
        fi
    done
    
    # 2. Cleanup (Differential)
    for dest_file in "$dest_dir"/*; do
        [[ -f "$dest_file" ]] || continue
        local basename
        basename=$(basename "$dest_file")
        
        # Does this file LOOK like a rule?
        local is_managed=false
        
        if [[ -n "$new_ext" ]]; then
            if [[ "$basename" == *"$new_ext" ]]; then
                is_managed=true
            fi
        else
            if [[ "$basename" == *.md ]]; then
                is_managed=true
            fi
        fi
        
        if [[ "$is_managed" == "true" ]]; then
            if [[ "$valid_dest_files" != *"|$basename|"* ]]; then
                # Destination rules directory is sync-managed: delete obsolete outputs
                # even when the current include/exclude filters were changed.
                if [[ "$dry_run" == "true" ]]; then
                    log_step "Would remove: $dest_dir/$basename (obsolete)"
                else
                    rm -f "$dest_file"
                    log_step "Removed: $dest_dir/$basename"
                fi
                count_clean=$((count_clean + 1))
            fi
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
