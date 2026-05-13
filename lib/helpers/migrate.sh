#!/usr/bin/env bash
# agentsync migrate — move legacy flat-layout payload overrides
# (.ai/src/{hooks,mcp,settings}/<tool>.<ext>) into the per-tool canonical
# layout (.ai/src/tools/<tool>/<resource>.<ext>).
#
# Optionally consolidates identical per-tool MCP overrides into the shared
# .ai/src/mcp.json.
#
# Dry-run by default. Pass --apply to persist.

_migrate_prepare_context() {
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

# Scan .ai/src/{hooks,mcp,settings} and print one "resource|tool|path|ext" per
# legacy file found. Prints nothing when layout is already clean.
_migrate_scan_legacy() {
    local root="$REPO_ROOT/.ai/src"
    local resource file base tool ext
    for resource in hooks mcp settings; do
        [[ -d "$root/$resource" ]] || continue
        for file in "$root/$resource"/*; do
            [[ -f "$file" ]] || continue
            base=$(basename "$file")
            tool="${base%.*}"
            ext="${base##*.}"
            [[ -z "$tool" ]] && continue
            [[ -z "$ext" ]] && continue
            echo "${resource}|${tool}|${file}|${ext}"
        done
    done
}

# Print a short label describing how a legacy entry will move, given
# `resource|tool|src|ext`. Outputs "src  →  dest" (relative paths).
_migrate_format_move() {
    local line="$1"
    local resource="${line%%|*}"; line="${line#*|}"
    local tool="${line%%|*}"; line="${line#*|}"
    local src="${line%%|*}"; line="${line#*|}"
    local ext="$line"
    local dest="$REPO_ROOT/.ai/src/tools/${tool}/${resource}.${ext}"
    printf '  %s  →  %s' "${src#"$REPO_ROOT/"}" "${dest#"$REPO_ROOT/"}"
}

# Can all legacy MCP files be consolidated into .ai/src/mcp.json? They must:
#   (a) exist
#   (b) have more than one file OR at least one distinct MCP file
#   (c) all be byte-identical
# Prints the canonical MCP source path on stdout when consolidation is safe.
# Returns 0 on success, 1 otherwise.
_migrate_mcp_consolidation_candidate() {
    local mcp_dir="$REPO_ROOT/.ai/src/mcp"
    [[ -d "$mcp_dir" ]] || return 1

    local -a files=()
    local f
    for f in "$mcp_dir"/*.json; do
        [[ -f "$f" ]] || continue
        files+=("$f")
    done
    [[ ${#files[@]} -ge 1 ]] || return 1

    # Shared target must not already exist; if it does, let per-tool moves
    # handle the rest — consolidation would risk clobbering user content.
    [[ -f "$REPO_ROOT/.ai/src/mcp.json" ]] && return 1

    local first="${files[0]}"
    local other
    for other in "${files[@]:1}"; do
        cmp -s "$first" "$other" || return 1
    done

    echo "$first"
    return 0
}

# Apply a single move: mkdir -p target parent, mv file, skip collision.
# Sets caller `applied_count` / `skipped_count` via name-reference-by-convention.
_migrate_move_one() {
    local line="$1"
    local resource="${line%%|*}"; line="${line#*|}"
    local tool="${line%%|*}"; line="${line#*|}"
    local src="${line%%|*}"; line="${line#*|}"
    local ext="$line"
    local dest="$REPO_ROOT/.ai/src/tools/${tool}/${resource}.${ext}"

    if [[ -f "$dest" ]]; then
        _yellow "  skipped (target already exists)"; echo " ${dest#"$REPO_ROOT/"}"
        skipped_count=$((skipped_count + 1))
        return 0
    fi

    mkdir -p "$(dirname "$dest")"
    mv "$src" "$dest"
    _green "  moved"; echo " ${src#"$REPO_ROOT/"} → ${dest#"$REPO_ROOT/"}"
    applied_count=$((applied_count + 1))
}

# Detect the pre-v0.6 monolithic layout: a sibling `.agent/` directory
# (singular, no 's') with AGENTS.md and any of workflows/, rules/, skills/.
# Returns 0 if a candidate is present, 1 otherwise.
#
# Google Antigravity uses the same `.agent/` directory for its current
# output. If antigravity is enabled, `.agent/` is live tool output, not
# legacy — never propose to remove it.
_migrate_has_legacy_agent_dir() {
    local root="$REPO_ROOT/.agent"
    [[ -d "$root" ]] || return 1

    local enabled=""
    enabled=$(list_enabled_tools) || true
    local t
    while IFS= read -r t; do
        [[ "$t" == "antigravity" ]] && return 1
    done <<< "$enabled"

    # A bare `.agent/` directory with no recognisable payload is still legacy
    # leftover — flag it so the user can decide to remove. Recognise both
    # styles: marker file present, or any nested directory exists.
    if [[ -f "$root/AGENTS.md" ]] || [[ -d "$root/workflows" ]] || \
       [[ -d "$root/rules" ]] || [[ -d "$root/skills" ]] || \
       [[ -z "$(ls -A "$root" 2>/dev/null)" ]]; then
        return 0
    fi
    # Any other non-empty content — still legacy, flag conservatively.
    return 0
}

# Remove the legacy `.agent/` directory after confirmation. Prints what was
# removed. Caller is responsible for printing surrounding context.
_migrate_remove_legacy_agent_dir() {
    local root="$REPO_ROOT/.agent"
    [[ -d "$root" ]] || return 0
    rm -rf "$root"
    _green "  removed .agent/ (pre-v0.6 layout)"; echo ""
}

# Remove now-empty legacy directories. Silent on non-empty dirs.
_migrate_cleanup_empty_dirs() {
    local root="$REPO_ROOT/.ai/src"
    local d
    for d in hooks mcp settings; do
        [[ -d "$root/$d" ]] || continue
        rmdir "$root/$d" 2>/dev/null || true
    done
}

cmd_migrate() {
    local apply=false
    local yes=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --apply)    apply=true; shift ;;
            --yes|-y)   yes=true;   shift ;;
            --help|-h)
                cat <<'USAGE'
Usage: agentsync migrate [--apply] [--yes]

  Moves legacy flat-layout overrides to the canonical per-tool layout:
    .ai/src/hooks/<tool>.<ext>    → .ai/src/tools/<tool>/hooks.<ext>
    .ai/src/mcp/<tool>.<ext>      → .ai/src/tools/<tool>/mcp.<ext>
    .ai/src/settings/<tool>.<ext> → .ai/src/tools/<tool>/settings.<ext>

  When every legacy MCP file is byte-identical, migrate offers to consolidate
  them into the shared .ai/src/mcp.json. Pass --yes to accept without prompt.

  Dry-run by default — re-run with --apply to move files.
USAGE
                return 0
                ;;
            *)
                echo "$(_red "Error"): Unknown flag: $1" >&2
                echo "Usage: agentsync migrate [--apply] [--yes]" >&2
                exit 1
                ;;
        esac
    done

    _migrate_prepare_context

    local legacy
    legacy=$(_migrate_scan_legacy)
    local has_legacy_agent_dir=false
    if _migrate_has_legacy_agent_dir; then
        has_legacy_agent_dir=true
    fi

    echo ""
    _bold "  AgentSync Migrate"; echo ""
    _dim "  $REPO_ROOT"; echo ""
    echo ""

    if [[ -z "$legacy" ]] && [[ "$has_legacy_agent_dir" != "true" ]]; then
        _green "  Nothing to migrate."; echo ""
        _dim "  No files under .ai/src/{hooks,mcp,settings}/ and no .agent/ legacy dir — already on canonical layout."; echo ""
        echo ""
        return 0
    fi

    # Handle pre-v0.6 `.agent/` removal first (independent of flat-override moves).
    if [[ "$has_legacy_agent_dir" == "true" ]]; then
        echo "  $(_bold "Legacy pre-v0.6 layout"):"
        echo "    $(_yellow ".agent/") — orphan directory from before tool-specific outputs."
        local item
        for item in "$REPO_ROOT/.agent"/*; do
            [[ -e "$item" ]] || continue
            echo "      · ${item#"$REPO_ROOT/.agent/"}"
        done
        echo ""

        if [[ "$apply" == "true" ]]; then
            local do_remove=false
            if [[ "$yes" == "true" ]]; then
                do_remove=true
            elif is_tty; then
                if prompt_confirm "Remove .agent/ (review the listing above first)?" n; then
                    do_remove=true
                fi
            else
                # Non-interactive without --yes: be conservative, do not auto-remove.
                echo "  $(_dim "(non-interactive; .agent/ left in place — re-run with --yes to remove)")"
                echo ""
            fi
            if [[ "$do_remove" == "true" ]]; then
                _migrate_remove_legacy_agent_dir
            fi
        else
            _dim "  Dry-run. Re-run with"; printf ' %s' "$(_cyan "agentsync migrate --apply")"
            _dim " to remove .agent/."; echo ""
            echo ""
        fi

        # If there's no flat-layout legacy too, we're done.
        if [[ -z "$legacy" ]]; then
            return 0
        fi
    fi

    # Separate MCP entries (candidates for consolidation) from per-tool moves.
    local -a mcp_entries=()
    local -a other_entries=()
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        case "$line" in
            mcp\|*) mcp_entries+=("$line") ;;
            *)      other_entries+=("$line") ;;
        esac
    done <<< "$legacy"

    local shared_candidate=""
    shared_candidate=$(_migrate_mcp_consolidation_candidate) || shared_candidate=""

    # Print the plan.
    echo "  $(_bold "Planned moves"):"
    local all_move_count=0
    if [[ ${#other_entries[@]} -gt 0 ]]; then
        for line in "${other_entries[@]}"; do
            _migrate_format_move "$line"; echo ""
            all_move_count=$((all_move_count + 1))
        done
    fi
    if [[ -n "$shared_candidate" ]]; then
        echo ""
        echo "  $(_bold "MCP consolidation"):"
        echo "    All ${#mcp_entries[@]} .ai/src/mcp/*.json are byte-identical — can consolidate into .ai/src/mcp.json."
        echo "    $(_dim "Source file:") ${shared_candidate#"$REPO_ROOT/"}"
    elif [[ ${#mcp_entries[@]} -gt 0 ]]; then
        # MCP files differ — migrate per-tool instead.
        for line in "${mcp_entries[@]}"; do
            _migrate_format_move "$line"; echo ""
            all_move_count=$((all_move_count + 1))
        done
    fi
    echo ""

    if [[ "$apply" != "true" ]]; then
        _dim "  Dry-run. Re-run with"; printf ' %s' "$(_cyan "agentsync migrate --apply")"
        _dim " to move files."; echo ""
        echo ""
        return 0
    fi

    # ── Apply ────────────────────────────────────────────────────────────────
    local applied_count=0
    local skipped_count=0
    local consolidated=false

    # Ask about MCP consolidation first — if declined, fall back to per-tool moves.
    if [[ -n "$shared_candidate" ]]; then
        local do_consolidate=false
        if [[ "$yes" == "true" ]]; then
            do_consolidate=true
        elif is_tty; then
            if prompt_confirm "Consolidate ${#mcp_entries[@]} identical MCP files into .ai/src/mcp.json?" y; then
                do_consolidate=true
            fi
        else
            do_consolidate=true
        fi

        if [[ "$do_consolidate" == "true" ]]; then
            cp "$shared_candidate" "$REPO_ROOT/.ai/src/mcp.json"
            for line in "${mcp_entries[@]}"; do
                local src="${line#mcp|*|}"; src="${src%%|*}"
                rm -f "$src"
                _green "  consolidated"; echo " ${src#"$REPO_ROOT/"} → .ai/src/mcp.json"
                applied_count=$((applied_count + 1))
            done
            consolidated=true
        else
            for line in "${mcp_entries[@]}"; do
                _migrate_move_one "$line"
            done
        fi
    elif [[ ${#mcp_entries[@]} -gt 0 ]]; then
        for line in "${mcp_entries[@]}"; do
            _migrate_move_one "$line"
        done
    fi

    for line in "${other_entries[@]+"${other_entries[@]}"}"; do
        _migrate_move_one "$line"
    done

    _migrate_cleanup_empty_dirs

    echo ""
    _green "  Migration complete."; echo ""
    _dim "    moved:        $applied_count"; echo ""
    if [[ $skipped_count -gt 0 ]]; then
        _yellow "    skipped:      $skipped_count (target already existed)"; echo ""
    fi
    if [[ "$consolidated" == "true" ]]; then
        _dim "    consolidated: .ai/src/mcp.json"; echo ""
    fi
    echo ""
    _dim "  Run"; printf ' %s' "$(_cyan "agentsync sync")"; _dim " to confirm outputs are unchanged."; echo ""
    echo ""
}
