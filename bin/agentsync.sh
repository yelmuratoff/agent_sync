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
        # `read` returns 1 on EOF without trailing newline, but still assigns
        # the partial content — accept that with `|| true` to survive `set -e`.
        read -r VERSION < "$version_file" || true
        [[ -n "$VERSION" ]] || VERSION="0.0.0-dev"
    else
        VERSION="0.0.0-dev"
    fi
}
_resolve_version
readonly VERSION

# ─── Module loader ───────────────────────────────────────────────────────────
# Only cli_colors, resolve, and update are always loaded (needed by main/dispatch
# and cmd_engine). Subcommand-specific modules are sourced on demand via _need.
_AGENTSYNC_LIB_DIR=""

_need() {
    local mod flag
    for mod in "$@"; do
        flag="_AS_LOADED_${mod//[^a-zA-Z0-9_]/_}"
        [[ "${!flag:-}" == 1 ]] && continue
        # shellcheck disable=SC1090
        source "$_AGENTSYNC_LIB_DIR/$mod.sh"
        printf -v "$flag" '%s' 1
    done
}

_load_lib_core() {
    local source="${BASH_SOURCE[0]}"
    while [[ -L "$source" ]]; do
        local link_dir
        link_dir="$(cd "$(dirname "$source")" && pwd)"
        source="$(readlink "$source")"
        [[ "$source" != /* ]] && source="$link_dir/$source"
    done
    local script_dir
    script_dir="$(cd "$(dirname "$source")" && pwd)"

    _AGENTSYNC_ENGINE_ROOT="$(cd "$script_dir/.." && pwd)"

    _AGENTSYNC_LIB_DIR="$_AGENTSYNC_ENGINE_ROOT/lib/helpers"
    if [[ ! -d "$_AGENTSYNC_LIB_DIR" ]]; then
        _AGENTSYNC_LIB_DIR="${AGENTSYNC_HOME:-.}/lib/helpers"
    fi
    if [[ ! -d "$_AGENTSYNC_LIB_DIR" ]]; then
        echo "Error: Cannot find AgentSync lib directory." >&2
        exit 1
    fi

    # Always-loaded core: colour helpers for all output, resolve_system_dir for
    # cmd_engine, update.sh for AGENTSYNC_REPO + check_for_updates used in main.
    _need cli_colors resolve update
}
_load_lib_core

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
    echo "    $(_cyan "migrate")        Move legacy flat-layout overrides to per-tool dirs"
    echo "    $(_cyan "show")           Show effective config for a tool"
    echo "    $(_cyan "diff")           Show user overrides vs base defaults"
    echo "    $(_cyan "resolve")        Interactively reconcile overrides with base values"
    echo "    $(_cyan "doctor")         Validate setup and surface warnings"
    echo "    $(_cyan "dedupe")         Remove source files that duplicate a parent .ai/src/"
    echo "    $(_cyan "adopt")          Promote a manual edit in a generated file back into .ai/src/"
    echo "    $(_cyan "profile")        Manage config-home profiles (work/personal variants)"
    echo "    $(_cyan "generate")       Print a prompt to auto-generate project-specific rules"
    echo "    $(_cyan "setup-hooks")    Install git hooks for automatic sync (--pre-commit optional)"
    echo "    $(_cyan "shell-init")     Print a shell hook that auto-syncs on directory change"
    echo "    $(_cyan "export")         Bundle .ai/src/ into a shareable archive"
    echo "    $(_cyan "import")         Import config from GitHub, archive, or directory"
    echo "    $(_cyan "refresh")        Pull new template files into existing .ai/src/"
    echo "    $(_cyan "update")         Update AgentSync to the latest version"
    echo "    $(_cyan "upgrade-config") Re-pin agentsync_version in agent_sync.yaml"
    echo "    $(_cyan "release")        Bump version, tag, and push (maintainer)"
    echo "    $(_cyan "version")        Print version"
    echo "    $(_cyan "help")           Show this message"
    echo ""
    echo "  $(_green "SYNC OPTIONS")"
    echo "    --only <tools>    Sync only these tools (comma-separated)"
    echo "    --skip <tools>    Skip these tools (comma-separated)"
    echo "    --profile <name>  Sync personal tools plus the named config-home profile"
    echo "    --dry-run         Preview changes without writing"
    echo "    --force           Overwrite destination files even if they were edited manually"
    echo "    --if-stale        Sync only when source changed since the last sync (else no-op)"
    echo "    --workspace       Run sync in every .ai/ below cwd (bottom-up alphabetical)"
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
    echo "    agentsync adopt .cursor/rules/core.mdc"
    echo "    agentsync adopt --all"
    echo "    agentsync profile add hub"
    echo "    agentsync sync"
    echo "    agentsync sync --only claude,cursor"
    echo "    agentsync sync --profile hub"
    echo "    agentsync sync --dry-run"
    echo "    agentsync sync --if-stale"
    echo "    agentsync check"
    echo "    agentsync setup-hooks --pre-commit"
    echo "    eval \"\$(agentsync shell-init zsh)\"   # add to ~/.zshrc"
    echo "    agentsync generate"
    echo "    agentsync generate React + TypeScript + Next.js project with Prisma ORM"
    echo "    agentsync export"
    echo "    agentsync import https://github.com/user/repo"
    echo "    agentsync refresh"
    echo "    agentsync refresh --only rules,skills"
    echo "    agentsync refresh --dry-run"
    echo ""
    echo "  $(_green "DOCS")"
    _dim  "    https://github.com/yelmuratoff/agent"; echo ""
    echo ""
}

# ─── Workspace fan-out (sync / dedupe) ───────────────────────────────────────
# Run a per-project command across every AgentSync-managed .ai/ below the
# current directory, in bottom-up alphabetical order (deeper paths first;
# siblings sorted by LC_ALL=C). Continues on failure: collects exit codes and
# reports a summary at the end.
#
# Usage: cmd_workspace_fanout <command-label> <forward-args...>
# Currently only used by `sync --workspace`; `dedupe --workspace` is handled
# inside cmd_dedupe directly because it's a Bash-level command (no engine
# subprocess).
cmd_workspace_fanout() {
    local label="$1"; shift
    _need paths logging
    local cwd
    cwd=$(pwd)

    local -a ai_dirs=()
    local d
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        ai_dirs+=("$d")
    done < <(find_workspace_ai_dirs "$cwd")

    if [[ ${#ai_dirs[@]} -eq 0 ]]; then
        echo "$(_red "Error"): No .ai/ directories found below $(pwd)" >&2
        echo "Run $(_cyan "agentsync init") to create one, or run from a workspace root." >&2
        return 1
    fi

    echo ""
    _bold "  AgentSync workspace $label"; echo ""
    _dim  "  Found ${#ai_dirs[@]} project(s) below $(pwd)"; echo ""
    echo ""

    local max_rc=0
    local i project_root rel rc
    for ((i = 0; i < ${#ai_dirs[@]}; i++)); do
        project_root=$(cd "${ai_dirs[$i]}/.." && pwd)
        if [[ "$project_root" == "$cwd" ]]; then
            rel="."
        else
            rel="${project_root#"$cwd/"}"
        fi
        echo "  $(_cyan "→") $rel"
        if AGENTSYNC_REPO_ROOT="$project_root" cmd_engine "sync.sh" "$@"; then
            rc=0
        else
            rc=$?
            max_rc=$rc
        fi
        echo ""
    done

    if [[ $max_rc -eq 0 ]]; then
        echo "  $(_green "Workspace $label complete.") ${#ai_dirs[@]} project(s) processed."
    else
        echo "  $(_yellow "Workspace $label finished with errors.") max exit code: $max_rc"
    fi
    echo ""
    return $max_rc
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

    case "$command" in
        sync|init|check|list|ls|setup-hooks|export|import|refresh|enable|disable|add|adopt|customize|simplify|migrate|show|diff|resolve|doctor|dedupe|profile|help|--help|-h)
            check_for_updates
            ;;
    esac

    # These subcommands don't parse their own --help; show the top-level usage
    # instead of mis-reading -h/--help as a positional argument.
    case "$command" in
        check|doctor|list|ls|show|diff|disable|resolve)
            case "${2:-}" in
                --help|-h) print_usage; exit 0 ;;
            esac
            ;;
    esac

    case "$command" in
        init)          _need prompts yaml tool_resolver template_manifest paths init; shift; cmd_init "$@" ;;
        sync)
            shift
            # --workspace fan-out: run sync in every .ai/ below cwd before
            # delegating to the engine. Any other args (--only, --dry-run,
            # ...) are forwarded to each per-project sync call.
            local _sync_workspace=false _sync_forward=()
            local _a
            for _a in "$@"; do
                if [[ "$_a" == "--workspace" ]]; then
                    _sync_workspace=true
                else
                    _sync_forward+=("$_a")
                fi
            done
            if [[ "$_sync_workspace" == "true" ]]; then
                cmd_workspace_fanout "sync" "${_sync_forward[@]+"${_sync_forward[@]}"}"
            else
                cmd_engine "sync.sh" "$@"
            fi
            ;;
        check)         shift; cmd_engine "check.sh" "$@" ;;
        setup-hooks)   shift; cmd_engine "setup_hooks.sh" "$@" ;;
        shell-init)    _need logging shell_init;                      shift; cmd_shell_init "$@" ;;
        generate|gen)  _need prompts generate;                         shift; cmd_generate "$*" ;;
        export)        _need yaml export;                              shift; cmd_export "$@" ;;
        import)        _need import;                                   shift; cmd_import "$@" ;;
        refresh)       _need yaml export prompts template_manifest refresh; shift; cmd_refresh "$@" ;;
        enable)        _need prompts yaml yaml_edit tool_resolver edit_paths enable; shift; cmd_enable "$@" ;;
        disable)       _need yaml yaml_edit tool_resolver enable;      shift; cmd_disable "$@" ;;
        add)           _need add;                                      shift; cmd_add "$@" ;;
        customize)     _need yaml yaml_edit tool_resolver customize;   shift; cmd_customize "$@" ;;
        simplify)      _need yaml yaml_edit tool_resolver customize simplify;   shift; cmd_simplify "$@" ;;
        migrate)       _need prompts yaml tool_resolver migrate;     shift; cmd_migrate "$@" ;;
        show)          _need yaml yaml_edit tool_resolver snapshot customize;   shift; cmd_show "$@" ;;
        diff)          _need yaml yaml_edit tool_resolver snapshot customize;   shift; cmd_diff "$@" ;;
        resolve)       _need yaml yaml_edit tool_resolver snapshot customize resolve_cmd; shift; cmd_resolve "$@" ;;
        doctor)        _need yaml tool_resolver edit_paths doctor;     cmd_doctor ;;
        dedupe)        _need yaml yaml_edit prompts paths template_manifest dedupe; shift; cmd_dedupe "$@" ;;
        adopt)         _need yaml tool_resolver paths logging filters file_ops prompts manifest cli_colors adopt; shift; cmd_adopt "$@" ;;
        profile)       _need yaml yaml_edit tool_resolver profiles paths logging prompts profile; shift; cmd_profile "$@" ;;
        update)        _need yaml snapshot;                            shift; cmd_update "$@" ;;
        upgrade-config) _need prompts yaml tool_resolver init;         shift; cmd_upgrade_config "$@" ;;
        release)       _need release;                                  shift; cmd_release "$@" ;;
        list|ls)       _need yaml tool_resolver customize list;        cmd_list ;;
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
