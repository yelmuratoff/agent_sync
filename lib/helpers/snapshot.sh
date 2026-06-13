#!/usr/bin/env bash
# Snapshot-based conflict detection for `agentsync update`.
#
# Flow:
#   1. `snapshot_save`   — pre-swap, copy the install-dir tool catalog to a side dir.
#   2. `git pull`        — install-dir is now at the new release.
#   3. `snapshot_diff`   — compare saved catalog against current; emit changed fields.
#   4. `snapshot_find_conflicts` — intersect with project overrides.
#   5. `snapshot_write_pending_resolutions` — persist the queue for `agentsync resolve`.
#
# Zero external deps. Reuses `parse_yaml_value` for both sides so quoting /
# multi-line quirks are handled identically.

# Well-known overridable keys — kept in sync with `_resolve_keys` in resolve_cmd.sh
# and the `keys=(...)` arrays in customize.sh. Duplicated here so the snapshot
# module has no dependency on the resolve command.
_snapshot_keys() {
    cat <<'KEYS'
name
enabled
targets.agents.dest
targets.rules.dest
targets.rules.extension
targets.rules.header
targets.rules.scoped_header
targets.rules.append_imports
targets.rules.merge_to_file
targets.rules.inline_into_agents
targets.rules.prepend_agents
targets.skills.dest
targets.skills.inline_into_agents
targets.commands.dest
targets.commands.format
targets.commands.as_skills
targets.commands.inline_into_agents
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

# List base-tool names in a catalog directory (sorted, no _TEMPLATE).
_snapshot_list_tools() {
    local catalog_dir="$1"
    [[ -d "$catalog_dir" ]] || return 0
    local f base
    for f in "$catalog_dir"/*.yaml; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f" .yaml)
        [[ "$base" == _* ]] && continue
        echo "$base"
    done | sort -u
}

# TAB character for delimited records — bash literal must use $'\t'.
_snapshot_tab() { printf '\t'; }

# ── Save ──────────────────────────────────────────────────────────────────────

# Copy install-dir tool catalog into <snapshot_dir>/tools/. Safe to call over
# an existing snapshot — caller is responsible for cleanup policy.
# Usage: snapshot_save <install_dir> <snapshot_dir>
snapshot_save() {
    local install_dir="$1"
    local snapshot_dir="$2"

    # Refuse to run with an unspecified target: an empty snapshot_dir would turn
    # the rm -rf below into a delete of a bare "/tools" path.
    if [[ -z "$install_dir" ]] || [[ -z "$snapshot_dir" ]]; then
        return 1
    fi

    local src="$install_dir/lib/templates/tools"
    local dst="$snapshot_dir/tools"

    if [[ ! -d "$src" ]]; then
        return 1
    fi

    rm -rf "$dst"
    mkdir -p "$dst"

    local f
    for f in "$src"/*.yaml; do
        [[ -f "$f" ]] || continue
        cp "$f" "$dst/"
    done
    return 0
}

# ── Diff ──────────────────────────────────────────────────────────────────────

# Compare catalog in <snapshot_dir>/tools/ against <install_dir>/lib/templates/tools/.
# Emits one TSV line per changed field:
#   tool<TAB>field<TAB>old_value<TAB>new_value
# Exit 0 always. Empty output = no changes.
# Usage: snapshot_diff <snapshot_dir> <install_dir>
snapshot_diff() {
    local snapshot_dir="$1"
    local install_dir="$2"

    local old_catalog="$snapshot_dir/tools"
    local new_catalog="$install_dir/lib/templates/tools"

    [[ -d "$old_catalog" ]] || return 0
    [[ -d "$new_catalog" ]] || return 0

    local tools_old tools_new all_tools
    tools_old=$(_snapshot_list_tools "$old_catalog")
    tools_new=$(_snapshot_list_tools "$new_catalog")
    all_tools=$(printf '%s\n%s\n' "$tools_old" "$tools_new" | sort -u | sed '/^$/d')

    local tool key old_file new_file old_val new_val tab
    tab=$(_snapshot_tab)
    while IFS= read -r tool; do
        [[ -z "$tool" ]] && continue
        old_file="$old_catalog/${tool}.yaml"
        new_file="$new_catalog/${tool}.yaml"

        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            old_val=""
            new_val=""
            [[ -f "$old_file" ]] && old_val=$(parse_yaml_value "$old_file" "$key")
            [[ -f "$new_file" ]] && new_val=$(parse_yaml_value "$new_file" "$key")

            if [[ "$old_val" != "$new_val" ]]; then
                printf '%s%s%s%s%s%s%s\n' \
                    "$tool" "$tab" "$key" "$tab" "$old_val" "$tab" "$new_val"
            fi
        done < <(_snapshot_keys)
    done <<< "$all_tools"
    return 0
}

# ── Correlate with project overrides ──────────────────────────────────────────

# Read a <diff_output> TSV stream on stdin and emit only lines where the
# project in <project_dir> has a user override for that tool.field.
# Output TSV: tool<TAB>field<TAB>base_before<TAB>base_after<TAB>your_override
# Usage: snapshot_find_conflicts <project_dir> < diff_output
snapshot_find_conflicts() {
    local project_dir="$1"
    local user_tools_dir="$project_dir/.ai/src/tools"

    [[ -d "$user_tools_dir" ]] || return 0

    local tab
    tab=$(_snapshot_tab)

    local line tool field base_before base_after user_file user_val
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS=$'\t' read -r tool field base_before base_after <<< "$line"
        user_file="$user_tools_dir/${tool}.yaml"
        [[ -f "$user_file" ]] || continue
        user_val=$(parse_yaml_value "$user_file" "$field")
        [[ -z "$user_val" ]] && continue
        printf '%s%s%s%s%s%s%s%s%s\n' \
            "$tool" "$tab" "$field" "$tab" \
            "$base_before" "$tab" "$base_after" "$tab" "$user_val"
    done
    return 0
}

# ── Emit pending-resolutions YAML ─────────────────────────────────────────────

# YAML-escape a scalar for a double-quoted string: backslash, double-quote,
# literal newlines, and tabs. Output is a double-quoted YAML scalar.
_snapshot_yaml_quote() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    # Keep newlines as literal \n for single-line readability.
    s="${s//$'\n'/\\n}"
    printf '"%s"' "$s"
}

# Write .ai/.pending-resolutions.yaml from TSV conflicts on stdin.
# Usage: snapshot_write_pending_resolutions <project_dir> <from_version> <to_version>
# Stdin lines: tool<TAB>field<TAB>base_before<TAB>base_after<TAB>your_override
snapshot_write_pending_resolutions() {
    local project_dir="$1"
    local from_version="$2"
    local to_version="$3"

    local ai_dir="$project_dir/.ai"
    [[ -d "$ai_dir" ]] || return 0
    local dest="$ai_dir/.pending-resolutions.yaml"

    local tmp
    tmp=$(mktemp "${dest}.XXXXXX") || return 1

    local today
    today=$(date -u +%Y-%m-%d)

    {
        echo "# AgentSync — pending upstream resolutions from \`agentsync update\`."
        echo "# Run \`agentsync resolve\` to walk these fields interactively."
        echo "# Remove this file once you've reviewed every entry."
        echo ""
        echo "schema: 1"
        echo "generated_on: \"$today\""
        echo "from_version: \"$from_version\""
        echo "to_version: \"$to_version\""
        echo "conflicts:"

        local line tool field base_before base_after your_override any=false
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            IFS=$'\t' read -r tool field base_before base_after your_override <<< "$line"
            any=true
            printf '  - tool: "%s"\n' "$tool"
            printf '    field: "%s"\n' "$field"
            printf '    base_before: %s\n' "$(_snapshot_yaml_quote "$base_before")"
            printf '    base_after: %s\n'  "$(_snapshot_yaml_quote "$base_after")"
            printf '    your_override: %s\n' "$(_snapshot_yaml_quote "$your_override")"
        done

        if [[ "$any" == "false" ]]; then
            # Should not happen — caller checks before invoking — but keep valid YAML.
            echo "  []"
        fi
    } > "$tmp"

    mv "$tmp" "$dest"
    return 0
}

# ── Read pending-resolutions (used by cmd_resolve) ────────────────────────────

# Print TSV "tool<TAB>field" pairs from an existing pending-resolutions file.
# Safe to call when the file is missing — prints nothing, returns 0.
snapshot_read_pending_pairs() {
    local project_dir="$1"
    local src="$project_dir/.ai/.pending-resolutions.yaml"
    [[ -f "$src" ]] || return 0

    local tab
    tab=$(_snapshot_tab)

    local in_conflicts=false current_tool="" current_field=""
    local line stripped
    while IFS= read -r line || [[ -n "$line" ]]; do
        stripped="${line#"${line%%[![:space:]]*}"}"
        if [[ "$stripped" == "conflicts:" ]] || [[ "$stripped" == conflicts:* ]]; then
            in_conflicts=true
            continue
        fi
        [[ "$in_conflicts" == "true" ]] || continue
        # Stop if a non-indented key resumes root-level scope.
        if [[ -n "$stripped" ]] && [[ "$line" == "${stripped}" ]] && [[ "$stripped" != -* ]]; then
            break
        fi

        if [[ "$stripped" == "- tool:"* ]]; then
            # Flush previous pair if complete.
            if [[ -n "$current_tool" ]] && [[ -n "$current_field" ]]; then
                printf '%s%s%s\n' "$current_tool" "$tab" "$current_field"
            fi
            current_tool="${stripped#"- tool:"}"
            current_tool="${current_tool#"${current_tool%%[![:space:]]*}"}"
            current_tool="${current_tool%\"}"; current_tool="${current_tool#\"}"
            current_field=""
        elif [[ "$stripped" == "field:"* ]]; then
            current_field="${stripped#"field:"}"
            current_field="${current_field#"${current_field%%[![:space:]]*}"}"
            current_field="${current_field%\"}"; current_field="${current_field#\"}"
        fi
    done < "$src"

    if [[ -n "$current_tool" ]] && [[ -n "$current_field" ]]; then
        printf '%s%s%s\n' "$current_tool" "$tab" "$current_field"
    fi
    return 0
}

# Remove the pending-resolutions file. Safe when missing.
snapshot_clear_pending() {
    local project_dir="$1"
    rm -f "$project_dir/.ai/.pending-resolutions.yaml"
}
