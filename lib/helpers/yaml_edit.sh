#!/usr/bin/env bash
# Safe YAML editing — line-oriented mutation of simple YAML files.
# Limitations match the AgentSync YAML parser: handles `key: value` lines
# and block-style lists (`- item`). No multi-doc, no flow collections except
# single-line `[a, b]`, no anchors.
#
# All functions write atomically (temp file + mv) and never touch comments.

# ── Utilities ─────────────────────────────────────────────────────────────────

# Count leading spaces of a line.
_yaml_leading_indent() {
    local line="$1"
    local stripped="${line#"${line%%[![:space:]]*}"}"
    echo $(( ${#line} - ${#stripped} ))
}

# Strip trailing whitespace from a line.
_yaml_rtrim() {
    local line="$1"
    echo "${line%"${line##*[![:space:]]}"}"
}

# Atomic write: writes content from stdin to $1 via a sibling temp file.
_yaml_atomic_write() {
    local dest="$1"
    local tmp
    tmp=$(mktemp "${dest}.XXXXXX") || return 1
    cat > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$dest"
}

# Ensure the parent directory for a file exists.
_yaml_ensure_parent_dir() {
    local file="$1"
    local dir
    dir=$(dirname "$file")
    [[ -d "$dir" ]] || mkdir -p "$dir"
}

# Find the line number (1-based) of a key at a given dot-notation path.
# Prints "lineno indent" on success, nothing if not found.
# The line must be a `key:` (block) or `key: value` (scalar) form.
_yaml_find_key_line() {
    local file="$1"
    local key_path="$2"
    [[ -f "$file" ]] || return 0

    local -a keys
    IFS='.' read -ra keys <<< "$key_path"
    local depth=${#keys[@]}

    local looking_for="${keys[0]}"
    local next_key_index=1
    local in_section=false
    local section_indent=0
    local lineno=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        ((lineno++)) || true
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        local stripped="${line#"${line%%[![:space:]]*}"}"
        local indent=$(( ${#line} - ${#stripped} ))

        local line_key
        if [[ "$stripped" =~ ^([a-zA-Z0-9_-]+):[[:space:]]*(.*) ]]; then
            line_key="${BASH_REMATCH[1]}"
        elif [[ "$stripped" =~ ^([a-zA-Z0-9_-]+):$ ]]; then
            line_key="${BASH_REMATCH[1]}"
        else
            continue
        fi

        if [[ "$in_section" == false ]]; then
            if [[ $indent -eq 0 ]] && [[ "$line_key" == "$looking_for" ]]; then
                if [[ $next_key_index -eq $depth ]]; then
                    echo "$lineno $indent"
                    return 0
                fi
                in_section=true
                section_indent=$indent
                looking_for="${keys[$next_key_index]}"
                ((next_key_index++)) || true
            fi
        else
            if [[ $indent -le $section_indent ]]; then
                return 0
            fi
            if [[ "$line_key" == "$looking_for" ]]; then
                if [[ $next_key_index -eq $depth ]]; then
                    echo "$lineno $indent"
                    return 0
                fi
                section_indent=$indent
                looking_for="${keys[$next_key_index]}"
                ((next_key_index++)) || true
            fi
        fi
    done < "$file"
}

# ── Scalar set/remove ─────────────────────────────────────────────────────────

# Set a top-level scalar key. Creates the file if needed.
# Only handles keys at root depth (no nested-path creation); callers needing
# nested sets should write the block manually.
# Usage: yaml_set_scalar <file> <key> <value>
yaml_set_scalar() {
    local file="$1"
    local key="$2"
    local value="$3"

    _yaml_ensure_parent_dir "$file"

    if [[ ! -f "$file" ]]; then
        printf '%s: %s\n' "$key" "$value" | _yaml_atomic_write "$file"
        return $?
    fi

    local found=false
    {
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$found" == false ]] && [[ "$line" =~ ^${key}:[[:space:]] ]]; then
                printf '%s: %s\n' "$key" "$value"
                found=true
            elif [[ "$found" == false ]] && [[ "$line" == "${key}:" ]]; then
                printf '%s: %s\n' "$key" "$value"
                found=true
            else
                printf '%s\n' "$line"
            fi
        done < "$file"

        if [[ "$found" == false ]]; then
            printf '%s: %s\n' "$key" "$value"
        fi
    } | _yaml_atomic_write "$file"
}

# Remove a key and the nested block that belongs to it.
# Usage: yaml_remove_key <file> <dot.path>
yaml_remove_key() {
    local file="$1"
    local key_path="$2"
    [[ -f "$file" ]] || return 0

    local found
    found=$(_yaml_find_key_line "$file" "$key_path")
    [[ -z "$found" ]] && return 0

    local target_line target_indent
    target_line=$(echo "$found" | awk '{print $1}')
    target_indent=$(echo "$found" | awk '{print $2}')

    local lineno=0
    local skipping=false
    local skip_indent_threshold=-1

    {
        while IFS= read -r line || [[ -n "$line" ]]; do
            ((lineno++)) || true

            if [[ "$lineno" -eq "$target_line" ]]; then
                skipping=true
                skip_indent_threshold="$target_indent"
                continue
            fi

            if [[ "$skipping" == "true" ]]; then
                if [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*$ ]]; then
                    # Blank line: keep skipping; will be preserved if not followed by deeper content.
                    continue
                fi
                local stripped="${line#"${line%%[![:space:]]*}"}"
                local indent=$(( ${#line} - ${#stripped} ))
                if [[ $indent -gt $skip_indent_threshold ]]; then
                    # Still inside the removed block (including `-` list items).
                    continue
                fi
                # Back at or above target indent → stop skipping and emit this line.
                skipping=false
            fi

            printf '%s\n' "$line"
        done < "$file"
    } | _yaml_atomic_write "$file"
}

# Rename a key (simple case: preserves value and nested block).
# Usage: yaml_rename_key <file> <old.dot.path> <new_leaf_name>
# Only renames the leaf of the path (e.g. merge_to_file → merge_into_single_file).
yaml_rename_key() {
    local file="$1"
    local old_path="$2"
    local new_leaf="$3"
    [[ -f "$file" ]] || return 0

    local found
    found=$(_yaml_find_key_line "$file" "$old_path")
    [[ -z "$found" ]] && return 0

    local target_line
    target_line=$(echo "$found" | awk '{print $1}')

    local old_leaf="${old_path##*.}"
    local lineno=0

    {
        while IFS= read -r line || [[ -n "$line" ]]; do
            ((lineno++)) || true
            if [[ "$lineno" -eq "$target_line" ]]; then
                # Replace the first occurrence of old_leaf: with new_leaf:
                printf '%s\n' "${line/${old_leaf}:/${new_leaf}:}"
            else
                printf '%s\n' "$line"
            fi
        done < "$file"
    } | _yaml_atomic_write "$file"
}

# ── List mutations (block style) ──────────────────────────────────────────────

# Append an item to a block-style list under <path> (creates structures as needed).
# Usage: yaml_list_append <file> <dot.path> <value>
# Only works for top-level or first-level nested lists (e.g. tools.enabled).
yaml_list_append() {
    local file="$1"
    local path="$2"
    local value="$3"

    _yaml_ensure_parent_dir "$file"

    # Skip if already present
    local existing
    while IFS= read -r existing; do
        [[ "$existing" == "$value" ]] && return 0
    done < <(parse_yaml_list "$file" "$path" 2>/dev/null || true)

    # Case A: file doesn't exist or path missing — create it
    if [[ ! -f "$file" ]] || [[ -z "$(_yaml_find_key_line "$file" "$path")" ]]; then
        local -a segs
        IFS='.' read -ra segs <<< "$path"
        local existing_content=""
        [[ -f "$file" ]] && existing_content=$(cat "$file")

        {
            [[ -n "$existing_content" ]] && { printf '%s\n' "$existing_content"; echo ""; }
            local i indent=0
            for ((i=0; i<${#segs[@]}; i++)); do
                printf '%*s%s:\n' "$indent" "" "${segs[$i]}"
                indent=$(( indent + 2 ))
            done
            printf '%*s- %s\n' "$indent" "" "$value"
        } | _yaml_atomic_write "$file"
        return 0
    fi

    # Case B: path exists — insert new dash-item right after the last existing item.
    local key_line_info
    key_line_info=$(_yaml_find_key_line "$file" "$path")
    local key_lineno key_indent
    key_lineno=$(echo "$key_line_info" | awk '{print $1}')
    key_indent=$(echo "$key_line_info" | awk '{print $2}')
    local item_indent=$(( key_indent + 2 ))

    # Leaf key (last path segment).
    local leaf="${path##*.}"

    # Detect inline form: `key: [...]` or `key: value` on the same line.
    # If present, we rewrite that line to bare `key:` before appending.
    local key_line_content=""
    local lineno=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((lineno++)) || true
        if [[ $lineno -eq $key_lineno ]]; then
            key_line_content="$line"
            break
        fi
    done < "$file"

    local has_inline=false
    if [[ "$key_line_content" =~ ^[[:space:]]*${leaf}:[[:space:]]+.+$ ]]; then
        has_inline=true
    fi

    # Find last existing dash-item at item_indent beneath the key.
    lineno=0
    local last_item_lineno="$key_lineno"
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((lineno++)) || true
        if [[ $lineno -le $key_lineno ]]; then
            continue
        fi
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        local stripped="${line#"${line%%[![:space:]]*}"}"
        local indent=$(( ${#line} - ${#stripped} ))
        if [[ $indent -lt $item_indent ]]; then
            break
        fi
        if [[ "$stripped" =~ ^- ]]; then
            last_item_lineno=$lineno
        fi
    done < "$file"

    # Rewrite file: collapse inline form to bare key, then insert dash-item.
    lineno=0
    {
        while IFS= read -r line || [[ -n "$line" ]]; do
            ((lineno++)) || true
            if [[ $lineno -eq $key_lineno ]] && [[ "$has_inline" == "true" ]]; then
                printf '%*s%s:\n' "$key_indent" "" "$leaf"
            else
                printf '%s\n' "$line"
            fi
            if [[ $lineno -eq $last_item_lineno ]]; then
                printf '%*s- %s\n' "$item_indent" "" "$value"
            fi
        done < "$file"
    } | _yaml_atomic_write "$file"
}

# Remove an item from a block-style list under <path>.
# Usage: yaml_list_remove <file> <dot.path> <value>
yaml_list_remove() {
    local file="$1"
    local path="$2"
    local value="$3"
    [[ -f "$file" ]] || return 0

    local key_line_info
    key_line_info=$(_yaml_find_key_line "$file" "$path")
    [[ -z "$key_line_info" ]] && return 0
    local key_lineno key_indent
    key_lineno=$(echo "$key_line_info" | awk '{print $1}')
    key_indent=$(echo "$key_line_info" | awk '{print $2}')
    local item_indent=$(( key_indent + 2 ))

    local lineno=0
    {
        while IFS= read -r line || [[ -n "$line" ]]; do
            ((lineno++)) || true
            if [[ $lineno -le $key_lineno ]]; then
                printf '%s\n' "$line"
                continue
            fi
            local stripped="${line#"${line%%[![:space:]]*}"}"
            local indent=$(( ${#line} - ${#stripped} ))
            if [[ -n "$stripped" ]] && [[ $indent -lt $item_indent ]]; then
                printf '%s\n' "$line"
                continue
            fi
            if [[ "$stripped" =~ ^-[[:space:]]*(.*)$ ]]; then
                local item="${BASH_REMATCH[1]}"
                local normalized
                normalized=$(_yaml_normalize_scalar "$item")
                if [[ "$normalized" == "$value" ]]; then
                    continue
                fi
            fi
            printf '%s\n' "$line"
        done < "$file"
    } | _yaml_atomic_write "$file"
}
