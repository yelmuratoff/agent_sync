#!/usr/bin/env bash
# Tool resolver — layered config lookup for AgentSync tools.
#
# Model:
#   Base    = <install-dir>/lib/templates/tools/<name>.yaml  (shipped, versioned)
#   Override= <repo>/.ai/src/tools/<name>.yaml               (user-owned, optional, partial)
#
# A tool's effective field value is the user override if present,
# else the base value. Neither file is rewritten at sync time.
#
# Expected globals (set by sync.sh / check.sh / list.sh):
#   REPO_ROOT              — project root (user project, or install-dir for self-sync)
#   DEFAULT_REPO_ROOT      — fallback repo root (install-dir for source templates)

# ── Base/User tool directories ────────────────────────────────────────────────

# Path to base tool catalog (install-dir).
tool_resolver_base_dir() {
    echo "$DEFAULT_REPO_ROOT/lib/templates/tools"
}

# Path to user override directory in current project.
tool_resolver_user_dir() {
    echo "$REPO_ROOT/.ai/src/tools"
}

# Base YAML path for a tool (may or may not exist).
tool_resolver_base_file() {
    local tool_name="$1"
    echo "$(tool_resolver_base_dir)/${tool_name}.yaml"
}

# User override YAML path for a tool (may or may not exist).
tool_resolver_user_file() {
    local tool_name="$1"
    echo "$(tool_resolver_user_dir)/${tool_name}.yaml"
}

# ── Layered value lookup ──────────────────────────────────────────────────────

# Get an effective YAML value for a tool: user override wins, base fallback.
# Usage: get_tool_value <tool_name> <yaml.key.path>
# Always returns exit 0; prints empty if missing in both layers.
get_tool_value() {
    local tool_name="$1"
    local key_path="$2"

    local user_file
    user_file=$(tool_resolver_user_file "$tool_name")
    if [[ -f "$user_file" ]]; then
        local v
        v=$(parse_yaml_value "$user_file" "$key_path")
        if [[ -n "$v" ]]; then
            echo "$v"
            return 0
        fi
    fi

    local base_file
    base_file=$(tool_resolver_base_file "$tool_name")
    if [[ -f "$base_file" ]]; then
        parse_yaml_value "$base_file" "$key_path"
        return 0
    fi

    echo ""
}

# Layered strict boolean parse for 'enabled' and other flags.
# Usage: get_tool_bool <tool_name> <key> -> prints "true"/"false" or empty.
get_tool_bool() {
    local tool_name="$1"
    local key_path="$2"

    local v
    v=$(get_tool_value "$tool_name" "$key_path")
    shopt -s nocasematch
    case "$v" in
        true|yes|1|on)  echo "true" ;;
        false|no|0|off) echo "false" ;;
        *)              echo "" ;;
    esac
    shopt -u nocasematch
}

# ── Payload resolution (settings / mcp / hooks) ───────────────────────────────
#
# Each tool can ship a per-resource payload file (e.g. Cursor's hooks.json).
# Two locations are searched, in order:
#   1. Override: <repo>/.ai/src/<resource>/<tool>.<ext>     (project-local)
#   2. Base:     <install-dir>/lib/templates/<resource>/<tool>.<ext>  (shipped)
#
# Extension is discovered from whichever file exists. If the tool YAML sets
# targets.<resource>.source to a non-conventional path, that path is used for
# the override lookup (for backward compat), but the base fallback still works
# by tool name + resource.
#
# Usage: resolve_payload_source <tool> <resource>   resource ∈ {settings,mcp,hooks}
# Prints absolute path to the source file, or empty if neither override nor
# base exists. Always exits 0.

_payload_base_dir() {
    echo "$DEFAULT_REPO_ROOT/lib/templates/$1"
}

# Look for <install-dir>/lib/templates/<resource>/<tool>.*; print the first match.
_find_base_payload() {
    local resource="$1"
    local tool_name="$2"
    local base_dir
    base_dir=$(_payload_base_dir "$resource")
    [[ -d "$base_dir" ]] || return 0
    local candidate
    for candidate in "$base_dir/${tool_name}".*; do
        [[ -f "$candidate" ]] || continue
        echo "$candidate"
        return 0
    done
}

resolve_payload_source() {
    local tool_name="$1"
    local resource="$2"

    # Discover the base (also tells us the conventional extension).
    local base_file
    base_file=$(_find_base_payload "$resource" "$tool_name")

    # Declared override path from tool YAML (user override or base's target block).
    local declared
    declared=$(get_tool_value "$tool_name" "targets.${resource}.source")

    # If not declared, derive conventional override path from base's extension.
    if [[ -z "$declared" ]] && [[ -n "$base_file" ]]; then
        local ext="${base_file##*.}"
        declared=".ai/src/${resource}/${tool_name}.${ext}"
    fi

    # 1. Override wins if present at the declared path.
    if [[ -n "$declared" ]]; then
        local override_abs="$declared"
        [[ "$override_abs" != /* ]] && override_abs="$REPO_ROOT/$declared"
        if [[ -f "$override_abs" ]]; then
            echo "$override_abs"
            return 0
        fi
    fi

    # 2. Base fallback.
    if [[ -n "$base_file" ]]; then
        echo "$base_file"
        return 0
    fi

    # 3. Nothing found — caller will skip.
    return 0
}

# ── Catalog listings ──────────────────────────────────────────────────────────

# All base tools shipped with the install (one name per line, sorted).
list_base_tools() {
    local dir
    dir=$(tool_resolver_base_dir)
    [[ -d "$dir" ]] || return 0
    local f base
    for f in "$dir"/*.yaml; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f" .yaml)
        [[ "$base" == _* ]] && continue
        echo "$base"
    done | sort -u
}

# Tool names that have user override files (one per line, sorted).
list_user_override_tools() {
    local dir
    dir=$(tool_resolver_user_dir)
    [[ -d "$dir" ]] || return 0
    local f base
    for f in "$dir"/*.yaml; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f" .yaml)
        [[ "$base" == _* ]] && continue
        echo "$base"
    done | sort -u
}

# Union of base + user tools (used-only tools appear, unknown base tools appear).
list_all_tools() {
    {
        list_base_tools
        list_user_override_tools
    } | sort -u
}

# ── Enabled-tools resolution ──────────────────────────────────────────────────

# Read enabled tool names from project agent_sync.yaml (tools.enabled list).
# Expects caller to set PROJECT_CONFIG_PATH (may be empty if missing).
list_configured_enabled_tools() {
    local cfg="${PROJECT_CONFIG_PATH:-}"
    [[ -z "$cfg" ]] || [[ ! -f "$cfg" ]] && return 0
    parse_yaml_list "$cfg" "tools.enabled"
}

# Legacy enabled: a user override file that explicitly says `enabled: true`.
# Kept for backward compatibility with projects predating tools.enabled list.
list_legacy_enabled_tools() {
    local dir
    dir=$(tool_resolver_user_dir)
    [[ -d "$dir" ]] || return 0
    local f base flag
    for f in "$dir"/*.yaml; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f" .yaml)
        [[ "$base" == _* ]] && continue
        flag=$(parse_yaml_value "$f" "enabled")
        [[ "$flag" == "true" ]] && echo "$base"
    done
}

# Union of modern (agent_sync.yaml) + legacy (per-file) enabled tools.
list_enabled_tools() {
    {
        list_configured_enabled_tools
        list_legacy_enabled_tools
    } | sort -u
}

# Is <tool_name> enabled (modern or legacy)?
is_tool_enabled() {
    local tool_name="$1"
    local t
    while IFS= read -r t; do
        [[ "$t" == "$tool_name" ]] && return 0
    done < <(list_enabled_tools)
    return 1
}

# Does <tool_name> exist in base catalog or have a user override?
tool_exists() {
    local tool_name="$1"
    local t
    while IFS= read -r t; do
        [[ "$t" == "$tool_name" ]] && return 0
    done < <(list_all_tools)
    return 1
}

# ── Display helpers ───────────────────────────────────────────────────────────

# Display name for a tool (user override wins, falls back to base, then basename).
tool_display_name() {
    local tool_name="$1"
    local n
    n=$(get_tool_value "$tool_name" "name")
    if [[ -z "$n" ]]; then
        n="$tool_name"
    fi
    echo "$n"
}
