#!/usr/bin/env bash
# Markdown frontmatter parsing and MD→TOML format conversion.
# Depends on: logging.sh, filters.sh, file_ops.sh

# Parse YAML frontmatter from a markdown file.
# Sets globals: _FM_NAME, _FM_DESCRIPTION, _FM_MODEL, _FM_TOOLS (newline-sep), _FM_BODY
# Usage: _parse_md_frontmatter "file"
_parse_md_frontmatter() {
    local src_file="$1"
    _FM_NAME=""
    _FM_DESCRIPTION=""
    _FM_MODEL=""
    _FM_TOOLS=""
    _FM_BODY=""

    local in_frontmatter=false
    local frontmatter_done=false
    local in_multiline_desc=false
    local in_tools_list=false

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$frontmatter_done" == "false" ]]; then
            if [[ "$line" == "---" ]] && [[ "$in_frontmatter" == "false" ]]; then
                in_frontmatter=true
                continue
            elif [[ "$line" == "---" ]] && [[ "$in_frontmatter" == "true" ]]; then
                frontmatter_done=true
                in_multiline_desc=false
                in_tools_list=false
                continue
            elif [[ "$in_frontmatter" == "true" ]]; then
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

                if [[ "$in_tools_list" == "true" ]]; then
                    if [[ "$line" =~ ^[[:space:]]+-[[:space:]]+(.*) ]]; then
                        local tool="${BASH_REMATCH[1]}"
                        tool="${tool#\"}" ; tool="${tool%\"}"
                        tool="${tool#\'}" ; tool="${tool%\'}"
                        _FM_TOOLS+="${tool}"$'\n'
                        continue
                    else
                        in_tools_list=false
                    fi
                fi

                if [[ "$line" =~ ^name:[[:space:]]*(.*) ]]; then
                    _FM_NAME="${BASH_REMATCH[1]}"
                    _FM_NAME="${_FM_NAME#\"}" ; _FM_NAME="${_FM_NAME%\"}"
                    _FM_NAME="${_FM_NAME#\'}" ; _FM_NAME="${_FM_NAME%\'}"
                elif [[ "$line" =~ ^model:[[:space:]]*(.*) ]]; then
                    _FM_MODEL="${BASH_REMATCH[1]}"
                    _FM_MODEL="${_FM_MODEL#\"}" ; _FM_MODEL="${_FM_MODEL%\"}"
                    _FM_MODEL="${_FM_MODEL#\'}" ; _FM_MODEL="${_FM_MODEL%\'}"
                elif [[ "$line" =~ ^tools:[[:space:]]*\[(.*)\][[:space:]]*$ ]]; then
                    # Inline list: tools: [Read, Grep, Glob]
                    local raw="${BASH_REMATCH[1]}"
                    local IFS_OLD="$IFS"
                    # Split on commas with pathname expansion OFF so a tool token
                    # containing a glob char is not expanded against the cwd.
                    local reglob=1; case $- in *f*) reglob=0 ;; esac
                    set -f
                    IFS=','
                    local item
                    for item in $raw; do
                        item="${item# }" ; item="${item% }"
                        item="${item#\"}" ; item="${item%\"}"
                        item="${item#\'}" ; item="${item%\'}"
                        [[ -n "$item" ]] && _FM_TOOLS+="${item}"$'\n'
                    done
                    IFS="$IFS_OLD"
                    (( reglob )) && set +f
                elif [[ "$line" =~ ^tools:[[:space:]]*$ ]]; then
                    in_tools_list=true
                elif [[ "$line" =~ ^description:[[:space:]]*\>$ ]]; then
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

# Read a single scalar field from a markdown file's YAML frontmatter.
# Only handles top-level `key: value` inside the leading `---` delimiters.
# Echoes the value (without surrounding quotes) on stdout; empty if no
# frontmatter or field absent. Stops scanning after the closing `---`.
#
# Used to read optional fields like `category:` without dragging in the
# full _parse_md_frontmatter state machine — keeps the call site cheap
# when doctor scans dozens of files.
#
# Usage: read_frontmatter_field "file.md" "category"
read_frontmatter_field() {
    local file="$1"
    local field="$2"
    [[ -f "$file" ]] || { echo ""; return 0; }
    [[ -n "$field" ]] || { echo ""; return 0; }

    local in_fm=false value=""
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$in_fm" == "false" ]]; then
            [[ "$line" == "---" ]] || { echo ""; return 0; }
            in_fm=true
            continue
        fi
        if [[ "$line" == "---" ]]; then
            echo "$value"
            return 0
        fi
        if [[ "$line" =~ ^${field}:[[:space:]]*(.*)$ ]]; then
            value="${BASH_REMATCH[1]}"
            value="${value#\"}" ; value="${value%\"}"
            value="${value#\'}" ; value="${value%\'}"
            # Strip trailing whitespace / comments.
            value="${value%%#*}"
            value="${value%"${value##*[![:space:]]}"}"
            # Keep scanning — first occurrence wins, which is what frontmatter
            # spec implies; the early echo on closing `---` covers the case
            # where the field is the last entry.
        fi
    done < "$file"
    echo "$value"
}

# Escape a string for safe inclusion as a JSON string value.
# Handles: backslash, double-quote, newline, carriage return, tab.
# Usage: _json_escape "input"  → echoes escaped string
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Convert a markdown command file to Gemini TOML format.
# Translates !`cmd` → !{cmd} and $ARGUMENTS → {{args}}.
# Usage: convert_md_command_to_toml "src_file" "dest_file" "dry_run"
convert_md_command_to_toml() {
    local src_file="$1"
    local dest_file="$2"
    local dry_run="${3:-false}"

    if [[ "$dry_run" == "true" ]]; then
        log_step "$(display_path "$src_file") → $(display_path "$dest_file") (md→toml) (dry-run)"
        return 0
    fi

    ensure_dir "${dest_file%/*}"
    _parse_md_frontmatter "$src_file"

    local description="$_FM_DESCRIPTION"
    local body="$_FM_BODY"

    body=$(echo "$body" | sed 's/!`\([^`]*\)`/!{\1}/g')
    body=$(echo "$body" | sed 's/\$ARGUMENTS/{{args}}/g')

    {
        if [[ -n "$description" ]]; then
            echo "description = \"$description\""
        fi
        echo "prompt = \"\"\""
        printf '%s' "$body"
        echo "\"\"\""
    } > "$dest_file"

    if declare -f manifest_record_write >/dev/null 2>&1; then
        manifest_record_write "$dest_file"
    fi
}

# Sync a directory of markdown command files, converting each to TOML.
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
        local basename="${src_file##*/}"; basename="${basename%.md}"
        local dest_file="$dest_dir/$basename.toml"
        convert_md_command_to_toml "$src_file" "$dest_file" "$dry_run"
        count=$((count + 1))
    done

    if [[ $count -gt 0 ]]; then
        log_step "$(display_path "$src_dir")/ → $(display_path "$dest_dir")/ ($count commands, md→toml)"
    fi
}

# Convert a markdown agent file to Codex TOML format.
# Usage: convert_md_agent_to_toml "src_file" "dest_file" "dry_run"
convert_md_agent_to_toml() {
    local src_file="$1"
    local dest_file="$2"
    local dry_run="${3:-false}"

    if [[ "$dry_run" == "true" ]]; then
        log_step "$(display_path "$src_file") → $(display_path "$dest_file") (agent md→toml) (dry-run)"
        return 0
    fi

    ensure_dir "${dest_file%/*}"
    _parse_md_frontmatter "$src_file"

    local name_stem="${src_file##*/}"; name_stem="${name_stem%.md}"
    local name="${_FM_NAME:-$name_stem}"
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

    if declare -f manifest_record_write >/dev/null 2>&1; then
        manifest_record_write "$dest_file"
    fi
}

# Sync a directory of markdown agent files, converting each to TOML.
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
        local basename="${src_file##*/}"; basename="${basename%.md}"
        local dest_file="$dest_dir/$basename.toml"
        convert_md_agent_to_toml "$src_file" "$dest_file" "$dry_run"
        count=$((count + 1))
    done

    if [[ $count -gt 0 ]]; then
        log_step "$(display_path "$src_dir")/ → $(display_path "$dest_dir")/ ($count agents, md→toml)"
    fi
}

# Convert a markdown agent file to Amazon Q CLI custom-agent JSON format.
# Schema: https://docs.aws.amazon.com/amazonq/latest/qdeveloper-ug/command-line-custom-agents-configuration.html
# Usage: convert_md_agent_to_amazonq_json "src_file" "dest_file" "dry_run"
convert_md_agent_to_amazonq_json() {
    local src_file="$1"
    local dest_file="$2"
    local dry_run="${3:-false}"

    if [[ "$dry_run" == "true" ]]; then
        log_step "$(display_path "$src_file") → $(display_path "$dest_file") (agent md→json) (dry-run)"
        return 0
    fi

    ensure_dir "${dest_file%/*}"
    _parse_md_frontmatter "$src_file"

    local name_stem="${src_file##*/}"; name_stem="${name_stem%.md}"
    local name="${_FM_NAME:-$name_stem}"
    local description="$_FM_DESCRIPTION"
    local model="$_FM_MODEL"
    local body="${_FM_BODY%$'\n'}"  # trim single trailing newline added by parser

    local tools_json="[]"
    if [[ -n "$_FM_TOOLS" ]]; then
        local items=""
        local tool
        while IFS= read -r tool; do
            [[ -z "$tool" ]] && continue
            if [[ -z "$items" ]]; then
                items="\"$(_json_escape "$tool")\""
            else
                items="${items}, \"$(_json_escape "$tool")\""
            fi
        done <<< "$_FM_TOOLS"
        tools_json="[$items]"
    fi

    {
        printf '{\n'
        printf '  "name": "%s",\n' "$(_json_escape "$name")"
        if [[ -n "$description" ]]; then
            printf '  "description": "%s",\n' "$(_json_escape "$description")"
        fi
        if [[ -n "$model" ]]; then
            printf '  "model": "%s",\n' "$(_json_escape "$model")"
        fi
        printf '  "tools": %s,\n' "$tools_json"
        printf '  "mcpServers": {},\n'
        printf '  "prompt": "%s"\n' "$(_json_escape "$body")"
        printf '}\n'
    } > "$dest_file"

    if declare -f manifest_record_write >/dev/null 2>&1; then
        manifest_record_write "$dest_file"
    fi
}

# Sync a directory of markdown agent files, converting each to Amazon Q JSON.
# Usage: sync_agents_as_amazonq_json "src_dir" "dest_dir" "dry_run"
sync_agents_as_amazonq_json() {
    local src_dir="$1"
    local dest_dir="$2"
    local dry_run="${3:-false}"

    if [[ ! -d "$src_dir" ]]; then
        return 0
    fi

    local count=0
    for src_file in "$src_dir"/*.md; do
        [[ -f "$src_file" ]] || continue
        local basename="${src_file##*/}"; basename="${basename%.md}"
        local dest_file="$dest_dir/$basename.json"
        convert_md_agent_to_amazonq_json "$src_file" "$dest_file" "$dry_run"
        count=$((count + 1))
    done

    if [[ $count -gt 0 ]]; then
        log_step "$(display_path "$src_dir")/ → $(display_path "$dest_dir")/ ($count agents, md→amazonq json)"
    fi
}
