#!/usr/bin/env bash
# agentsync resolve — interactive walk-through of user overrides.
#
# For each overridden field, shows user value vs base value and asks:
#   [k]eep    — keep the override as-is (default)
#   [a]dopt   — remove the override so base value wins
#   [s]kip    — skip this field (same as keep, but explicit)
#
# In non-TTY mode, prints a read-only summary and exits 0.

_resolve_prepare_context() {
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

# Well-known override-reviewable keys — must match customize.sh.
_resolve_keys() {
    cat <<'KEYS'
name
enabled
targets.agents.dest
targets.rules.dest
targets.rules.extension
targets.rules.header
targets.rules.append_imports
targets.rules.merge_to_file
targets.rules.inline_into_agents
targets.rules.prepend_agents
targets.skills.dest
targets.skills.inline_into_agents
targets.commands.dest
targets.commands.format
targets.subagents.dest
targets.subagents.format
targets.settings.source
targets.settings.dest
targets.mcp.source
targets.mcp.dest
targets.hooks.source
targets.hooks.dest
post_sync
KEYS
}

cmd_resolve() {
    local tool_filter="${1:-}"

    _resolve_prepare_context

    local overrides
    overrides=$(list_user_override_tools)

    if [[ -z "$overrides" ]]; then
        echo ""
        echo "  $(_dim "No user overrides — nothing to resolve.")"
        echo ""
        return 0
    fi

    local interactive=true
    [[ -t 0 ]] || interactive=false
    [[ -t 1 ]] || interactive=false

    if [[ "$interactive" != "true" ]]; then
        echo ""
        _bold "  Resolve (read-only — not a TTY)"; echo ""
        echo "  Run from an interactive shell to review overrides one by one."
        echo "  Use $(_cyan "agentsync diff") for a full list."
        echo ""
        return 0
    fi

    local matched=false
    local tool
    while IFS= read -r tool; do
        [[ -z "$tool" ]] && continue
        if [[ -n "$tool_filter" ]] && [[ "$tool" != "$tool_filter" ]]; then
            continue
        fi
        _resolve_one_tool "$tool"
        matched=true
    done <<< "$overrides"

    if [[ "$matched" != "true" ]]; then
        echo "$(_red "Error"): No override found for '$tool_filter'." >&2
        return 1
    fi

    echo ""
    _green "Done."; echo ""
    echo "  Run $(_cyan "agentsync sync") to apply any changes."
    echo ""
}

_resolve_one_tool() {
    local tool_name="$1"
    local base_file user_file
    base_file=$(tool_resolver_base_file "$tool_name")
    user_file=$(tool_resolver_user_file "$tool_name")

    echo ""
    _bold "  $(tool_display_name "$tool_name")"; echo ""
    _dim "  override: ${user_file#"$REPO_ROOT/"}"; echo ""
    if [[ -f "$base_file" ]]; then
        _dim "  base:     ${base_file#"$DEFAULT_REPO_ROOT/"}"; echo ""
    else
        _dim "  base:     (custom tool — no base)"; echo ""
    fi
    echo ""

    local any_diff=false
    local key u b
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        u=""
        b=""
        u=$(parse_yaml_value "$user_file" "$key")
        [[ -f "$base_file" ]] && b=$(parse_yaml_value "$base_file" "$key")

        if [[ -z "$u" ]]; then
            continue
        fi
        if [[ "$u" == "$b" ]]; then
            continue
        fi

        any_diff=true
        echo "    $(_yellow "◆") $key"
        printf "        %s %s\n" "$(_dim "user:")" "$u"
        if [[ -n "$b" ]]; then
            printf "        %s %s\n" "$(_dim "base:")" "$b"
        else
            printf "        %s %s\n" "$(_dim "base:")" "$(_dim "(not set)")"
        fi

        local answer
        printf "        %s " "$(_bold "[k]eep / [a]dopt base / [s]kip")"
        IFS= read -r answer < /dev/tty || answer=""

        case "$answer" in
            a|A|adopt)
                yaml_remove_key "$user_file" "$key"
                echo "        $(_green "→ adopted base value")"
                ;;
            s|S|skip|"")
                echo "        $(_dim "→ skipped")"
                ;;
            k|K|keep|*)
                echo "        $(_dim "→ kept user value")"
                ;;
        esac
        echo ""
    done < <(_resolve_keys)

    if [[ "$any_diff" == "false" ]]; then
        _dim "    No diverging fields."; echo ""
    fi
}
