#!/usr/bin/env bash
# Shared helper for describing where a user can edit a tool's payload
# overrides. Callers (enable, doctor, any future `show --resources`) pick the
# formatter; the resolution logic lives here.

# Emit TSV rows for <tool>'s editable payloads. One row per resource
# (settings, hooks, mcp). Silent when the tool has no base templates at all.
#
# Format:  <resource>\t<state>\t<value>
#
# States:
#   override        — per-tool override file exists at <value> (path)
#   shared          — MCP: shared .ai/src/mcp.json exists at <value> (path)
#   customize-hint  — no override yet; <value> is the `customize` command
#   shared-hint     — MCP only; shared file not configured; <value> is the `add mcp` command
tool_edit_paths_rows() {
    local tool_name="$1"

    local resource base user_path
    for resource in settings hooks; do
        base=$(_find_base_payload "$resource" "$tool_name")
        [[ -z "$base" ]] && continue
        user_path=$(_payload_override_path "$tool_name" "$resource")
        if [[ -n "$user_path" ]] && [[ -f "$user_path" ]]; then
            printf '%s\t%s\t%s\n' "$resource" "override" "${user_path#"$REPO_ROOT/"}"
        else
            printf '%s\t%s\tagentsync customize %s %s\n' \
                "$resource" "customize-hint" "$tool_name" "$resource"
        fi
    done

    # MCP resolves through the shared source when per-tool override is absent.
    local mcp_base
    mcp_base=$(_find_base_payload mcp "$tool_name")
    [[ -z "$mcp_base" ]] && return 0

    local per_tool_mcp
    per_tool_mcp=$(_payload_override_path "$tool_name" mcp)
    if [[ -n "$per_tool_mcp" ]] && [[ -f "$per_tool_mcp" ]]; then
        printf '%s\t%s\t%s\n' "mcp" "override" "${per_tool_mcp#"$REPO_ROOT/"}"
        return 0
    fi

    local shared
    shared=$(shared_mcp_path)
    if [[ -f "$shared" ]]; then
        printf '%s\t%s\t%s\n' "mcp" "shared" "${shared#"$REPO_ROOT/"}"
    else
        printf '%s\t%s\tagentsync add mcp <server>\n' "mcp" "shared-hint"
    fi
}

# Block formatter used by `enable` — inline list of Edit/Hint rows under a
# bold tool-name heading, 4-space indent.
print_tool_edit_paths_block() {
    local tool_name="$1"
    local rows
    rows=$(tool_edit_paths_rows "$tool_name")
    [[ -z "$rows" ]] && return 0

    local display
    display=$(tool_display_name "$tool_name")

    echo ""
    _bold "  $display"; echo ""

    local resource state value
    while IFS=$'\t' read -r resource state value; do
        [[ -z "$resource" ]] && continue
        case "$state" in
            override)
                printf "    Edit %-9s %s\n" "${resource}:" "$value"
                ;;
            shared)
                printf "    Edit %-9s %s  %s\n" "mcp:" "$value" "$(_dim "(shared)")"
                ;;
            customize-hint)
                local label
                case "$resource" in
                    settings) label="Settings:" ;;
                    hooks)    label="Hooks:" ;;
                    *)        label="${resource}:" ;;
                esac
                printf "    %-14s %s\n" "$label" "$(_dim "$value")"
                ;;
            shared-hint)
                printf "    %-14s %s\n" "MCP:" "$(_dim "$value  (shared — not yet configured)")"
                ;;
        esac
    done <<< "$rows"
}

# Checklist formatter used by `doctor` — indented further, glyphs per state.
print_tool_edit_paths_checklist() {
    local tool_name="$1"
    local rows
    rows=$(tool_edit_paths_rows "$tool_name")
    [[ -z "$rows" ]] && return 0

    local display
    display=$(tool_display_name "$tool_name")
    echo "      $(_bold "$display")"

    local resource state value glyph render
    while IFS=$'\t' read -r resource state value; do
        [[ -z "$resource" ]] && continue
        case "$state" in
            override|shared)
                glyph="$(_green "✓")"
                if [[ "$state" == "shared" ]]; then
                    render="$value $(_dim "(shared)")"
                else
                    render="$value"
                fi
                ;;
            customize-hint|shared-hint)
                glyph="$(_dim "·")"
                if [[ "$state" == "shared-hint" ]]; then
                    render="$(_dim "$value (shared — not yet configured)")"
                else
                    render="$(_dim "$value")"
                fi
                ;;
            *) continue ;;
        esac
        printf "          %s  %-10s %s\n" "$glyph" "$resource" "$render"
    done <<< "$rows"
}
