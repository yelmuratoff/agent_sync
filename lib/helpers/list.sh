#!/usr/bin/env bash
# agentsync list — show available tools from base catalog and per-project state.

_list_prepare_context() {
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

# Build a short resources string for a tool. Each resource (hooks, mcp,
# settings) is shown as:
#   H  — base available, no override
#   H* — override present (new per-tool layout)
#   H~ — override present in legacy flat layout (migration pending)
# Missing resources are shown as ·
_list_resources_column() {
    local tool="$1"
    local resource letter base new_override legacy out=""
    for resource in hooks mcp settings; do
        case "$resource" in
            hooks)    letter="H" ;;
            mcp)      letter="M" ;;
            settings) letter="S" ;;
        esac
        base=$(_find_base_payload "$resource" "$tool")
        new_override=$(_find_new_payload_override "$tool" "$resource")
        legacy=$(_payload_override_legacy_path "$tool" "$resource")
        if [[ -n "$new_override" ]]; then
            out+="$(_yellow "${letter}*")"
        elif [[ -n "$legacy" ]] && [[ -f "$legacy" ]]; then
            out+="$(_yellow "${letter}~")"
        elif [[ -n "$base" ]]; then
            out+="$(_dim "${letter} ")"
        else
            out+="$(_dim "· ")"
        fi
        out+=" "
    done
    printf '%s' "$out"
}

cmd_list() {
    _list_prepare_context

    echo ""
    _bold "  AgentSync Tools"; echo ""
    _dim "  ● enabled   ○ available   ★ tool override   H M S = hooks/mcp/settings (· = base only, * = override, ~ = legacy override)"; echo ""
    _dim "  Columns: name · slug (use in commands) · status · resources"; echo ""
    echo ""

    # Collect sets as newline-separated strings for fast membership checks.
    local enabled_tools customized_tools
    enabled_tools=$(list_enabled_tools)
    customized_tools=$(list_user_override_tools)

    local all
    all=$(list_all_tools)

    if [[ -z "$all" ]]; then
        echo "  $(_yellow "No tools found in base catalog.")"
        echo "  Expected at $(_dim "$(tool_resolver_base_dir)")"
        echo ""
        return 0
    fi

    local enabled_count=0 available_count=0 customized_count=0
    local payload_override_count=0
    local tool
    while IFS= read -r tool; do
        [[ -z "$tool" ]] && continue
        local display
        display=$(tool_display_name "$tool")

        local enabled=false customized=false
        if grep -qxF "$tool" <<<"$enabled_tools"; then enabled=true; fi
        if grep -qxF "$tool" <<<"$customized_tools"; then customized=true; fi

        local marker status_text
        if [[ "$enabled" == "true" ]]; then
            marker="$(_green "●")"
            status_text="$(_dim "enabled")"
            enabled_count=$((enabled_count + 1))
        else
            marker="$(_dim "○")"
            status_text="$(_dim "available")"
            available_count=$((available_count + 1))
        fi

        local star=" "
        if [[ "$customized" == "true" ]]; then
            star="$(_yellow "★")"
            customized_count=$((customized_count + 1))
        fi

        # Resources column tracks hooks/mcp/settings overrides.
        local resources
        resources=$(_list_resources_column "$tool")
        if [[ "$resources" == *"*"* ]] || [[ "$resources" == *"~"* ]]; then
            payload_override_count=$((payload_override_count + 1))
        fi

        printf "    %s %s  %-22s %-13s %-10s  %s\n" "$marker" "$star" "$display" "$(_dim "$tool")" "$status_text" "$resources"
    done <<< "$all"

    echo ""
    local total
    total=$(echo "$all" | grep -c .)
    local summary="$enabled_count of $total enabled"
    [[ $customized_count -gt 0 ]]         && summary="$summary, $customized_count tool override(s)"
    [[ $payload_override_count -gt 0 ]]   && summary="$summary, $payload_override_count payload override(s)"
    echo "  $summary"

    # Shared MCP source: one .ai/src/mcp.json applies to every enabled tool
    # unless the tool has its own per-tool override.
    local shared_mcp="$REPO_ROOT/.ai/src/mcp.json"
    if [[ -f "$shared_mcp" ]]; then
        local mcp_override_count=0
        while IFS= read -r tool; do
            [[ -z "$tool" ]] && continue
            if [[ -n "$(_find_new_payload_override "$tool" "mcp")" ]]; then
                mcp_override_count=$((mcp_override_count + 1))
            fi
        done <<< "$all"
        local mcp_hint="  Shared MCP: $(_yellow ".ai/src/mcp.json")"
        if [[ $mcp_override_count -gt 0 ]]; then
            mcp_hint="$mcp_hint $(_dim "(+ $mcp_override_count per-tool override)")"
        fi
        echo "$mcp_hint"
    fi

    echo ""
    if [[ $enabled_count -eq 0 ]]; then
        echo "  Enable a tool:     $(_cyan "agentsync enable <slug>")"
    fi
    echo "  Customize a tool:  $(_cyan "agentsync customize <slug> [<resource>]")"
    if [[ ! -f "$shared_mcp" ]]; then
        echo "  Add MCP server:    $(_cyan "agentsync add mcp <server> --command …")"
    fi
    echo "  Sync outputs:      $(_cyan "agentsync sync")"
    echo ""
}
