#!/usr/bin/env bash
# AgentSync CLI — single entry point for all operations.
# https://github.com/yelmuratoff/agent

set -euo pipefail

# ─── Version ─────────────────────────────────────────────────────────────────
_resolve_version() {
    local source="${BASH_SOURCE[0]}"
    while [[ -L "$source" ]]; do
        local link_dir
        link_dir="$(cd "$(dirname "$source")" && pwd)"
        source="$(readlink "$source")"
        [[ "$source" != /* ]] && source="$link_dir/$source"
    done
    local script_dir
    script_dir="$(cd "$(dirname "$source")" && pwd)"
    local version_file="$script_dir/../VERSION"
    if [[ -f "$version_file" ]]; then
        read -r VERSION < "$version_file"
    else
        VERSION="0.0.0-dev"
    fi
}
_resolve_version
readonly VERSION

# ─── Load modules ────────────────────────────────────────────────────────────
_load_lib() {
    # Resolve real path of this script (follow symlinks)
    local source="${BASH_SOURCE[0]}"
    while [[ -L "$source" ]]; do
        local link_dir
        link_dir="$(cd "$(dirname "$source")" && pwd)"
        source="$(readlink "$source")"
        [[ "$source" != /* ]] && source="$link_dir/$source"
    done
    local script_dir
    script_dir="$(cd "$(dirname "$source")" && pwd)"

    # Engine root is one level up from bin/
    _AGENTSYNC_ENGINE_ROOT="$(cd "$script_dir/.." && pwd)"

    local lib_dir="$_AGENTSYNC_ENGINE_ROOT/lib/helpers"
    if [[ ! -d "$lib_dir" ]]; then
        lib_dir="${AGENTSYNC_HOME:-.}/lib/helpers"
    fi

    if [[ ! -d "$lib_dir" ]]; then
        echo "Error: Cannot find AgentSync lib directory." >&2
        exit 1
    fi

    source "$lib_dir/cli_colors.sh"
    source "$lib_dir/prompts.sh"
    source "$lib_dir/resolve.sh"
    source "$lib_dir/yaml.sh"
    source "$lib_dir/yaml_edit.sh"
    source "$lib_dir/tool_resolver.sh"
    source "$lib_dir/init.sh"
    source "$lib_dir/list.sh"
    source "$lib_dir/enable.sh"
    source "$lib_dir/customize.sh"
    source "$lib_dir/add.sh"
    source "$lib_dir/simplify.sh"
    source "$lib_dir/doctor.sh"
    source "$lib_dir/resolve_cmd.sh"
    source "$lib_dir/generate.sh"
    source "$lib_dir/snapshot.sh"
    source "$lib_dir/update.sh"
    source "$lib_dir/release.sh"
    source "$lib_dir/export.sh"
    source "$lib_dir/import.sh"
}
_load_lib

# ─── Help ────────────────────────────────────────────────────────────────────
print_usage() {
    echo ""
    _bold "  AgentSync"; echo " v${VERSION}"
    _dim  "  Sync AI agent instructions to every tool from one source."; echo ""
    echo ""
    echo "  $(_green "USAGE")"
    echo "    agentsync <command> [options]"
    echo ""
    echo "  $(_green "COMMANDS")"
    echo "    $(_cyan "init")           Create .ai/ structure in current project"
    echo "    $(_cyan "sync")           Sync instructions to all enabled tools"
    echo "    $(_cyan "check")          Verify outputs are in sync with source"
    echo "    $(_cyan "list")           Show available tools and their status"
    echo "    $(_cyan "enable")         Opt in to one or more tools"
    echo "    $(_cyan "disable")        Opt out of one or more tools"
    echo "    $(_cyan "add")            Scaffold a rule, skill, command, or subagent"
    echo "    $(_cyan "customize")      Create a per-field override for a tool"
    echo "    $(_cyan "simplify")       Remove override fields that match the base"
    echo "    $(_cyan "show")           Show effective config for a tool"
    echo "    $(_cyan "diff")           Show user overrides vs base defaults"
    echo "    $(_cyan "resolve")        Interactively reconcile overrides with base values"
    echo "    $(_cyan "doctor")         Validate setup and surface warnings"
    echo "    $(_cyan "generate")       Print a prompt to auto-generate project-specific rules"
    echo "    $(_cyan "setup-hooks")    Install git hooks for automatic sync"
    echo "    $(_cyan "export")         Bundle .ai/src/ into a shareable archive"
    echo "    $(_cyan "import")         Import config from GitHub, archive, or directory"
    echo "    $(_cyan "update")         Update AgentSync to the latest version"
    echo "    $(_cyan "upgrade-config") Re-pin agentsync_version in agent_sync.yaml"
    echo "    $(_cyan "release")        Bump version, tag, and push (maintainer)"
    echo "    $(_cyan "version")        Print version"
    echo "    $(_cyan "help")           Show this message"
    echo ""
    echo "  $(_green "SYNC OPTIONS")"
    echo "    --only <tools>    Sync only these tools (comma-separated)"
    echo "    --skip <tools>    Skip these tools (comma-separated)"
    echo "    --dry-run         Preview changes without writing"
    echo ""
    echo "  $(_green "EXAMPLES")"
    echo "    agentsync init"
    echo "    agentsync list"
    echo "    agentsync enable claude cursor"
    echo "    agentsync add rule testing"
    echo "    agentsync add skill deploy"
    echo "    agentsync customize cursor"
    echo "    agentsync simplify"
    echo "    agentsync simplify cursor --apply"
    echo "    agentsync show cursor"
    echo "    agentsync diff"
    echo "    agentsync doctor"
    echo "    agentsync resolve"
    echo "    agentsync sync"
    echo "    agentsync sync --only claude,cursor"
    echo "    agentsync sync --dry-run"
    echo "    agentsync check"
    echo "    agentsync generate"
    echo "    agentsync generate React + TypeScript + Next.js project with Prisma ORM"
    echo "    agentsync export"
    echo "    agentsync import https://github.com/user/repo"
    echo ""
    echo "  $(_green "DOCS")"
    _dim  "    https://github.com/yelmuratoff/agent"; echo ""
    echo ""
}

# ─── Engine delegation (sync, check, setup-hooks) ───────────────────────────
cmd_engine() {
    local script_name="$1"
    shift

    local system_dir=""
    system_dir=$(resolve_system_dir) || {
        echo "$(_red "Error"): Sync engine not found." >&2
        echo "" >&2
        echo "Looked in:" >&2
        echo "  1. \$AGENTSYNC_HOME/lib/" >&2
        echo "  2. Relative to agentsync script (following symlinks)" >&2
        echo "  3. $(pwd)/lib/" >&2
        echo "" >&2
        echo "Run $(_cyan "agentsync init") or install AgentSync globally:" >&2
        echo "  curl -fsSL https://raw.githubusercontent.com/$AGENTSYNC_REPO/main/install.sh | bash" >&2
        exit 1
    }

    local script_path="$system_dir/$script_name"
    if [[ ! -f "$script_path" ]]; then
        echo "$(_red "Error"): Script not found: $script_path" >&2
        exit 1
    fi

    export AGENTSYNC_REPO_ROOT="${AGENTSYNC_REPO_ROOT:-$(pwd)}"
    bash "$script_path" "$@"
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    local command="${1:-help}"

    # Update check for interactive commands
    case "$command" in
        sync|init|check|list|ls|setup-hooks|export|import|enable|disable|add|customize|simplify|show|diff|resolve|doctor|help|--help|-h)
            check_for_updates
            ;;
    esac

    case "$command" in
        init)          shift; cmd_init "$@" ;;
        sync)          shift; cmd_engine "sync.sh" "$@" ;;
        check)         shift; cmd_engine "check.sh" "$@" ;;
        setup-hooks)   shift; cmd_engine "setup_hooks.sh" "$@" ;;
        generate|gen)  shift; cmd_generate "$*" ;;
        export)        shift; cmd_export "$@" ;;
        import)        shift; cmd_import "$@" ;;
        enable)        shift; cmd_enable "$@" ;;
        disable)       shift; cmd_disable "$@" ;;
        add)           shift; cmd_add "$@" ;;
        customize)     shift; cmd_customize "$@" ;;
        simplify)      shift; cmd_simplify "$@" ;;
        show)          shift; cmd_show "$@" ;;
        diff)          shift; cmd_diff "$@" ;;
        resolve)       shift; cmd_resolve "$@" ;;
        doctor)        cmd_doctor ;;
        update)        shift; cmd_update "$@" ;;
        upgrade-config) shift; cmd_upgrade_config "$@" ;;
        release)       shift; cmd_release "$@" ;;
        list|ls)       cmd_list ;;
        version|--version|-v) echo "agentsync v${VERSION}" ;;
        help|--help|-h)       print_usage ;;
        *)
            echo "$(_red "Error"): Unknown command: $command" >&2
            echo "" >&2
            print_usage >&2
            exit 1
            ;;
    esac
}

main "$@"
