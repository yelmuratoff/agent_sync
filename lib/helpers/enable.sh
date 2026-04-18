#!/usr/bin/env bash
# agentsync enable / disable — manage tools.enabled list in agent_sync.yaml.

# Resolve the path of the project config, creating one if missing.
# Returns path on stdout.
_enable_resolve_or_create_config() {
    local project_dir="$1"
    local cfg="$project_dir/.ai/agent_sync.yaml"

    if [[ -f "$cfg" ]]; then
        echo "$cfg"
        return 0
    fi

    local legacy="$project_dir/agent_sync.yaml"
    if [[ -f "$legacy" ]]; then
        echo "$legacy"
        return 0
    fi

    mkdir -p "$project_dir/.ai"
    {
        echo "# AgentSync — Project Configuration"
        echo "tools:"
        echo "  enabled: []"
    } > "$cfg"
    echo "$cfg"
}

# Discover project + install-dir layout so tool_resolver works from CLI context.
_enable_prepare_context() {
    local project_dir
    project_dir="${AGENTSYNC_REPO_ROOT:-$(pwd)}"
    project_dir="$(cd "$project_dir" && pwd)"
    REPO_ROOT="$project_dir"
    REPO_ROOT_CANONICAL="$(cd -P "$project_dir" && pwd)"

    local system_dir
    system_dir=$(resolve_system_dir 2>/dev/null) || {
        echo "$(_red "Error"): AgentSync engine not found." >&2
        exit 1
    }
    DEFAULT_REPO_ROOT="$(cd "$system_dir/.." && pwd)"

    PROJECT_CONFIG_PATH=""
    if [[ -f "$project_dir/.ai/agent_sync.yaml" ]]; then
        PROJECT_CONFIG_PATH="$project_dir/.ai/agent_sync.yaml"
    elif [[ -f "$project_dir/agent_sync.yaml" ]]; then
        PROJECT_CONFIG_PATH="$project_dir/agent_sync.yaml"
    fi

    export REPO_ROOT REPO_ROOT_CANONICAL DEFAULT_REPO_ROOT PROJECT_CONFIG_PATH
}

# Print one-line summary for a list of tools (expects caller context loaded).
_enable_print_tool_line() {
    local tool="$1"
    local display
    display=$(tool_display_name "$tool")
    echo "    $(_green "●") $display $(_dim "($tool)")"
}

# ── enable ────────────────────────────────────────────────────────────────────

cmd_enable() {
    if [[ $# -eq 0 ]]; then
        echo "$(_red "Error"): agentsync enable <tool> [<tool>...]" >&2
        echo "" >&2
        echo "Run $(_cyan "agentsync list") to see available tools." >&2
        exit 1
    fi

    _enable_prepare_context

    local cfg
    cfg=$(_enable_resolve_or_create_config "$REPO_ROOT")

    local added=0 already=0 unknown=()
    local tool
    for tool in "$@"; do
        if ! tool_exists "$tool"; then
            unknown+=("$tool")
            continue
        fi
        if is_tool_enabled "$tool"; then
            already=$((already + 1))
            continue
        fi
        yaml_list_append "$cfg" "tools.enabled" "$tool"
        added=$((added + 1))
    done

    echo ""
    if [[ $added -gt 0 ]]; then
        _green "Enabled $added tool(s)"; echo ""
        for tool in "$@"; do
            local u
            local skip=false
            for u in "${unknown[@]+"${unknown[@]}"}"; do
                [[ "$u" == "$tool" ]] && skip=true && break
            done
            [[ "$skip" == "true" ]] && continue
            _enable_print_tool_line "$tool"
        done
    fi

    if [[ $already -gt 0 ]]; then
        echo ""
        _dim "$already tool(s) were already enabled"; echo ""
    fi

    if [[ ${#unknown[@]} -gt 0 ]]; then
        echo ""
        _yellow "Unknown tool(s):"; echo ""
        for tool in "${unknown[@]+"${unknown[@]}"}"; do
            echo "    $tool"
        done
        echo ""
        echo "Run $(_cyan "agentsync list") to see available tools."
    fi

    if [[ $added -gt 0 ]]; then
        echo ""
        echo "Run $(_cyan "agentsync sync") to apply."
        echo ""
    fi
}

# ── disable ───────────────────────────────────────────────────────────────────

cmd_disable() {
    if [[ $# -eq 0 ]]; then
        echo "$(_red "Error"): agentsync disable <tool> [<tool>...]" >&2
        exit 1
    fi

    _enable_prepare_context

    local cfg
    cfg=$(_enable_resolve_or_create_config "$REPO_ROOT")

    local removed=0 not_enabled=0
    local tool
    for tool in "$@"; do
        if is_tool_enabled "$tool"; then
            yaml_list_remove "$cfg" "tools.enabled" "$tool"
            # Also flip legacy override `enabled: true` if present.
            local user_file
            user_file=$(tool_resolver_user_file "$tool")
            if [[ -f "$user_file" ]]; then
                local legacy_flag
                legacy_flag=$(parse_yaml_value "$user_file" "enabled")
                if [[ "$legacy_flag" == "true" ]]; then
                    yaml_set_scalar "$user_file" "enabled" "false"
                fi
            fi
            removed=$((removed + 1))
        else
            not_enabled=$((not_enabled + 1))
        fi
    done

    echo ""
    if [[ $removed -gt 0 ]]; then
        _yellow "Disabled $removed tool(s)"; echo ""
        for tool in "$@"; do
            if ! is_tool_enabled "$tool"; then
                local display
                display=$(tool_display_name "$tool")
                echo "    $(_dim "○") $display $(_dim "($tool)")"
            fi
        done
        echo ""
        echo "Run $(_cyan "agentsync sync") to apply cleanup."
    fi
    if [[ $not_enabled -gt 0 ]] && [[ $removed -eq 0 ]]; then
        _dim "No matching tools were enabled."; echo ""
    fi
    echo ""
}
