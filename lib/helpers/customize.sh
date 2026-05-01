#!/usr/bin/env bash
# agentsync customize / show / diff — inspect and create overrides for tools.
#
# Resources:
#   tool      (default)  — tools/<name>.yaml override
#   hooks                — hooks/<name>.<ext> payload override
#   mcp                  — mcp/<name>.<ext> payload override
#   settings             — settings/<name>.<ext> payload override

_VALID_RESOURCES="tool hooks mcp settings"

_validate_resource() {
    local resource="$1"
    case " $_VALID_RESOURCES " in
        *" $resource "*) return 0 ;;
        *)
            echo "$(_red "Error"): Unknown resource '$resource'." >&2
            echo "Valid: $_VALID_RESOURCES" >&2
            exit 1
            ;;
    esac
}

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
    local yes=false
    local tool_name=""
    local resource=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --full) full=true; shift ;;
            --yes|-y) yes=true; shift ;;
            -*)
                echo "$(_red "Error"): Unknown flag: $1" >&2
                exit 1
                ;;
            *)
                if [[ -z "$tool_name" ]]; then
                    tool_name="$1"
                    shift
                elif [[ -z "$resource" ]]; then
                    resource="$1"
                    shift
                else
                    echo "$(_red "Error"): Too many arguments." >&2
                    echo "Usage: agentsync customize <slug> [<resource>] [--full] [--yes]" >&2
                    exit 1
                fi
                ;;
        esac
    done

    if [[ -z "$tool_name" ]]; then
        echo "$(_red "Error"): agentsync customize <slug> [<resource>] [--full] [--yes]" >&2
        echo "  <resource>: $_VALID_RESOURCES (default: tool)" >&2
        exit 1
    fi

    resource="${resource:-tool}"
    _validate_resource "$resource"

    _customize_prepare_context

    case "$resource" in
        tool)     _customize_tool "$tool_name" "$full" ;;
        hooks)    _customize_payload "$tool_name" "hooks" "$yes" ;;
        mcp)      _customize_payload "$tool_name" "mcp" "$yes" ;;
        settings) _customize_payload "$tool_name" "settings" "$yes" ;;
    esac
}

_customize_tool() {
    local tool_name="$1"
    local full="$2"

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

# Copy a base payload file (hooks/mcp/settings) into .ai/src/tools/<tool>/
# as an override. If a legacy flat-layout file exists at the old path, migrate
# it inline before scaffolding. For hooks: show summary + require confirmation
# (unless --yes or non-TTY batch).
_customize_payload() {
    local tool_name="$1"
    local resource="$2"
    local yes="$3"

    local base_file
    base_file=$(_find_base_payload "$resource" "$tool_name")
    if [[ -z "$base_file" ]]; then
        echo "$(_red "Error"): No base $resource template for '$tool_name'." >&2
        echo "" >&2
        echo "Either '$tool_name' is unknown, or this tool doesn't ship a $resource template." >&2
        echo "Run $(_cyan "agentsync list") to see available tools." >&2
        exit 1
    fi

    local user_file legacy_file
    user_file=$(_payload_override_path "$tool_name" "$resource")
    legacy_file=$(_payload_override_legacy_path "$tool_name" "$resource")

    # Inline migration: if legacy flat file exists and new path does not,
    # move it to the per-tool dir before anything else.
    if [[ -n "$legacy_file" ]] && [[ -f "$legacy_file" ]] && [[ ! -f "$user_file" ]]; then
        mkdir -p "$(dirname "$user_file")"
        mv "$legacy_file" "$user_file"
        _yellow "Migrated legacy override:"; echo " ${legacy_file#"$REPO_ROOT/"} → ${user_file#"$REPO_ROOT/"}"
    fi

    if [[ -f "$user_file" ]]; then
        echo "$(_yellow "Override already exists"): $user_file"
        echo ""
        echo "Edit it directly, or remove it to start over."
        echo "See effective source:  $(_cyan "agentsync show $tool_name $resource")"
        echo "See your vs base diff: $(_cyan "agentsync diff $tool_name $resource")"
        return 0
    fi

    # Hooks carry executable intent — show summary + require opt-in.
    if [[ "$resource" == "hooks" ]]; then
        echo ""
        _yellow "⚠  You are about to override hooks for $(tool_display_name "$tool_name")."
        echo ""
        echo "Hooks can run shell commands after sync. Review the base template"
        echo "below before copying it — anything you put here will run locally."
        echo ""
        _dim "  Base: $base_file"; echo ""
        echo ""
        sed 's/^/    /' "$base_file"
        echo ""

        if [[ "$yes" != "true" ]]; then
            if [[ -t 0 ]]; then
                local reply=""
                read -r -p "$(_bold "Create this override? [y/N] ")" reply
                case "$reply" in
                    y|Y|yes|YES) ;;
                    *)
                        echo "$(_dim "Cancelled.")"
                        return 0
                        ;;
                esac
            else
                echo "$(_red "Error"): Refusing to scaffold hook override in non-interactive mode." >&2
                echo "Re-run with $(_cyan "--yes") to confirm." >&2
                exit 1
            fi
        fi
    fi

    mkdir -p "$(dirname "$user_file")"
    cp "$base_file" "$user_file"

    echo ""
    _green "Created $resource override:"; echo " $user_file"
    echo ""
    _dim "  source (base): $base_file"; echo ""
    echo ""
    echo "Edit this file to customize. Remove it to fall back to the base template."
    echo "See diff vs base: $(_cyan "agentsync diff $tool_name $resource")"
    echo ""
}

# ── show ──────────────────────────────────────────────────────────────────────

cmd_show() {
    local show_base=false
    local tool_name=""
    local resource=""

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
                elif [[ -z "$resource" ]]; then
                    resource="$1"
                    shift
                else
                    echo "$(_red "Error"): Too many arguments." >&2
                    exit 1
                fi
                ;;
        esac
    done

    if [[ -z "$tool_name" ]]; then
        echo "$(_red "Error"): agentsync show <slug> [<resource>] [--base]" >&2
        echo "  <resource>: $_VALID_RESOURCES (default: tool)" >&2
        exit 1
    fi

    resource="${resource:-tool}"
    _validate_resource "$resource"

    _customize_prepare_context

    # Payload resources resolve via base+override fallback.
    if [[ "$resource" != "tool" ]]; then
        _show_payload "$tool_name" "$resource" "$show_base"
        return 0
    fi

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

_show_payload() {
    local tool_name="$1"
    local resource="$2"
    local show_base="$3"

    local base_file user_file legacy_file effective
    base_file=$(_find_base_payload "$resource" "$tool_name")
    user_file=$(_payload_override_path "$tool_name" "$resource")
    legacy_file=$(_payload_override_legacy_path "$tool_name" "$resource")
    effective=$(resolve_payload_source "$tool_name" "$resource")

    if [[ "$show_base" == "true" ]]; then
        if [[ -z "$base_file" ]]; then
            echo "$(_red "Error"): No base $resource template for '$tool_name'." >&2
            exit 1
        fi
        echo ""
        _bold "  Base $resource"; echo " $(_dim "$base_file")"
        echo ""
        sed 's/^/    /' "$base_file"
        echo ""
        return 0
    fi

    if [[ -z "$effective" ]]; then
        echo "$(_red "Error"): No $resource source for '$tool_name' (neither override nor base)." >&2
        echo "Run $(_cyan "agentsync list") to see available tools." >&2
        exit 1
    fi

    local source_label
    source_label="$(_dim "base")"
    if [[ -n "$user_file" ]] && [[ -f "$user_file" ]] && [[ "$user_file" == "$effective" ]]; then
        source_label="$(_yellow "★ user override")"
    elif [[ -n "$legacy_file" ]] && [[ -f "$legacy_file" ]] && [[ "$legacy_file" == "$effective" ]]; then
        source_label="$(_yellow "★ user override (legacy layout)")"
    fi

    echo ""
    _bold "  $(tool_display_name "$tool_name") — $resource  [$source_label]"; echo ""
    _dim "  effective: $effective"; echo ""
    if [[ -n "$user_file" ]] && [[ -f "$user_file" ]]; then
        _dim "  override:  $user_file"; echo ""
    fi
    if [[ -n "$legacy_file" ]] && [[ -f "$legacy_file" ]] && [[ "$legacy_file" != "$effective" || "$effective" != "$user_file" ]]; then
        # Show legacy only if it's actually on disk and not already listed.
        if [[ ! -f "$user_file" ]]; then
            _dim "  legacy:    $legacy_file"; echo ""
        fi
    fi
    if [[ -n "$base_file" ]]; then
        _dim "  base:      $base_file"; echo ""
    fi
    echo ""
    sed 's/^/    /' "$effective"
    echo ""
}

# ── diff ──────────────────────────────────────────────────────────────────────

cmd_diff() {
    local tool_name=""
    local resource=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -*)
                echo "$(_red "Error"): Unknown flag: $1" >&2
                exit 1
                ;;
            *)
                if [[ -z "$tool_name" ]]; then
                    tool_name="$1"
                    shift
                elif [[ -z "$resource" ]]; then
                    resource="$1"
                    shift
                else
                    echo "$(_red "Error"): Too many arguments." >&2
                    exit 1
                fi
                ;;
        esac
    done

    _customize_prepare_context

    resource="${resource:-tool}"
    _validate_resource "$resource"

    if [[ "$resource" != "tool" ]]; then
        if [[ -z "$tool_name" ]]; then
            echo "$(_red "Error"): agentsync diff <slug> <resource>" >&2
            exit 1
        fi
        _diff_payload "$tool_name" "$resource"
        return 0
    fi

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

_diff_payload() {
    local tool_name="$1"
    local resource="$2"

    local base_file user_file
    base_file=$(_find_base_payload "$resource" "$tool_name")
    # Prefer new layout; fall back to legacy flat file if present.
    user_file=$(_find_new_payload_override "$tool_name" "$resource")
    if [[ -z "$user_file" ]]; then
        local legacy
        legacy=$(_payload_override_legacy_path "$tool_name" "$resource")
        if [[ -n "$legacy" ]] && [[ -f "$legacy" ]]; then
            user_file="$legacy"
        fi
    fi

    if [[ -z "$base_file" ]] && [[ -z "$user_file" ]]; then
        echo "$(_red "Error"): No $resource source for '$tool_name' (no base, no override)." >&2
        exit 1
    fi

    if [[ -z "$user_file" ]] || [[ ! -f "$user_file" ]]; then
        echo ""
        _dim "  No override for $(tool_display_name "$tool_name") $resource — inheriting fully from base."; echo ""
        _dim "  base: $base_file"; echo ""
        echo ""
        return 0
    fi

    if [[ -z "$base_file" ]]; then
        echo ""
        _yellow "  Custom $resource override (no base to diff against):"; echo ""
        _dim "  override: $user_file"; echo ""
        echo ""
        return 0
    fi

    echo ""
    _bold "  $(tool_display_name "$tool_name") — $resource diff"; echo ""
    _dim "    override: $user_file"; echo ""
    _dim "    base:     $base_file"; echo ""
    echo ""
    if diff -u "$base_file" "$user_file" > /dev/null 2>&1; then
        _dim "    Identical — override is a byte-for-byte copy of base."
        echo ""
        _dim "    Tip: $(_cyan "agentsync simplify") can remove redundant overrides."
        echo ""
        return 0
    fi
    # diff returns 1 when files differ — that's expected, not an error.
    diff -u --label "base" --label "override" "$base_file" "$user_file" 2>/dev/null | sed 's/^/    /' || true
    echo ""
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
