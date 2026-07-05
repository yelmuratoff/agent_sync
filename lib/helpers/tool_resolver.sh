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

# Canonical ordered list of per-tool target resource types. Every consumer that
# iterates a tool's targets.* keys reads this — extend it here, not at each loop.
# Consumed across files (sync.sh, profile.sh); shellcheck lints each in isolation.
# Guarded so a re-source under `set -e` never aborts on the readonly reassignment.
if [[ -z "${AGENTSYNC_TARGET_KEYS+x}" ]]; then
    # shellcheck disable=SC2034
    AGENTSYNC_TARGET_KEYS=(agents rules skills commands subagents settings mcp hooks)
    readonly AGENTSYNC_TARGET_KEYS
fi

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

# Base tool name declared by a variant via `base:` in its user file.
# Variant tools (profiles) have no base catalog file of their own; they inherit
# unset fields and base payload templates from the named base tool.
# Prints the base name, or empty when the tool declares no `base:`.
tool_base_name() {
    local tool_name="$1"
    local user_file
    user_file=$(tool_resolver_user_file "$tool_name")
    [[ -f "$user_file" ]] || { echo ""; return 0; }
    parse_yaml_value "$user_file" "base"
}

# ── Layered value lookup ──────────────────────────────────────────────────────

# REPLY-returning core of get_tool_value: user override wins, base fallback, then
# the `base:` variant tool. Sets REPLY instead of echoing, so parent-shell
# callers avoid a command-substitution fork per lookup. Always exit 0.
# Usage: get_tool_value_r <tool_name> <yaml.key.path>  →  reads $REPLY
get_tool_value_r() {
    local tool_name="$1"
    local key_path="$2"

    REPLY=""
    local user_file="$REPO_ROOT/.ai/src/tools/${tool_name}.yaml"
    if [[ -f "$user_file" ]]; then
        parse_yaml_value_r "$user_file" "$key_path"
        [[ -n "$REPLY" ]] && return 0
    fi

    local base_file="$DEFAULT_REPO_ROOT/lib/templates/tools/${tool_name}.yaml"
    if [[ -f "$base_file" ]]; then
        parse_yaml_value_r "$base_file" "$key_path"
        return 0
    fi

    # Variant tool (profile): no base catalog file of its own — fall back to the
    # base tool declared via `base:`. Skip `base`/`name` so a variant's own
    # identity never resolves to the base tool's.
    if [[ "$key_path" != "base" ]] && [[ "$key_path" != "name" ]]; then
        local base_tool base_tool_file
        base_tool=$(tool_base_name "$tool_name")
        if [[ -n "$base_tool" ]]; then
            base_tool_file=$(tool_resolver_base_file "$base_tool")
            if [[ -f "$base_tool_file" ]]; then
                parse_yaml_value_r "$base_tool_file" "$key_path"
                return 0
            fi
        fi
    fi

    REPLY=""
    return 0
}

# Get an effective YAML value for a tool: user override wins, base fallback.
# Echo wrapper kept for the many `$(...)` call sites; hot parent-shell paths
# should call get_tool_value_r and read $REPLY to avoid the fork.
# Usage: get_tool_value <tool_name> <yaml.key.path>
get_tool_value() {
    get_tool_value_r "$1" "$2"
    echo "$REPLY"
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

# Read a filter field (include/exclude) from one file as a space-joined string,
# accepting a scalar ("a b c"), an inline list ([a, b]), or a block list
# (`- a` per line). Echoes empty when the key is absent.
_read_filter_file() {
    local file="$1"
    local key="$2"

    local scalar
    scalar=$(parse_yaml_value "$file" "$key")
    if [[ -n "$scalar" ]] && [[ "$scalar" != \[*\] ]]; then
        echo "$scalar"
        return 0
    fi

    local -a items=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && items+=("$line")
    done < <(parse_yaml_list "$file" "$key")
    if [[ ${#items[@]} -gt 0 ]]; then
        echo "${items[*]}"
    fi
}

# Layered read of an include/exclude filter (user override → base → base: tool),
# returning a space-joined glob string regardless of YAML form (scalar/list).
# Use this instead of get_tool_value for targets.*.include / targets.*.exclude
# so configs can list one glob per line.
# Usage: get_tool_filter <tool_name> <targets.X.include|exclude>
get_tool_filter() {
    local tool_name="$1"
    local key_path="$2"

    local user_file
    user_file=$(tool_resolver_user_file "$tool_name")
    if [[ -f "$user_file" ]]; then
        local v
        v=$(_read_filter_file "$user_file" "$key_path")
        if [[ -n "$v" ]]; then
            echo "$v"
            return 0
        fi
    fi

    local base_file
    base_file=$(tool_resolver_base_file "$tool_name")
    if [[ -f "$base_file" ]]; then
        _read_filter_file "$base_file" "$key_path"
        return 0
    fi

    local base_tool base_tool_file
    base_tool=$(tool_base_name "$tool_name")
    if [[ -n "$base_tool" ]]; then
        base_tool_file=$(tool_resolver_base_file "$base_tool")
        if [[ -f "$base_tool_file" ]]; then
            _read_filter_file "$base_tool_file" "$key_path"
            return 0
        fi
    fi

    echo ""
}

# ── Payload resolution (settings / mcp / hooks) ───────────────────────────────
#
# Each tool can ship a per-resource payload file (e.g. Cursor's hooks.json).
# Lookup order:
#   1. Per-tool override:  <repo>/.ai/src/tools/<tool>/<resource>.<ext>   (0.11+)
#   2. Declared override:  whatever targets.<resource>.source points to   (user-set)
#   3. Legacy flat:        <repo>/.ai/src/<resource>/<tool>.<ext>         (pre-0.11, deprecated)
#   4. Shared MCP only:    <repo>/.ai/src/mcp.json                        (0.11+, mcp resource only)
#   5. Base template:      <install-dir>/lib/templates/<resource>/<tool>.<ext>
#
# The extension in (1) and (3) is discovered by probing the directory — so
# custom tools that ship their own file without a base still resolve.
#
# Usage: resolve_payload_source <tool> <resource>   resource ∈ {settings,mcp,hooks}
# Prints absolute path to the source file, or empty if nothing exists. Exit 0.

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

    # Variant tool: fall back to the base tool's payload template.
    local base_tool
    base_tool=$(tool_base_name "$tool_name")
    [[ -z "$base_tool" ]] && return 0
    for candidate in "$base_dir/${base_tool}".*; do
        [[ -f "$candidate" ]] || continue
        echo "$candidate"
        return 0
    done
}

# Per-tool override directory: .ai/src/tools/<tool>/ (0.11+ canonical layout).
_payload_override_dir() {
    local tool_name="$1"
    echo "$REPO_ROOT/.ai/src/tools/${tool_name}"
}

# Canonical write-path for a payload override (0.11+ layout).
# Extension derived from base; empty if no base (custom tool).
_payload_override_path() {
    local tool_name="$1"
    local resource="$2"
    local base_file ext
    base_file=$(_find_base_payload "$resource" "$tool_name")
    [[ -z "$base_file" ]] && return 0
    ext="${base_file##*.}"
    echo "$(_payload_override_dir "$tool_name")/${resource}.${ext}"
}

# Probe the per-tool dir for any existing <resource>.* file. Read-side helper.
_find_new_payload_override() {
    local tool_name="$1"
    local resource="$2"
    local dir
    dir=$(_payload_override_dir "$tool_name")
    [[ -d "$dir" ]] || return 0
    local candidate
    for candidate in "$dir/${resource}".*; do
        [[ -f "$candidate" ]] || continue
        echo "$candidate"
        return 0
    done
}

# Legacy flat-layout override path (pre-0.11). Extension derived from base.
_payload_override_legacy_path() {
    local tool_name="$1"
    local resource="$2"
    local base_file ext
    base_file=$(_find_base_payload "$resource" "$tool_name")
    [[ -z "$base_file" ]] && return 0
    ext="${base_file##*.}"
    echo "$REPO_ROOT/.ai/src/${resource}/${tool_name}.${ext}"
}

# Find any existing override (new or legacy). Prints path, exit 0 if found.
_find_any_payload_override() {
    local tool_name="$1"
    local resource="$2"
    local p
    p=$(_find_new_payload_override "$tool_name" "$resource")
    if [[ -n "$p" ]]; then
        echo "$p"
        return 0
    fi
    p=$(_payload_override_legacy_path "$tool_name" "$resource")
    if [[ -n "$p" ]] && [[ -f "$p" ]]; then
        echo "$p"
        return 0
    fi
    return 1
}

# Warn (once per CLI invocation) about legacy flat-layout overrides.
# Uses a PID-scoped marker because resolve_payload_source is called from
# command substitution subshells, so global variables won't persist.
_warn_legacy_payload_path() {
    local rel="${1#"$REPO_ROOT/"}"
    local marker="${TMPDIR:-/tmp}/agentsync_legacy_warn_$$"
    [[ -f "$marker" ]] && return 0
    : > "$marker" 2>/dev/null || true
    {
        echo "⚠  Legacy payload override layout detected: $rel"
        echo "   Move to .ai/src/tools/<tool>/<resource>.<ext> (canonical since 0.11)."
        echo "   Legacy paths will be dropped in 0.12."
    } >&2
}

# Shared MCP path: .ai/src/mcp.json — one source of truth for every tool.
# Only MCP supports this; hooks/settings remain per-tool by nature.
shared_mcp_path() {
    echo "$REPO_ROOT/.ai/src/mcp.json"
}

_find_shared_mcp() {
    local p
    p=$(shared_mcp_path)
    [[ -f "$p" ]] && echo "$p"
}

resolve_payload_source() {
    local tool_name="$1"
    local resource="$2"

    # 1. New per-tool dir (canonical for 0.11+).
    local new_override
    new_override=$(_find_new_payload_override "$tool_name" "$resource")
    if [[ -n "$new_override" ]]; then
        echo "$new_override"
        return 0
    fi

    # 2. Explicit path from tool YAML targets.<resource>.source (user-set).
    local declared
    get_tool_value_r "$tool_name" "targets.${resource}.source"; declared="$REPLY"
    if [[ -n "$declared" ]]; then
        local declared_abs="$declared"
        [[ "$declared_abs" != /* ]] && declared_abs="$REPO_ROOT/$declared"
        if [[ -f "$declared_abs" ]]; then
            case "$declared" in
                .ai/src/hooks/*|.ai/src/mcp/*|.ai/src/settings/*)
                    _warn_legacy_payload_path "$declared_abs"
                    ;;
            esac
            echo "$declared_abs"
            return 0
        fi
    fi

    # 3. Legacy flat layout (pre-0.11, deprecated — warn once).
    local legacy
    legacy=$(_payload_override_legacy_path "$tool_name" "$resource")
    if [[ -n "$legacy" ]] && [[ -f "$legacy" ]]; then
        _warn_legacy_payload_path "$legacy"
        echo "$legacy"
        return 0
    fi

    # 4. Shared MCP: applies to every tool, scoped to resource == mcp.
    if [[ "$resource" == "mcp" ]]; then
        local shared
        shared=$(_find_shared_mcp)
        if [[ -n "$shared" ]]; then
            echo "$shared"
            return 0
        fi
    fi

    # 5. Base fallback.
    local base_file
    base_file=$(_find_base_payload "$resource" "$tool_name")
    if [[ -n "$base_file" ]]; then
        echo "$base_file"
        return 0
    fi

    return 0
}

# Classify a resolved payload source path. Returns one of:
#   override   — new per-tool dir (.ai/src/tools/<tool>/<resource>.*)
#   declared   — explicit targets.<resource>.source override (non-legacy path)
#   legacy     — legacy flat (.ai/src/<resource>/<tool>.*)
#   shared     — shared MCP (.ai/src/mcp.json)
#   base       — shipped base template
#   unknown    — none of the above (custom declared path outside .ai/src)
describe_payload_source() {
    local path="$1"
    local tool_name="$2"
    local resource="$3"

    [[ -z "$path" ]] && { echo ""; return 0; }

    local new_dir
    new_dir=$(_payload_override_dir "$tool_name")
    if [[ -n "$new_dir" ]] && [[ "$path" == "$new_dir/"* ]]; then
        echo "override"
        return 0
    fi

    if [[ "$resource" == "mcp" ]] && [[ "$path" == "$(shared_mcp_path)" ]]; then
        echo "shared"
        return 0
    fi

    local legacy_prefix="$REPO_ROOT/.ai/src/${resource}/"
    if [[ "$path" == "$legacy_prefix"* ]]; then
        echo "legacy"
        return 0
    fi

    local base_prefix
    base_prefix=$(_payload_base_dir "$resource")
    if [[ -n "$base_prefix" ]] && [[ "$path" == "$base_prefix/"* ]]; then
        echo "base"
        return 0
    fi

    echo "declared"
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

# Per-process memo of the enabled-tools set. tools.enabled is fixed for a run,
# so computing it once and answering membership from a string avoids re-reading
# config + every override file (and two sort forks) for each tool checked.
_ENABLED_TOOLS_CACHED="false"
_ENABLED_TOOLS_SET="|"

# Populate the enabled-tools membership cache. MUST run in the parent shell (not
# a $(...) subshell), or the globals it sets won't survive for later lookups.
warm_enabled_tools_cache() {
    _ENABLED_TOOLS_SET="|"
    local t
    while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        _ENABLED_TOOLS_SET="${_ENABLED_TOOLS_SET}${t}|"
    done < <(list_enabled_tools)
    _ENABLED_TOOLS_CACHED="true"
}

# Is <tool_name> enabled (modern or legacy)? Answers from the memo when warmed;
# otherwise falls back to a fresh scan (standalone callers, tests).
is_tool_enabled() {
    local tool_name="$1"
    if [[ "$_ENABLED_TOOLS_CACHED" == "true" ]]; then
        [[ "$_ENABLED_TOOLS_SET" == *"|${tool_name}|"* ]]
        return
    fi
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
