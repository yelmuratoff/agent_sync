#!/usr/bin/env bash
# Simple YAML parser for AI Sync Script
# Cross-platform compatible (Unix/macOS/Git Bash)
# Only handles simple key: value pairs and nested keys with dot notation

# Parse a scalar value from YAML file
# Usage: parse_yaml_value "file.yaml" "key" OR "key.subkey" OR "key.subkey.subsubkey"
# Returns: the value as string, or empty if not found
# Always returns exit code 0 (safe for use with set -e)
_yaml_normalize_scalar() {
    local raw="$1"
    local value
    value=$(echo "$raw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

    # Keep inline # only when the scalar is quoted.
    if [[ "$value" =~ ^\"(.*)\"[[:space:]]*(#.*)?$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$value" =~ ^\'(.*)\'[[:space:]]*(#.*)?$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi

    value="${value%%#*}"
    value=$(echo "$value" | sed 's/[[:space:]]*$//')
    echo "$value"
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
            line_value="${BASH_REMATCH[2]}"
            line_value=$(_yaml_normalize_scalar "$line_value")
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

# Parse boolean value from YAML file
# Usage: parse_yaml_bool "file.yaml" "key.subkey"
# Returns: 0 if true, 1 if false or not found
parse_yaml_bool() {
    local file="$1"
    local key_path="$2"
    
    local value
    value=$(parse_yaml_value "$file" "$key_path")
    
    # Convert to lowercase using tr (POSIX compatible)
    local lower_value
    lower_value=$(echo "$value" | tr '[:upper:]' '[:lower:]')
    
    case "$lower_value" in
        true|yes|1|on)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
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

    local lower_value
    lower_value=$(echo "$value" | tr '[:upper:]' '[:lower:]')

    case "$lower_value" in
        true|yes|1|on)
            echo "true"
            return 0
            ;;
        false|no|0|off)
            echo "false"
            return 0
            ;;
        *)
            return 3
            ;;
    esac
}
