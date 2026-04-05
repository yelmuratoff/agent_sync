#!/usr/bin/env bash
# agentsync export — bundle source files into a shareable archive.

# Shared target names used by both export and import.
# Order matches init.sh directory creation.
_BUNDLE_FILE_TARGETS=("AGENTS.md")
_BUNDLE_DIR_TARGETS=("rules" "skills" "commands" "agents" "settings" "mcp" "hooks" "tools")
_BUNDLE_CONFIG="agent_sync.yaml"

# ── Source path resolution ───────────────────────────────────────────────────

# Resolve all source paths respecting agent_sync.yaml overrides and layout auto-detection.
# Sets: _SRC_AGENTS, _SRC_RULES, _SRC_SKILLS, _SRC_COMMANDS, _SRC_SUBAGENTS,
#        _SRC_SETTINGS, _SRC_MCP, _SRC_HOOKS, _SRC_TOOLS
# Also sets _SRC_BASE (detected base dir, e.g. ".ai/src" or ".ai")
_resolve_source_paths() {
    local repo_root="$1"
    local config="$repo_root/$_BUNDLE_CONFIG"

    # Auto-detect base layout
    if [[ -d "$repo_root/.ai/src" ]]; then
        _SRC_BASE=".ai/src"
    elif [[ -d "$repo_root/.ai" ]]; then
        _SRC_BASE=".ai"
    else
        _SRC_BASE=""
    fi

    # Defaults from auto-detection
    _SRC_AGENTS=""
    [[ -f "$repo_root/$_SRC_BASE/AGENTS.md" ]] && _SRC_AGENTS="$_SRC_BASE/AGENTS.md"

    _SRC_RULES=""
    _SRC_SKILLS=""
    _SRC_COMMANDS=""
    # Note: "agents" subdir = subagents (not the AGENTS.md file)
    _SRC_AGENTS_DIR=""
    _SRC_SETTINGS=""
    _SRC_MCP=""
    _SRC_HOOKS=""
    _SRC_TOOLS=""

    local dir_name
    for dir_name in rules skills commands agents settings mcp hooks tools; do
        if [[ -d "$repo_root/$_SRC_BASE/$dir_name" ]]; then
            case "$dir_name" in
                rules)    _SRC_RULES="$_SRC_BASE/$dir_name" ;;
                skills)   _SRC_SKILLS="$_SRC_BASE/$dir_name" ;;
                commands) _SRC_COMMANDS="$_SRC_BASE/$dir_name" ;;
                agents)   _SRC_AGENTS_DIR="$_SRC_BASE/$dir_name" ;;
                settings) _SRC_SETTINGS="$_SRC_BASE/$dir_name" ;;
                mcp)      _SRC_MCP="$_SRC_BASE/$dir_name" ;;
                hooks)    _SRC_HOOKS="$_SRC_BASE/$dir_name" ;;
                tools)    _SRC_TOOLS="$_SRC_BASE/$dir_name" ;;
            esac
        fi
    done

    # Override from agent_sync.yaml if present
    if [[ -f "$config" ]]; then
        local override
        override=$(parse_yaml_value "$config" "source.agents")
        [[ -n "$override" ]] && _SRC_AGENTS="$override"

        override=$(parse_yaml_value "$config" "source.rules")
        [[ -n "$override" ]] && _SRC_RULES="$override"

        override=$(parse_yaml_value "$config" "source.skills")
        [[ -n "$override" ]] && _SRC_SKILLS="$override"

        override=$(parse_yaml_value "$config" "source.commands")
        [[ -n "$override" ]] && _SRC_COMMANDS="$override"

        override=$(parse_yaml_value "$config" "source.subagents")
        [[ -n "$override" ]] && _SRC_AGENTS_DIR="$override"

        override=$(parse_yaml_value "$config" "source.tools")
        [[ -n "$override" ]] && _SRC_TOOLS="$override"
    fi
}

# Count files recursively in a directory (portable).
_count_files_recursive() {
    local dir="$1"
    local count=0
    while IFS= read -r -d '' _; do
        count=$((count + 1))
    done < <(find "$dir" -type f -print0 2>/dev/null)
    echo "$count"
}

# ── Export command ───────────────────────────────────────────────────────────

cmd_export() {
    local repo_root="${AGENTSYNC_REPO_ROOT:-$(pwd)}"
    local output=""
    local dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output|-o)
                [[ $# -lt 2 ]] && { echo "$(_red "Error"): --output requires a path" >&2; return 1; }
                output="$2"; shift 2 ;;
            --dry-run)   dry_run=true; shift ;;
            --help|-h)   _export_usage; return 0 ;;
            *)
                echo "$(_red "Error"): Unknown option: $1" >&2
                _export_usage >&2
                return 1
                ;;
        esac
    done

    _resolve_source_paths "$repo_root"

    if [[ -z "$_SRC_BASE" ]]; then
        echo "$(_red "Error"): No .ai/ directory found in $repo_root" >&2
        echo "Run $(_cyan "agentsync init") first." >&2
        return 1
    fi

    [[ -z "$output" ]] && output="$repo_root/agentsync-bundle.tar.gz"

    echo ""
    _bold "  AgentSync Export"; echo ""
    echo ""

    # Collect items to bundle (relative paths from repo_root)
    local items=()
    local item_labels=()

    # Agent identity file
    if [[ -n "$_SRC_AGENTS" ]] && [[ -f "$repo_root/$_SRC_AGENTS" ]]; then
        items+=("$_SRC_AGENTS")
        item_labels+=("$(basename "$_SRC_AGENTS")")
    fi

    # Directory targets — map names to resolved source paths
    local _dir_pairs=(
        "rules:$_SRC_RULES"
        "skills:$_SRC_SKILLS"
        "commands:$_SRC_COMMANDS"
        "agents:$_SRC_AGENTS_DIR"
        "settings:$_SRC_SETTINGS"
        "mcp:$_SRC_MCP"
        "hooks:$_SRC_HOOKS"
        "tools:$_SRC_TOOLS"
    )
    local _pair
    for _pair in "${_dir_pairs[@]}"; do
        local dir_label="${_pair%%:*}"
        local src_path="${_pair#*:}"
        [[ -z "$src_path" ]] && continue
        [[ -d "$repo_root/$src_path" ]] || continue

        local count
        count=$(_count_files_recursive "$repo_root/$src_path")
        if (( count > 0 )); then
            items+=("$src_path")
            item_labels+=("$dir_label/ ($count files)")
        fi
    done

    # Project config
    if [[ -f "$repo_root/$_BUNDLE_CONFIG" ]]; then
        items+=("$_BUNDLE_CONFIG")
        item_labels+=("$_BUNDLE_CONFIG")
    fi

    if [[ ${#items[@]} -eq 0 ]]; then
        echo "  $(_yellow "Nothing to export") — source directories are empty."
        echo ""
        return 0
    fi

    echo "  $(_green "Contents:")"
    local label
    for label in "${item_labels[@]}"; do
        echo "    $(_dim "•") $label"
    done
    echo ""

    if [[ "$dry_run" == "true" ]]; then
        echo "  $(_yellow "Dry run") — no files written."
        echo "  Would create: $(_cyan "$output")"
        echo ""
        return 0
    fi

    (cd "$repo_root" && tar -czf "$output" "${items[@]}") || {
        echo "  $(_red "Error"): Failed to create archive." >&2
        return 1
    }

    local size
    if [[ "$(uname)" == "Darwin" ]]; then
        size=$(stat -f%z "$output" 2>/dev/null || echo "?")
    else
        size=$(stat -c%s "$output" 2>/dev/null || echo "?")
    fi

    local human_size="$size B"
    if [[ "$size" =~ ^[0-9]+$ ]]; then
        if (( size >= 1048576 )); then
            human_size="$(( size / 1048576 )) MB"
        elif (( size >= 1024 )); then
            human_size="$(( size / 1024 )) KB"
        fi
    fi

    echo "  $(_green "Exported!") → $(_cyan "$output") ($human_size)"
    echo ""
    echo "  Share this file and import with:"
    echo "    $(_cyan "agentsync import") $(_dim "$(basename "$output")")"
    echo ""
}

_export_usage() {
    echo ""
    echo "  $(_bold "agentsync export") — bundle source files into a shareable archive"
    echo ""
    echo "  $(_green "USAGE")"
    echo "    agentsync export [options]"
    echo ""
    echo "  $(_green "OPTIONS")"
    echo "    --output, -o <path>   Output file path (default: ./agentsync-bundle.tar.gz)"
    echo "    --dry-run             Preview what would be exported"
    echo "    --help, -h            Show this message"
    echo ""
    echo "  $(_green "EXAMPLES")"
    echo "    agentsync export"
    echo "    agentsync export -o my-config.tar.gz"
    echo "    agentsync export --dry-run"
    echo ""
}
