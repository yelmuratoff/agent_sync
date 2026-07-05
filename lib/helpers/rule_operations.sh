#!/usr/bin/env bash
# Rule file operations for AgentSync sync engine.
# Cross-platform compatible (Unix/macOS/Git Bash)
# Depends on: logging.sh, filters.sh, file_ops.sh, format_conversion.sh

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

# Echo a rule's canonical `paths:` globs as a comma-separated list. Empty when
# the rule has no leading frontmatter or no `paths:` key.
_rule_paths_csv() {
    local file="$1"
    local first_line=""
    IFS= read -r first_line < "$file" || true
    [[ "$first_line" == "---" ]] || return 0
    sed -n '2,/^---$/p' "$file" | grep -q '^paths:[[:space:]]*$' || return 0
    sed -n '2,/^---$/p' "$file" \
        | sed -n 's/^[[:space:]]*-[[:space:]][[:space:]]*//p' \
        | sed -e 's/^["'\'']//' -e 's/["'\'']$//' \
        | paste -sd, -
}

# Remove a leading YAML frontmatter block (and the blank line after it) in place.
_strip_frontmatter() {
    local file="$1"
    local first_line=""
    IFS= read -r first_line < "$file" || true
    [[ "$first_line" == "---" ]] || return 0
    local tmp="${file}.tmp"
    sed '1,/^---$/d' "$file" | sed '/./,$!d' > "$tmp"
    mv "$tmp" "$file"
}

# Apply a tool's rule frontmatter. When the source rule declares canonical
# `paths:` scope and the tool provides a scoped_header (with a {globs}
# placeholder), translate that scope into the tool's native glob trigger;
# otherwise merge the always-on default header. A no-op when the tool defines
# neither — e.g. Claude, whose native `paths:` frontmatter is kept verbatim.
apply_rule_header() {
    local file="$1" header="$2" scoped_header="$3"
    local globs
    globs=$(_rule_paths_csv "$file")
    if [[ -n "$globs" && -n "$scoped_header" ]]; then
        _strip_frontmatter "$file"
        add_header "$file" "${scoped_header//\{globs\}/$globs}"
    elif [[ -n "$header" ]]; then
        merge_or_prepend_header "$file" "$header"
    fi
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
                local basename="${rule_file##*/}"
                echo "@rules/${basename}"
            fi
        done
    } >> "$agents_file"

    if declare -f manifest_record_write >/dev/null 2>&1; then
        manifest_record_write "$agents_file"
    fi
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

    local src_disp dest_disp
    src_disp=$(display_path "$src_dir")
    dest_disp=$(display_path "$dest_file")

    local files_to_merge=()
    for src_file in "$src_dir"/*.md; do
        [[ -f "$src_file" ]] || continue
        local basename="${src_file##*/}"
        if matches_filter "$basename" "$include" "$exclude"; then
            files_to_merge+=("$src_file")
        fi
    done

    if [[ "$dry_run" == "true" ]]; then
        local extra=""
        [[ -n "$agents_file" ]] && extra=" +agents"
        log_step "$src_disp/ → $dest_disp (${#files_to_merge[@]} files merged${extra}) (dry-run)"
        return 0
    fi

    ensure_dir "${dest_file%/*}"
    rm -f "$dest_file" 2>/dev/null || true

    if [[ -n "$agents_file" ]] && [[ -f "$agents_file" ]]; then
        cat "$agents_file" >> "$dest_file"
        echo "" >> "$dest_file"
        echo "---" >> "$dest_file"
        echo "" >> "$dest_file"
    fi

    local first=true
    for src_file in "${files_to_merge[@]+"${files_to_merge[@]}"}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo "" >> "$dest_file"
            echo "---" >> "$dest_file"
            echo "" >> "$dest_file"
        fi
        cat "$src_file" >> "$dest_file"
    done

    if declare -f manifest_record_write >/dev/null 2>&1; then
        manifest_record_write "$dest_file"
    fi

    log_step "$src_disp/ → $dest_disp (${#files_to_merge[@]} files merged)"
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
    local scoped_header="${8:-}"

    if [[ ! -d "$src_dir" ]]; then
        log_warning "Rules source not found: $src_dir"
        return 1
    fi

    local src_disp dest_disp
    src_disp=$(display_path "$src_dir")
    dest_disp=$(display_path "$dest_dir")

    if [[ "$dry_run" != "true" ]]; then
        ensure_dir "$dest_dir"
    fi

    local valid_dest_files=""
    local count_copy=0
    local count_clean=0

    # 1. Copy & track expected output filenames
    for src_file in "$src_dir"/*.md; do
        [[ -f "$src_file" ]] || continue
        local basename="${src_file##*/}"

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
                apply_rule_header "$dest_path" "$header" "$scoped_header"
                if declare -f manifest_record_write >/dev/null 2>&1; then
                    manifest_record_write "$dest_path"
                fi
                count_copy=$((count_copy + 1))
            fi
        fi
    done

    # 2. Differential cleanup — remove managed files no longer in source
    for dest_file in "$dest_dir"/*; do
        [[ -f "$dest_file" ]] || continue
        local basename="${dest_file##*/}"

        local is_managed=false
        if [[ -n "$new_ext" ]]; then
            [[ "$basename" == *"$new_ext" ]] && is_managed=true
        else
            [[ "$basename" == *.md ]] && is_managed=true
        fi

        if [[ "$is_managed" == "true" ]] && [[ "$valid_dest_files" != *"|$basename|"* ]]; then
            # A file this run already wrote (e.g. an AGENTS file the agents step
            # copied into this rules dir) is a current output, not obsolete.
            if declare -f manifest_was_touched >/dev/null 2>&1 && manifest_was_touched "$dest_file"; then
                continue
            fi
            if ! sync_may_prune "$dest_file"; then
                sync_note_preserved "$dest_disp/$basename" "$dry_run"
                continue
            fi
            if [[ "$dry_run" == "true" ]]; then
                log_step "Would remove: $dest_disp/$basename (obsolete)"
            else
                rm -f "$dest_file"
                log_step "Removed: $dest_disp/$basename"
            fi
            count_clean=$((count_clean + 1))
        fi
    done

    local extra=""
    [[ -n "$include" ]] && extra="${extra}, include='$include'"
    if [[ "$dry_run" == "true" ]]; then
        log_step "$src_disp/ → $dest_disp/ ($count_copy updates, $count_clean cleanups)${extra} (dry-run)"
    else
        log_step "$src_disp/ → $dest_disp/ ($count_copy updates, $count_clean cleanups)${extra}"
    fi
}

# Append a "## Commands" index section to an AGENTS-like file. Used for tools
# without a native commands surface AND without a separate skills dir (Amazon Q,
# Zed) — so the inlined index is the only way the agent learns the commands
# exist. Each entry is "- `name` — <description>" pulled from frontmatter.
#
# Idempotency note: this appends every run. The full AGENTS.md is regenerated
# upstream (copy + inline rules + inline skills + inline commands), so the
# section appears once per sync, not duplicated.
#
# Usage: inline_commands_to_file "src_commands_dir" "target_file" "include" "exclude"
inline_commands_to_file() {
    local src_dir="$1"
    local target_file="$2"
    local include="${3:-}"
    local exclude="${4:-}"

    [[ -d "$src_dir" ]] || return 0
    [[ -n "$target_file" ]] || return 0

    local entries=""
    local src_file basename name desc
    for src_file in "$src_dir"/*.md; do
        [[ -f "$src_file" ]] || continue
        basename="${src_file##*/}"
        if ! matches_filter "$basename" "$include" "$exclude"; then
            continue
        fi
        name="${basename%.md}"
        desc=$(read_frontmatter_field "$src_file" "description")
        if [[ -n "$desc" ]]; then
            entries+="- \`/${name}\` — ${desc}"$'\n'
        else
            entries+="- \`/${name}\`"$'\n'
        fi
    done

    [[ -n "$entries" ]] || return 0

    {
        echo ""
        echo "## Commands"
        echo ""
        echo "The following commands provide quick workflows. Find them in \`.ai/src/commands/\`:"
        echo ""
        printf '%s' "$entries"
    } >> "$target_file"

    if declare -f manifest_record_write >/dev/null 2>&1; then
        manifest_record_write "$target_file"
    fi
    log_step "Appended command index to ${target_file##*/}"
}

# Convert each .ai/src/commands/<name>.md into a generated skill directory
# at <skills_dest>/command-<name>/SKILL.md. Used for tools that lack a
# native slash-command surface (Codex, Amazon Q, Zed) so command workflows
# stay available through the skill mechanism instead.
#
# Frontmatter is regenerated (name: command-<name>, description carried over);
# `$ARGUMENTS` and !`cmd` slash-command sugar is rewritten into plain prose
# the skill reader will understand.
#
# Differential cleanup removes stale command-<name>/ dirs whose source file
# no longer exists. Non-generated skill dirs (anything not matching
# command-*) are left untouched.
#
# Usage: sync_commands_as_skills "src_commands_dir" "skills_dest_dir" "dry_run" "include" "exclude"
sync_commands_as_skills() {
    local src_dir="$1"
    local dest_dir="$2"
    local dry_run="${3:-false}"
    local include="${4:-}"
    local exclude="${5:-}"

    if [[ ! -d "$src_dir" ]]; then
        return 0
    fi

    local src_disp dest_disp
    src_disp=$(display_path "$src_dir")
    dest_disp=$(display_path "$dest_dir")

    if [[ "$dry_run" != "true" ]]; then
        ensure_dir "$dest_dir"
    fi

    local valid_dirs="|"
    local count=0

    local src_file
    for src_file in "$src_dir"/*.md; do
        [[ -f "$src_file" ]] || continue
        local basename name skill_dir_name skill_dir skill_file
        basename="${src_file##*/}"
        name="${basename%.md}"

        if ! matches_filter "$basename" "$include" "$exclude"; then
            continue
        fi

        skill_dir_name="command-${name}"
        valid_dirs="${valid_dirs}${skill_dir_name}|"
        skill_dir="$dest_dir/$skill_dir_name"
        skill_file="$skill_dir/SKILL.md"

        count=$((count + 1))
        if [[ "$dry_run" == "true" ]]; then
            continue
        fi

        local description
        description=$(read_frontmatter_field "$src_file" "description")
        if [[ -z "$description" ]]; then
            description="Run the /${name} command workflow."
        fi

        local body
        body=$(awk '
            BEGIN { in_fm = 0; fm_seen = 0; body_started = 0 }
            NR == 1 && /^---$/ { in_fm = 1; next }
            in_fm == 1 && /^---$/ { in_fm = 0; fm_seen = 1; next }
            in_fm == 1 { next }
            !body_started && /^$/ && fm_seen { next }
            { body_started = 1; print }
        ' "$src_file" \
          | sed -e 's/\$ARGUMENTS/<arg>/g' \
                -e 's/!`/`/g')

        ensure_dir "$skill_dir"

        {
            printf '%s\n' "---"
            printf 'name: "command-%s"\n' "$name"
            printf 'description: >-\n'
            printf '  %s\n' "$description"
            printf '%s\n' "---"
            printf '\n'
            printf '%s\n' "$body"
        } > "$skill_file"

        if declare -f manifest_record_write >/dev/null 2>&1; then
            manifest_record_write "$skill_file"
        fi
    done

    local d d_name
    for d in "$dest_dir"/command-*/; do
        [[ -d "$d" ]] || continue
        # Trailing slash from the */ glob: strip it before taking the leaf.
        d_name="${d%/}"; d_name="${d_name##*/}"
        if [[ "$valid_dirs" != *"|${d_name}|"* ]]; then
            if [[ "$dry_run" == "true" ]]; then
                log_step "Would remove obsolete generated skill: $d_name"
            else
                rm -rf "$d"
                log_step "Removed obsolete generated skill: $d_name"
            fi
        fi
    done

    if [[ "$dry_run" == "true" ]]; then
        log_step "$src_disp/*.md → $dest_disp/command-*/SKILL.md ($count generated) (dry-run)"
    else
        log_step "$src_disp/*.md → $dest_disp/command-*/SKILL.md ($count generated)"
    fi
}
