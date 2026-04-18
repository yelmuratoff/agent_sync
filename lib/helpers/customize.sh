#!/usr/bin/env bash
# agentsync customize / show / diff — inspect and create overrides for tools.

_customize_prepare_context() {
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

# ── customize ─────────────────────────────────────────────────────────────────

cmd_customize() {
    local full=false
    local tool_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --full) full=true; shift ;;
            -*)
                echo "$(_red "Error"): Unknown flag: $1" >&2
                exit 1
                ;;
            *)
                if [[ -z "$tool_name" ]]; then
                    tool_name="$1"
                    shift
                else
                    echo "$(_red "Error"): Only one tool at a time." >&2
                    exit 1
                fi
                ;;
        esac
    done

    if [[ -z "$tool_name" ]]; then
        echo "$(_red "Error"): agentsync customize <tool> [--full]" >&2
        exit 1
    fi

    _customize_prepare_context

    local base_file user_file
    base_file=$(tool_resolver_base_file "$tool_name")
    user_file=$(tool_resolver_user_file "$tool_name")

    local base_exists=false
    [[ -f "$base_file" ]] && base_exists=true

    if [[ "$base_exists" != "true" ]] && [[ "$full" == "true" ]]; then
        echo "$(_red "Error"): No base template for '$tool_name' — cannot use --full." >&2
        echo "Create $user_file manually for a custom tool." >&2
        exit 1
    fi

    if [[ -f "$user_file" ]]; then
        echo "$(_yellow "Override already exists"): $user_file"
        echo ""
        echo "Edit it directly, or remove it to start over."
        echo "See effective config: $(_cyan "agentsync show $tool_name")"
        return 0
    fi

    mkdir -p "$(dirname "$user_file")"

    if [[ "$full" == "true" ]]; then
        cp "$base_file" "$user_file"
        echo ""
        _green "Created full override:"; echo " $user_file"
        echo ""
        echo "This is a full copy of the base template. Every field you keep"
        echo "wins over future base updates. Remove fields you don't need to"
        echo "customize — those will inherit from base automatically."
        echo ""
    else
        {
            echo "# $(tool_display_name "$tool_name") — custom override for AgentSync."
            if [[ "$base_exists" == "true" ]]; then
                echo "#"
                echo "# Only fields you write here are \"owned\" by you."
                echo "# Everything else inherits from the base template and receives updates."
                echo "#"
                echo "# See base fields:          agentsync show $tool_name --base"
                echo "# See effective config:     agentsync show $tool_name"
                echo "# See your vs base diff:    agentsync diff $tool_name"
            else
                echo "#"
                echo "# This is a custom tool — no base template exists."
                echo "# Define the full config here, then add to tools.enabled in agent_sync.yaml."
            fi
            echo ""
        } > "$user_file"

        echo ""
        _green "Created empty override:"; echo " $user_file"
        echo ""
        echo "Add only fields you want to change. Everything else inherits from base."
        echo "See overridable fields: $(_cyan "agentsync show $tool_name --base")"
        echo ""
    fi
}

# ── show ──────────────────────────────────────────────────────────────────────

cmd_show() {
    local show_base=false
    local tool_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base) show_base=true; shift ;;
            -*)
                echo "$(_red "Error"): Unknown flag: $1" >&2
                exit 1
                ;;
            *)
                if [[ -z "$tool_name" ]]; then
                    tool_name="$1"
                    shift
                else
                    echo "$(_red "Error"): Only one tool at a time." >&2
                    exit 1
                fi
                ;;
        esac
    done

    if [[ -z "$tool_name" ]]; then
        echo "$(_red "Error"): agentsync show <tool> [--base]" >&2
        exit 1
    fi

    _customize_prepare_context

    local base_file user_file
    base_file=$(tool_resolver_base_file "$tool_name")
    user_file=$(tool_resolver_user_file "$tool_name")

    if [[ "$show_base" == "true" ]]; then
        if [[ ! -f "$base_file" ]]; then
            echo "$(_red "Error"): No base template for '$tool_name'." >&2
            exit 1
        fi
        echo ""
        _bold "  Base template"; echo " $(_dim "$base_file")"
        echo ""
        sed 's/^/    /' "$base_file"
        echo ""
        return 0
    fi

    if [[ ! -f "$base_file" ]] && [[ ! -f "$user_file" ]]; then
        echo "$(_red "Error"): Unknown tool '$tool_name'." >&2
        echo "Run $(_cyan "agentsync list") to see available tools." >&2
        exit 1
    fi

    local enabled_label
    if is_tool_enabled "$tool_name"; then
        enabled_label="$(_green "enabled")"
    else
        enabled_label="$(_dim "disabled")"
    fi

    echo ""
    _bold "  $(tool_display_name "$tool_name")"; echo "  [$enabled_label]"
    if [[ -f "$user_file" ]]; then
        _dim "  override: $user_file"; echo ""
    fi
    if [[ -f "$base_file" ]]; then
        _dim "  base:     $base_file"; echo ""
    fi
    echo ""

    # Emit effective values for the well-known keys.
    local keys=(
        "name"
        "enabled"
        "targets.agents.dest"
        "targets.agents.source"
        "targets.rules.dest"
        "targets.rules.source"
        "targets.rules.extension"
        "targets.rules.header"
        "targets.rules.append_imports"
        "targets.rules.merge_to_file"
        "targets.rules.inline_into_agents"
        "targets.rules.prepend_agents"
        "targets.skills.dest"
        "targets.skills.inline_into_agents"
        "targets.commands.dest"
        "targets.commands.format"
        "targets.commands.extension"
        "targets.subagents.dest"
        "targets.subagents.format"
        "targets.subagents.extension"
        "targets.settings.source"
        "targets.settings.dest"
        "targets.mcp.source"
        "targets.mcp.dest"
        "targets.hooks.source"
        "targets.hooks.dest"
        "post_sync"
    )

    local key user_val base_val source_label
    for key in "${keys[@]}"; do
        user_val=""
        base_val=""
        if [[ -f "$user_file" ]]; then
            user_val=$(parse_yaml_value "$user_file" "$key")
        fi
        if [[ -f "$base_file" ]]; then
            base_val=$(parse_yaml_value "$base_file" "$key")
        fi

        if [[ -n "$user_val" ]]; then
            source_label="$(_yellow "★ user")"
            printf "    %s  %-42s  %s\n" "$source_label" "$key" "$user_val"
        elif [[ -n "$base_val" ]]; then
            source_label="$(_dim "base  ")"
            printf "    %s  %-42s  %s\n" "$source_label" "$key" "$base_val"
        fi
    done
    echo ""
}

# ── diff ──────────────────────────────────────────────────────────────────────

cmd_diff() {
    local tool_name="${1:-}"

    _customize_prepare_context

    local overrides
    overrides=$(list_user_override_tools)

    if [[ -z "$overrides" ]]; then
        echo ""
        echo "  $(_dim "No user overrides — all tools inherit fully from base.")"
        echo ""
        return 0
    fi

    local any=false
    local tool
    while IFS= read -r tool; do
        [[ -z "$tool" ]] && continue
        if [[ -n "$tool_name" ]] && [[ "$tool" != "$tool_name" ]]; then
            continue
        fi
        _diff_one_tool "$tool"
        any=true
    done <<< "$overrides"

    if [[ "$any" == "false" ]]; then
        echo "$(_red "Error"): No override found for '$tool_name'." >&2
        exit 1
    fi
}

_diff_one_tool() {
    local tool_name="$1"
    local base_file user_file
    base_file=$(tool_resolver_base_file "$tool_name")
    user_file=$(tool_resolver_user_file "$tool_name")

    echo ""
    _bold "  $tool_name"; echo ""
    _dim "    user: $user_file"; echo ""
    if [[ -f "$base_file" ]]; then
        _dim "    base: $base_file"; echo ""
    else
        _dim "    base: (none — custom tool)"; echo ""
    fi
    echo ""

    local keys=(
        "name"
        "enabled"
        "targets.agents.dest"
        "targets.rules.dest"
        "targets.rules.extension"
        "targets.rules.header"
        "targets.rules.append_imports"
        "targets.rules.merge_to_file"
        "targets.rules.inline_into_agents"
        "targets.rules.prepend_agents"
        "targets.skills.dest"
        "targets.skills.inline_into_agents"
        "targets.commands.dest"
        "targets.commands.format"
        "targets.subagents.dest"
        "targets.subagents.format"
        "targets.settings.source"
        "targets.settings.dest"
        "targets.mcp.source"
        "targets.mcp.dest"
        "targets.hooks.source"
        "targets.hooks.dest"
        "post_sync"
    )

    local printed_override=false printed_inherit=false
    local key u b
    for key in "${keys[@]}"; do
        u=""
        b=""
        [[ -f "$user_file" ]] && u=$(parse_yaml_value "$user_file" "$key")
        [[ -f "$base_file" ]] && b=$(parse_yaml_value "$base_file" "$key")

        if [[ -n "$u" ]] && [[ "$u" != "$b" ]]; then
            if [[ "$printed_override" == "false" ]]; then
                echo "    $(_yellow "Your overrides (win over base):")"
                printed_override=true
            fi
            printf "      %s\n" "$key"
            printf "        you:  %s\n" "$u"
            if [[ -n "$b" ]]; then
                printf "        base: %s\n" "$b"
            else
                printf "        base: %s\n" "$(_dim "(not in base)")"
            fi
        fi
    done

    [[ "$printed_override" == "true" ]] && echo ""

    for key in "${keys[@]}"; do
        u=""
        b=""
        [[ -f "$user_file" ]] && u=$(parse_yaml_value "$user_file" "$key")
        [[ -f "$base_file" ]] && b=$(parse_yaml_value "$base_file" "$key")

        if [[ -z "$u" ]] && [[ -n "$b" ]]; then
            if [[ "$printed_inherit" == "false" ]]; then
                echo "    $(_dim "Inherited from base (remove override to keep inheriting):")"
                printed_inherit=true
            fi
            printf "      %-42s  %s\n" "$key" "$b"
        fi
    done

    [[ "$printed_inherit" == "true" ]] && echo ""

    if [[ "$printed_override" == "false" ]] && [[ "$printed_inherit" == "false" ]]; then
        _dim "    No diverging fields."; echo ""
    fi
}
