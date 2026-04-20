#!/usr/bin/env bash
# Simple YAML parser for AI Sync Script
# Cross-platform compatible (Unix/macOS/Git Bash)
# Only handles simple key: value pairs and nested keys with dot notation

# Parse a scalar value from YAML file
# Usage: parse_yaml_value "file.yaml" "key" OR "key.subkey" OR "key.subkey.subsubkey"
# Returns: the value as string, or empty if not found
# Always returns exit code 0 (safe for use with set -e)
# Normalize a YAML scalar into $REPLY. Pure-bash, no forks.
# Prefer this in hot loops. _yaml_normalize_scalar wraps it for the
# echo-returning API kept for backwards compatibility with `$(...)` callers.
_yaml_normalize_scalar_reply() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    if [[ "$value" =~ ^\"(.*)\"[[:space:]]*(#.*)?$ ]]; then
        REPLY="${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$value" =~ ^\'(.*)\'[[:space:]]*(#.*)?$ ]]; then
        REPLY="${BASH_REMATCH[1]}"
        return 0
    fi

    value="${value%%#*}"
    value="${value%"${value##*[![:space:]]}"}"
    REPLY="$value"
}

_yaml_normalize_scalar() {
    _yaml_normalize_scalar_reply "$1"
    echo "$REPLY"
}

parse_yaml_value() {
    local file="$1"
    local key_path="$2"
    
    if [[ ! -f "$file" ]]; then
        echo ""
        return 0
    fi
    
    # Split key path into parts
    IFS='.' read -ra keys <<< "$key_path"
    local depth=${#keys[@]}
    
    # For nested keys, we need to track indentation
    local in_section=false
    local section_indent=0
    local looking_for="${keys[0]}"
    local next_key_index=1
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Count leading spaces
        local stripped="${line#"${line%%[![:space:]]*}"}"
        local indent=$(( ${#line} - ${#stripped} ))
        
        # Extract key and value
        local line_key line_value
        if [[ "$stripped" =~ ^([a-zA-Z0-9_-]+):[[:space:]]*(.*) ]]; then
            line_key="${BASH_REMATCH[1]}"
            _yaml_normalize_scalar_reply "${BASH_REMATCH[2]}"
            line_value="$REPLY"
        elif [[ "$stripped" =~ ^([a-zA-Z0-9_-]+):$ ]]; then
            line_key="${BASH_REMATCH[1]}"
            line_value=""
        else
            continue
        fi

        if [[ "$in_section" == false ]]; then
            # Looking for first key at root level
            if [[ $indent -eq 0 ]] && [[ "$line_key" == "$looking_for" ]]; then
                if [[ $next_key_index -eq $depth ]]; then
                    # This is the final key
                    echo "$line_value"
                    return 0
                fi
                in_section=true
                section_indent=$indent
                looking_for="${keys[$next_key_index]}"
                ((next_key_index++))
            fi
        else
            # We're inside a section, looking for nested key
            if [[ $indent -le $section_indent ]]; then
                # Exited the section without finding key - return empty
                echo ""
                return 0
            fi
            
            if [[ "$line_key" == "$looking_for" ]]; then
                if [[ $next_key_index -eq $depth ]]; then
                    # Found the final key
                    echo "$line_value"
                    return 0
                fi
                section_indent=$indent
                looking_for="${keys[$next_key_index]}"
                ((next_key_index++))
            fi
        fi
    done < "$file"
    
    # Key not found - return empty (not error)
    echo ""
    return 0
}

# Parse a YAML list under a key path.
# Usage: parse_yaml_list "file.yaml" "tools.enabled"
# Prints each list item on its own line.
# Supports both inline `key: [a, b, c]` and block style:
#   key:
#     - a
#     - b
parse_yaml_list() {
    local file="$1"
    local key_path="$2"

    if [[ ! -f "$file" ]]; then
        return 0
    fi

    # Try inline style first
    local inline_value
    inline_value=$(parse_yaml_value "$file" "$key_path")
    if [[ "$inline_value" =~ ^\[(.*)\]$ ]]; then
        local items="${BASH_REMATCH[1]}"
        local IFS=','
        local item
        for item in $items; do
            _yaml_normalize_scalar_reply "$item"
            [[ -n "$REPLY" ]] && echo "$REPLY"
        done
        return 0
    fi

    # Block style: walk the file and locate the key, then read dash-items under it.
    local -a keys
    IFS='.' read -ra keys <<< "$key_path"
    local depth=${#keys[@]}
    local in_section=false
    local section_indent=0
    local looking_for="${keys[0]}"
    local next_key_index=1
    local collecting=false
    local collect_min_indent=-1

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Always skip blanks/comments
        if [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi

        local stripped="${line#"${line%%[![:space:]]*}"}"
        local indent=$(( ${#line} - ${#stripped} ))

        if [[ "$collecting" == "true" ]]; then
            # First dash-line defines the list's expected indent.
            if [[ "$stripped" =~ ^-[[:space:]]*(.*)$ ]]; then
                if [[ $collect_min_indent -lt 0 ]]; then
                    collect_min_indent=$indent
                fi
                if [[ $indent -eq $collect_min_indent ]]; then
                    _yaml_normalize_scalar_reply "${BASH_REMATCH[1]}"
                    [[ -n "$REPLY" ]] && echo "$REPLY"
                    continue
                fi
            fi
            # Anything else at same-or-less indent ends the list.
            if [[ $collect_min_indent -ge 0 ]] && [[ $indent -lt $collect_min_indent ]]; then
                return 0
            fi
            # Nested content we don't care about
            continue
        fi

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
                    collecting=true
                    continue
                fi
                in_section=true
                section_indent=$indent
                looking_for="${keys[$next_key_index]}"
                ((next_key_index++))
            fi
        else
            if [[ $indent -le $section_indent ]]; then
                return 0
            fi
            if [[ "$line_key" == "$looking_for" ]]; then
                if [[ $next_key_index -eq $depth ]]; then
                    collecting=true
                    continue
                fi
                section_indent=$indent
                looking_for="${keys[$next_key_index]}"
                ((next_key_index++))
            fi
        fi
    done < "$file"
}

# Parse boolean value from YAML file
# Usage: parse_yaml_bool "file.yaml" "key.subkey"
# Returns: 0 if true, 1 if false or not found
parse_yaml_bool() {
    local file="$1"
    local key_path="$2"

    local value
    value=$(parse_yaml_value "$file" "$key_path")

    shopt -s nocasematch
    local rc=1
    case "$value" in
        true|yes|1|on) rc=0 ;;
    esac
    shopt -u nocasematch
    return $rc
}

# Parse strict boolean value from YAML file
# Usage: parse_yaml_bool_strict "file.yaml" "key.subkey"
# Prints: "true" or "false" on success
# Returns:
#   0 - parsed successfully
#   2 - key missing or empty
#   3 - value is not a valid boolean scalar
parse_yaml_bool_strict() {
    local file="$1"
    local key_path="$2"

    local value
    value=$(parse_yaml_value "$file" "$key_path")

    # Empty values are treated as missing for strict mode.
    if [[ -z "$value" ]]; then
        return 2
    fi

    shopt -s nocasematch
    local rc=3
    case "$value" in
        true|yes|1|on)  echo "true";  rc=0 ;;
        false|no|0|off) echo "false"; rc=0 ;;
    esac
    shopt -u nocasematch
    return $rc
}
