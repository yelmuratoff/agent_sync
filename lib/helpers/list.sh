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

cmd_list() {
    _list_prepare_context

    echo ""
    _bold "  AgentSync Tools"; echo ""
    _dim "  ● enabled   ○ available   ★ customized"; echo ""
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

        local star=""
        if [[ "$customized" == "true" ]]; then
            star="  $(_yellow "★")"
            customized_count=$((customized_count + 1))
        fi

        printf "    %s  %-30s %s%s\n" "$marker" "$display" "$status_text" "$star"
    done <<< "$all"

    echo ""
    local total
    total=$(echo "$all" | grep -c .)
    echo "  $enabled_count of $total enabled$( [[ $customized_count -gt 0 ]] && echo ", $customized_count customized")"
    echo ""
    if [[ $enabled_count -eq 0 ]]; then
        echo "  Enable a tool:     $(_cyan "agentsync enable <name>")"
    fi
    echo "  Customize a tool:  $(_cyan "agentsync customize <name>")"
    echo "  Sync outputs:      $(_cyan "agentsync sync")"
    echo ""
}
