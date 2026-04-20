#!/usr/bin/env bash
# agentsync simplify — compress user overrides by dropping fields that
# already match the base template.
#
# After `agentsync customize --full`, an override carries the whole base
# verbatim. Over time those redundant fields pin stale values and silently
# block upstream updates. `simplify` walks every override, compares each
# field against the current base, and removes the ones that are byte-equal.
#
# Dry-run by default — pass --apply to persist. If an override ends up empty
# the file is offered for deletion (auto-accepted with -y).

# Well-known overridable keys — superset of customize.sh / resolve_cmd.sh keys.
# Any key outside this set stays untouched so we never drop user-defined extras.
_simplify_keys() {
    cat <<'KEYS'
name
enabled
targets.agents.dest
targets.agents.source
targets.rules.dest
targets.rules.source
targets.rules.extension
targets.rules.header
targets.rules.append_imports
targets.rules.merge_to_file
targets.rules.inline_into_agents
targets.rules.prepend_agents
targets.skills.dest
targets.skills.source
targets.skills.inline_into_agents
targets.commands.dest
targets.commands.format
targets.commands.extension
targets.subagents.dest
targets.subagents.format
targets.subagents.extension
targets.settings.source
targets.settings.dest
targets.mcp.source
targets.mcp.dest
targets.hooks.source
targets.hooks.dest
post_sync
KEYS
}

# Mirror customize / resolve context setup — sets REPO_ROOT, DEFAULT_REPO_ROOT,
# PROJECT_CONFIG_PATH used by the tool_resolver helpers.
_simplify_prepare_context() {
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

_simplify_print_usage() {
    echo ""
    _bold "  agentsync simplify [<tool>] [--apply] [-y]"; echo ""
    echo ""
    echo "  Removes fields from user overrides when they match the base."
    echo "  Dry-run by default — pass $(_cyan "--apply") to persist."
    echo ""
    echo "  Flags:"
    echo "    --apply    Write changes to disk (default: preview)"
    echo "    -y, --yes  Auto-delete empty override files (no prompt)"
    echo ""
}

# Return 0 if the YAML file has any non-comment key:value assignment or list
# item with a non-empty scalar. Bare block headers (`targets:`) don't count.
_simplify_file_has_content() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^[[:space:]]*[a-zA-Z0-9_-]+:[[:space:]]+.+$ ]]; then
            return 0
        fi
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+ ]]; then
            return 0
        fi
    done < "$file"
    return 1
}

cmd_simplify() {
    local apply=false
    local auto_yes=false
    local tool_filter=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --apply) apply=true; shift ;;
            -y|--yes) auto_yes=true; shift ;;
            -h|--help) _simplify_print_usage; return 0 ;;
            -*)
                echo "$(_red "Error"): Unknown flag: $1" >&2
                return 1
                ;;
            *)
                if [[ -z "$tool_filter" ]]; then
                    tool_filter="$1"
                    shift
                else
                    echo "$(_red "Error"): Only one tool at a time." >&2
                    return 1
                fi
                ;;
        esac
    done

    _simplify_prepare_context

    local overrides
    overrides=$(list_user_override_tools)

    local matched=false

    # Pass 1: tool YAML overrides.
    if [[ -n "$overrides" ]]; then
        local tool
        while IFS= read -r tool; do
            [[ -z "$tool" ]] && continue
            if [[ -n "$tool_filter" ]] && [[ "$tool" != "$tool_filter" ]]; then
                continue
            fi
            matched=true
            _simplify_one_tool "$tool" "$apply" "$auto_yes"
        done <<< "$overrides"
    fi

    # Pass 2: payload overrides (hooks/mcp/settings). Byte-compare with base.
    # Sets _SIMPLIFY_PAYLOAD_MATCHED=true if any payload was considered.
    _SIMPLIFY_PAYLOAD_MATCHED=false
    _simplify_payload_overrides "$apply" "$auto_yes" "$tool_filter" || true
    [[ "$_SIMPLIFY_PAYLOAD_MATCHED" == "true" ]] && matched=true

    if [[ "$matched" != "true" ]]; then
        if [[ -n "$tool_filter" ]]; then
            echo "$(_red "Error"): No override found for '$tool_filter'." >&2
            return 1
        fi
        echo ""
        echo "  $(_dim "No user overrides — nothing to simplify.")"
        echo ""
        return 0
    fi

    echo ""
    if [[ "$apply" == "true" ]]; then
        _green "Done."; echo ""
        echo "  Run $(_cyan "agentsync sync") to verify outputs are unchanged."
    else
        _dim "Dry run — pass --apply to persist."; echo ""
    fi
    echo ""
    return 0
}

# Scan .ai/src/{hooks,mcp,settings}/ for overrides that are byte-identical to
# their base template. Those are scaffolded copies the user never edited —
# deleting them lets the base drift through on future updates.
#
# Returns 0 if at least one payload was considered (matched tool_filter),
# 1 otherwise (only meaningful for error reporting in the caller).
_simplify_payload_overrides() {
    local apply="$1"
    local auto_yes="$2"
    local tool_filter="$3"

    local overrides_root="$REPO_ROOT/.ai/src"

    # First pass: collect candidates so we can print a clean block-with-header.
    local -a redundant_files=()
    local -a kept_files=()
    local resource file tool base_file
    for resource in hooks mcp settings; do
        [[ -d "$overrides_root/$resource" ]] || continue
        for file in "$overrides_root/$resource"/*; do
            [[ -f "$file" ]] || continue
            tool="$(basename "$file")"
            tool="${tool%.*}"

            if [[ -n "$tool_filter" ]] && [[ "$tool" != "$tool_filter" ]]; then
                continue
            fi
            _SIMPLIFY_PAYLOAD_MATCHED=true

            base_file=$(_find_base_payload "$resource" "$tool")

            if [[ -z "$base_file" ]] || ! cmp -s "$file" "$base_file"; then
                kept_files+=("$file")
                continue
            fi
            redundant_files+=("$file")
        done
    done

    if [[ ${#redundant_files[@]} -eq 0 ]] && [[ ${#kept_files[@]} -eq 0 ]]; then
        return 0
    fi

    echo ""
    _bold "  Payload overrides"; echo ""
    echo ""

    local rel
    if [[ ${#redundant_files[@]} -eq 0 ]]; then
        _dim "  No byte-identical payload overrides — ${#kept_files[@]} real customization(s)."; echo ""
        return 0
    fi

    echo "  $(_yellow "Byte-identical to base (safe to delete):")"
    for file in "${redundant_files[@]}"; do
        rel="${file#"$REPO_ROOT/"}"
        printf "    %s %s\n" "$(_dim "-")" "$rel"
    done
    echo ""

    if [[ ${#kept_files[@]} -gt 0 ]]; then
        _dim "  Kept (diverge from base or no base): ${#kept_files[@]} file(s)"; echo ""
    fi

    if [[ "$apply" != "true" ]]; then
        _dim "  → would delete ${#redundant_files[@]} payload override(s)."; echo ""
        return 0
    fi

    # --apply: delete (with confirmation unless --yes or non-TTY).
    local deleted=0 skipped=0
    for file in "${redundant_files[@]}"; do
        rel="${file#"$REPO_ROOT/"}"
        local do_delete=false
        if [[ "$auto_yes" == "true" ]]; then
            do_delete=true
        elif [[ -t 0 ]] && [[ -t 1 ]]; then
            local answer
            printf "  %s " "$(_bold "Delete $rel? [y/N]")"
            IFS= read -r answer < /dev/tty || answer=""
            case "$answer" in y|Y|yes|Yes) do_delete=true ;; esac
        else
            do_delete=true
        fi
        if [[ "$do_delete" == "true" ]]; then
            rm -f "$file"
            echo "  $(_green "Deleted") $rel"
            deleted=$((deleted + 1))
        else
            _dim "  Kept $rel"; echo ""
            skipped=$((skipped + 1))
        fi
    done
    echo ""
    _dim "  Removed $deleted, kept $skipped."; echo ""
    return 0
}

_simplify_one_tool() {
    local tool_name="$1"
    local apply="$2"
    local auto_yes="$3"

    local base_file user_file
    base_file=$(tool_resolver_base_file "$tool_name")
    user_file=$(tool_resolver_user_file "$tool_name")

    [[ -f "$user_file" ]] || return 0

    echo ""
    _bold "  $(tool_display_name "$tool_name")"; echo ""
    _dim "  override: ${user_file#"$REPO_ROOT/"}"; echo ""

    local -a redundant_keys=()
    local -a kept_keys=()
    local -a user_only_keys=()

    local key u b
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        u=$(parse_yaml_value "$user_file" "$key")
        [[ -z "$u" ]] && continue
        b=""
        [[ -f "$base_file" ]] && b=$(parse_yaml_value "$base_file" "$key")

        if [[ -n "$b" ]] && [[ "$u" == "$b" ]]; then
            redundant_keys+=("$key")
        elif [[ -z "$b" ]]; then
            user_only_keys+=("$key")
        else
            kept_keys+=("$key")
        fi
    done < <(_simplify_keys)

    if [[ ${#redundant_keys[@]} -eq 0 ]]; then
        _dim "  No redundant fields — already minimal."; echo ""
        return 0
    fi

    echo "  $(_yellow "Redundant (match base):")"
    local k v
    for k in "${redundant_keys[@]}"; do
        v=$(parse_yaml_value "$user_file" "$k")
        printf "    %s %-42s  %s\n" "$(_dim "-")" "$k" "$v"
    done
    echo ""

    if [[ ${#kept_keys[@]} -gt 0 ]]; then
        _dim "  Kept (diverge from base):"; echo ""
        for k in "${kept_keys[@]}"; do
            v=$(parse_yaml_value "$user_file" "$k")
            printf "    %s %-42s  %s\n" "$(_dim "=")" "$k" "$v"
        done
        echo ""
    fi

    if [[ ${#user_only_keys[@]} -gt 0 ]]; then
        _dim "  Kept (no base value):"; echo ""
        for k in "${user_only_keys[@]}"; do
            v=$(parse_yaml_value "$user_file" "$k")
            printf "    %s %-42s  %s\n" "$(_dim "=")" "$k" "$v"
        done
        echo ""
    fi

    if [[ "$apply" != "true" ]]; then
        local remaining=$(( ${#kept_keys[@]} + ${#user_only_keys[@]} ))
        if [[ $remaining -eq 0 ]]; then
            _dim "  → would delete the override file (all fields match base)."; echo ""
        else
            _dim "  → would remove ${#redundant_keys[@]} field(s)."; echo ""
        fi
        echo ""
        return 0
    fi

    for k in "${redundant_keys[@]}"; do
        yaml_remove_key "$user_file" "$k"
    done
    echo "  $(_green "Removed") ${#redundant_keys[@]} field(s)."

    if ! _simplify_file_has_content "$user_file"; then
        local do_delete=false
        if [[ "$auto_yes" == "true" ]]; then
            do_delete=true
        elif [[ -t 0 ]] && [[ -t 1 ]]; then
            local answer
            printf "  %s " "$(_bold "Delete empty override file? [y/N]")"
            IFS= read -r answer < /dev/tty || answer=""
            case "$answer" in
                y|Y|yes|Yes) do_delete=true ;;
                *) do_delete=false ;;
            esac
        fi
        if [[ "$do_delete" == "true" ]]; then
            rm -f "$user_file"
            echo "  $(_green "Deleted") ${user_file#"$REPO_ROOT/"}"
        else
            _dim "  Kept empty file — remove manually if desired."; echo ""
        fi
    fi
    echo ""
    return 0
}
