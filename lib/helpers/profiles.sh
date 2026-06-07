#!/usr/bin/env bash
# Profiles — config-home variants of tools.
#
# A profile groups variant tools (each a thin .ai/src/tools/<name>.yaml that
# declares `base:` to inherit unset fields) and supplies a per-profile source
# overlay (.ai/profiles/<name>/src) layered over the base .ai/src/ at sync time,
# where the profile wins on path conflicts. Declared in agent_sync.yaml:
#
#   profiles:
#     hub:
#       overlay: ".ai/profiles/hub"
#       active: true
#       tools: [claude-hub, codex-hub]
#
# Depends on: parse_yaml_value / parse_yaml_list (yaml.sh).
# Expected globals: PROJECT_CONFIG_PATH, REPO_ROOT.

# Rewrite a base tool dest into a profile's config-home layout: strip the
# leading tool-dir segment (when present) and re-root under <home>. Root-level
# files (no '/') land directly under <home>. This keeps every resource inside
# one self-contained config-home directory.
#   .claude/rules        -> <home>/rules
#   .amazonq/rules/x.md  -> <home>/rules/x.md   (basename would lose rules/)
#   CLAUDE.md            -> <home>/CLAUDE.md
#   .mcp.json            -> <home>/.mcp.json
# Usage: profile_rewrite_dest <base_dest> <home>
profile_rewrite_dest() {
    local base_dest="$1"
    local home="$2"
    local rel="$base_dest"
    [[ "$base_dest" == */* ]] && rel="${base_dest#*/}"
    echo "$home/$rel"
}

# Immediate child keys of the top-level `profiles:` mapping, one per line.
# A focused depth-1 walk — the parser has no generic "list child keys" helper
# and profiles always live at the root.
_profiles_names() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    local in_section=false child_indent=-1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        local stripped="${line#"${line%%[![:space:]]*}"}"
        local indent=$(( ${#line} - ${#stripped} ))
        local line_key=""
        [[ "$stripped" =~ ^([a-zA-Z0-9_-]+): ]] && line_key="${BASH_REMATCH[1]}"

        if [[ "$in_section" == false ]]; then
            [[ $indent -eq 0 ]] && [[ "$line_key" == "profiles" ]] && in_section=true
            continue
        fi

        # A key back at column 0 ends the profiles block.
        [[ $indent -eq 0 ]] && break
        [[ -z "$line_key" ]] && continue
        [[ $child_indent -lt 0 ]] && child_indent=$indent
        [[ $indent -eq $child_indent ]] && echo "$line_key"
    done < "$file"
}

# List declared profile names (one per line). Empty when none.
list_profiles() {
    [[ -n "${PROJECT_CONFIG_PATH:-}" ]] || return 0
    _profiles_names "$PROJECT_CONFIG_PATH"
}

# Overlay source root for a profile (relative path as written in config).
# Falls back to the conventional .ai/profiles/<name> when unset.
profile_overlay_dir() {
    local name="$1"
    [[ -n "${PROJECT_CONFIG_PATH:-}" ]] || { echo ".ai/profiles/$name"; return 0; }
    local v
    v=$(parse_yaml_value "$PROJECT_CONFIG_PATH" "profiles.$name.overlay")
    [[ -n "$v" ]] && echo "$v" || echo ".ai/profiles/$name"
}

# Variant tool names belonging to a profile (one per line).
profile_tools() {
    local name="$1"
    [[ -n "${PROJECT_CONFIG_PATH:-}" ]] || return 0
    parse_yaml_list "$PROJECT_CONFIG_PATH" "profiles.$name.tools"
}

# Is a profile marked active (synced on a plain `agentsync sync`)?
profile_is_active() {
    local name="$1"
    [[ -n "${PROJECT_CONFIG_PATH:-}" ]] || return 1
    local v
    v=$(parse_yaml_value "$PROJECT_CONFIG_PATH" "profiles.$name.active")
    shopt -s nocasematch
    local rc=1
    case "$v" in true|yes|1|on) rc=0 ;; esac
    shopt -u nocasematch
    return $rc
}

# Union of every profile's variant tools (sorted, deduped).
list_profile_tools() {
    local p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        profile_tools "$p"
    done < <(list_profiles) | sort -u
}

# Is <tool> a variant tool owned by some profile?
is_profile_tool() {
    local want="$1" t
    while IFS= read -r t; do
        [[ "$t" == "$want" ]] && return 0
    done < <(list_profile_tools)
    return 1
}
