#!/usr/bin/env bash
# Markdown frontmatter parsing and MD→TOML format conversion.
# Depends on: logging.sh, filters.sh, file_ops.sh

# Parse YAML frontmatter from a markdown file.
# Sets globals: _FM_NAME, _FM_DESCRIPTION, _FM_BODY
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

# Convert a markdown command file to Gemini TOML format.
# Translates !`cmd` → !{cmd} and $ARGUMENTS → {{args}}.
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

# Convert a markdown agent file to Codex TOML format.
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
