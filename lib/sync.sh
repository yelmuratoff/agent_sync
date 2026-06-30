#!/usr/bin/env bash
# chmod +x lib/sync.sh
# Cross-platform AgentSync Config Sync Script
# Works in Git Bash on Windows and Unix/macOS

set -euo pipefail

# Script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="${AGENTSYNC_REPO_ROOT:-$DEFAULT_REPO_ROOT}"

if [[ ! -d "$REPO_ROOT" ]]; then
    echo "Error: Repository root not found: $REPO_ROOT" >&2
    exit 1
fi

REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
REPO_ROOT_CANONICAL="$(cd -P "$REPO_ROOT" && pwd)"
export REPO_ROOT_CANONICAL DEFAULT_REPO_ROOT

# Source helper libraries
# shellcheck source=helpers/logging.sh
source "$SCRIPT_DIR/helpers/logging.sh"
# shellcheck source=helpers/yaml.sh
source "$SCRIPT_DIR/helpers/yaml.sh"
# shellcheck source=helpers/paths.sh
source "$SCRIPT_DIR/helpers/paths.sh"
# shellcheck source=helpers/filters.sh
source "$SCRIPT_DIR/helpers/filters.sh"
# shellcheck source=helpers/file_ops.sh
source "$SCRIPT_DIR/helpers/file_ops.sh"
# shellcheck source=helpers/rule_operations.sh
source "$SCRIPT_DIR/helpers/rule_operations.sh"
# shellcheck source=helpers/format_conversion.sh
source "$SCRIPT_DIR/helpers/format_conversion.sh"
# shellcheck source=helpers/gitignore.sh
source "$SCRIPT_DIR/helpers/gitignore.sh"
# shellcheck source=helpers/tool_resolver.sh
source "$SCRIPT_DIR/helpers/tool_resolver.sh"
# shellcheck source=helpers/manifest.sh
source "$SCRIPT_DIR/helpers/manifest.sh"
# shellcheck source=helpers/shared.sh
source "$SCRIPT_DIR/helpers/shared.sh"
# shellcheck source=helpers/profiles.sh
source "$SCRIPT_DIR/helpers/profiles.sh"

# Tool outputs are written as siblings of `.ai/`. A run rooted inside the
# `.ai/` tree would nest generated files under the source dir, so refuse and
# point the user at the project root (the parent of `.ai/`).
_project_root_above_ai=""
if _project_root_above_ai=$(ai_dir_enclosing_root "$REPO_ROOT"); then
    log_error "Refusing to sync from inside the .ai/ directory: $REPO_ROOT"
    log_info "Run agentsync from the project root (the parent of .ai/):"
    log_info "  cd \"$_project_root_above_ai\" && agentsync sync"
    exit 2
fi

# Global variables
DRY_RUN="false"
FORCE_SYNC="false"
IF_STALE="false"
ONLY_TOOLS=""
SKIP_TOOLS=""
SELECTED_PROFILE=""
SKIP_POST_SYNC="${AGENTSYNC_SKIP_POST_SYNC:-false}"
ALLOW_POST_SYNC="${AGENTSYNC_ALLOW_POST_SYNC:-false}"
SYNCED_COUNT=0
SKIPPED_COUNT=0
TOTAL_COUNT=0
# Gates sync_may_prune: pruning is allowed only on a real sync run (manifest
# loaded), never on a standalone/primitive helper call.
SYNC_MANIFEST_ACTIVE="false"
SYNC_PRESERVED_COUNT=0
PROJECT_CONFIG_PATH=""
SOURCE_AGENTS=""
SOURCE_RULES=""
SOURCE_SKILLS=""
# SOURCE_TOOLS is retained for backward compatibility with config.yaml; tool
# YAMLs now resolve via tool_resolver.sh (base + .ai/src/tools overrides).
# shellcheck disable=SC2034
SOURCE_TOOLS=""
SOURCE_COMMANDS=""
SOURCE_SUBAGENTS=""
# DEFAULT_ENABLED is kept for legacy config compatibility; tool enablement is now
# driven by tools.enabled in agent_sync.yaml (see tool_resolver.sh).
# shellcheck disable=SC2034
DEFAULT_ENABLED="false"
DEFAULT_CLEANUP="true"
UPDATE_GITIGNORE="true"

# Paths claimed by enabled tools — cleanup must not delete these
declare -a ENABLED_DEST_PATHS=()
# Repo-relative dest paths fed to .gitignore (dirs carry a trailing slash)
declare -a GENERATED_GITIGNORE_PATHS=()

# Personal/base SOURCE_* snapshot + base src dir for the profile passes (set by
# _snapshot_base_sources, read by _run_profile_passes).
BASE_SOURCE_AGENTS=""
BASE_SOURCE_RULES=""
BASE_SOURCE_SKILLS=""
BASE_SOURCE_COMMANDS=""
BASE_SOURCE_SUBAGENTS=""
PROFILE_BASE_SRC=""
# Tool catalog + profiles selected for this run (set by _build_tool_catalog).
declare -a ALL_TOOLS=()
declare -a PROFILES_TO_SYNC=()

# Usage information
usage() {
    cat << EOF
AgentSync Config Sync Script

Usage: $(basename "$0") [OPTIONS]

Options:
  --only <tools>    Sync only specified tools (comma-separated)
  --skip <tools>    Skip specified tools (comma-separated)
  --profile <name>  Also sync this profile (default: personal + active profiles)
  --dry-run         Show what would be copied without making changes
  --force           Overwrite destination files even if they were edited manually
  --if-stale        Sync only when source changed since the last sync (else no-op)
  --help            Show this help message
EOF
}

# Resolve project config path
resolve_project_config_path() {
    local config_env="${AGENTSYNC_CONFIG_PATH:-}"
    if [[ -n "$config_env" ]]; then
        local env_path="$config_env"
        if [[ "$env_path" != /* ]]; then
            env_path="$REPO_ROOT/$env_path"
        fi

        if [[ -f "$env_path" ]]; then
            PROJECT_CONFIG_PATH="$env_path"
            return 0
        fi
        log_warning "AGENTSYNC_CONFIG_PATH is set but file not found: $env_path"
    fi

    local project_config="$REPO_ROOT/.ai/agent_sync.yaml"
    if [[ -f "$project_config" ]]; then
        PROJECT_CONFIG_PATH="$project_config"
        return 0
    fi

    local legacy_config="$REPO_ROOT/agent_sync.yaml"
    if [[ -f "$legacy_config" ]]; then
        PROJECT_CONFIG_PATH="$legacy_config"
    fi
}

# Resolve source path from project config (supports both root keys and source.* keys)
resolve_source_override() {
    local key="$1"
    if [[ -z "$PROJECT_CONFIG_PATH" ]]; then
        echo ""
        return 0
    fi

    local nested direct
    nested=$(parse_yaml_value "$PROJECT_CONFIG_PATH" "source.$key") || true
    if [[ -n "$nested" ]]; then
        echo "$nested"
        return 0
    fi

    direct=$(parse_yaml_value "$PROJECT_CONFIG_PATH" "$key") || true
    echo "$direct"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --only)
                if [[ $# -lt 2 ]] || [[ "${2:-}" == --* ]]; then
                    log_error "Option --only requires a comma-separated value"
                    usage
                    exit 1
                fi
                ONLY_TOOLS="$2"
                shift 2
                ;;
            --skip)
                if [[ $# -lt 2 ]] || [[ "${2:-}" == --* ]]; then
                    log_error "Option --skip requires a comma-separated value"
                    usage
                    exit 1
                fi
                SKIP_TOOLS="$2"
                shift 2
                ;;
            --profile)
                if [[ $# -lt 2 ]] || [[ "${2:-}" == --* ]]; then
                    log_error "Option --profile requires a profile name"
                    usage
                    exit 1
                fi
                SELECTED_PROFILE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            --force)
                FORCE_SYNC="true"
                shift
                ;;
            --if-stale)
                IF_STALE="true"
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

should_sync_tool() {
    local tool_name="$1"
    if [[ -n "$ONLY_TOOLS" ]]; then
        if [[ ! ",$ONLY_TOOLS," == *",$tool_name,"* ]]; then
            return 1
        fi
    fi
    if [[ -n "$SKIP_TOOLS" ]]; then
        if [[ ",$SKIP_TOOLS," == *",$tool_name,"* ]]; then
            return 1
        fi
    fi
    return 0
}

run_post_sync_hook() {
    local tool_name="$1"
    local post_sync_cmd="$2"

    if [[ -z "$post_sync_cmd" ]]; then
        return 0
    fi

    if [[ "$SKIP_POST_SYNC" == "true" ]]; then
        log_info "Skipping post-sync hook for $tool_name (AGENTSYNC_SKIP_POST_SYNC=true)"
        return 0
    fi

    if [[ "$ALLOW_POST_SYNC" != "true" ]]; then
        log_warning "Skipping post-sync hook for $tool_name (set AGENTSYNC_ALLOW_POST_SYNC=true to enable)"
        return 0
    fi

    log_info "Running post-sync hook: $post_sync_cmd"
    if ! (cd "$REPO_ROOT" && bash -lc "$post_sync_cmd"); then
        log_warning "Post-sync hook failed"
        return 1
    fi

    return 0
}

is_path_protected() {
    local path="$1"
    [[ ${#ENABLED_DEST_PATHS[@]} -eq 0 ]] && return 1
    local p
    for p in "${ENABLED_DEST_PATHS[@]}"; do
        [[ "$p" == "$path" ]] && return 0
    done
    return 1
}

# Resolve one tool target's dest to an absolute path, or empty if unset/invalid.
_resolve_one_dest() {
    local tool_name="$1" key="$2" display="$3"
    local raw abs=""
    raw=$(get_tool_value "$tool_name" "targets.$key.dest")
    [[ -n "$raw" ]] || { echo ""; return 0; }
    abs=$(resolve_dest_path "$raw" "targets.$key.dest for $display") || abs=""
    echo "$abs"
}

# Resolved dest paths for the tool currently being synced — populated by
# _resolve_tool_dests, read by the _sync_*_step helpers. Module-scoped so the
# steps share them without threading eight positional args through every call.
_ST_DEST_AGENTS=""
_ST_DEST_RULES=""
_ST_DEST_SKILLS=""
_ST_DEST_COMMANDS=""
_ST_DEST_SUBAGENTS=""
_ST_DEST_SETTINGS=""
_ST_DEST_MCP=""
_ST_DEST_HOOKS=""

_resolve_tool_dests() {
    local tool_name="$1" display
    display=$(tool_display_name "$tool_name")
    _ST_DEST_AGENTS=$(_resolve_one_dest "$tool_name" agents "$display")
    _ST_DEST_RULES=$(_resolve_one_dest "$tool_name" rules "$display")
    _ST_DEST_SKILLS=$(_resolve_one_dest "$tool_name" skills "$display")
    _ST_DEST_COMMANDS=$(_resolve_one_dest "$tool_name" commands "$display")
    _ST_DEST_SUBAGENTS=$(_resolve_one_dest "$tool_name" subagents "$display")
    _ST_DEST_SETTINGS=$(_resolve_one_dest "$tool_name" settings "$display")
    _ST_DEST_MCP=$(_resolve_one_dest "$tool_name" mcp "$display")
    _ST_DEST_HOOKS=$(_resolve_one_dest "$tool_name" hooks "$display")
}

# Append a lightweight rule index (name + first heading) to the agents file, for
# tools that have no separate rules directory (targets.rules.inline_into_agents).
_inline_rules_into_agents() {
    local src_rules_abs="$1" dest_agents_abs="$2" rule_include="$3" rule_exclude="$4"
    [[ -d "$src_rules_abs" ]] || return 0
    {
        echo ""
        echo ""
        echo "## Rules"
        echo ""
        echo "The following rule files define project constraints. Read them before making changes:"
        echo ""
        local rule_file basename
        for rule_file in "$src_rules_abs"/*.md; do
            [[ -f "$rule_file" ]] || continue
            basename="${rule_file##*/}"
            if matches_filter "$basename" "$rule_include" "$rule_exclude"; then
                # First Markdown heading, skipping any YAML frontmatter — path-scoped
                # rules open with a `---` block, so `head -1` would print the delimiter.
                echo "- \`$basename\` — $(sed -n 's/^##* *//p' "$rule_file" | head -1)"
            fi
        done
        echo ""
        echo "Find all rules in \`.ai/src/rules/\`."
    } >> "$dest_agents_abs"
    manifest_record_write "$dest_agents_abs"
    log_step "Appended rule references to ${dest_agents_abs##*/}"
}

# Append a lightweight skill index (name + description) to a target file, for
# tools with no native skills directory (targets.skills.inline_into_agents).
_inline_skills_into_file() {
    local src_skills_abs="$1" target_file="$2" skills_include="$3" skills_exclude="$4"
    local skill_entries="" skill_dir skill_name skill_desc skill_file
    for skill_dir in "$src_skills_abs"/*/; do
        [[ -d "$skill_dir" ]] || continue
        # Trailing slash from the */ glob: strip it before taking the leaf.
        skill_name="${skill_dir%/}"; skill_name="${skill_name##*/}"
        matches_filter "$skill_name" "$skills_include" "$skills_exclude" || continue
        skill_desc=""
        skill_file="$skill_dir/SKILL.md"
        if [[ -f "$skill_file" ]]; then
            skill_desc=$(sed -n '/^---$/,/^---$/{ /^description:/{ s/^description:[[:space:]]*//; s/^>[[:space:]]*//; p; }; }' "$skill_file" | head -1)
            [[ "$skill_desc" == ">" ]] && skill_desc=""
            if [[ -z "$skill_desc" ]]; then
                skill_desc=$(sed -n '/^---$/,/^---$/{/^description:/,/^[a-z]/{ /^  /{ s/^[[:space:]]*//; p; q; }; }; }' "$skill_file")
            fi
        fi
        if [[ -n "$skill_desc" ]]; then
            skill_entries+="- \`$skill_name\` — $skill_desc"$'\n'
        else
            skill_entries+="- \`$skill_name\`"$'\n'
        fi
    done
    [[ -n "$skill_entries" ]] || return 0
    {
        echo ""
        echo "## Skills"
        echo ""
        echo "The following skills provide step-by-step workflows. Find them in \`.ai/src/skills/\`:"
        echo ""
        printf '%s' "$skill_entries"
    } >> "$target_file"
    manifest_record_write "$target_file"
    log_step "Appended skill index to ${target_file##*/}"
}

# Resolve a tool target's effective source to an absolute path: the per-tool
# targets.<key>.source override if set, else the run-wide default.
_resolve_tool_src() {
    local tool_name="$1" key="$2" default="$3" display="$4"
    local override
    override=$(get_tool_value "$tool_name" "targets.$key.source")
    resolve_source_path "${override:-$default}" "targets.$key.source for $display"
}

# Re-copy an AGENTS file that lives inside the rules dir — sync_rules sweeps the
# directory, so the file must be restored afterwards.
_recopy_nested_agents() {
    local src_agents_abs="$1" dest_agents_abs="$2" dest_rules_abs="$3"
    [[ -n "$dest_agents_abs" ]] && [[ -n "$dest_rules_abs" ]] || return 0
    [[ "$dest_agents_abs" == "$dest_rules_abs"/* ]] || return 0
    [[ "$DRY_RUN" != "true" ]] || return 0
    copy_file "$src_agents_abs" "$dest_agents_abs" "false" 2>/dev/null || true
}

_sync_agents_step() {
    local tool_name="$1" display="$2"
    local dest_agents_abs="$_ST_DEST_AGENTS"
    [[ -n "$dest_agents_abs" ]] || return 0

    local src_agents_abs
    src_agents_abs=$(_resolve_tool_src "$tool_name" agents "$SOURCE_AGENTS" "$display")
    copy_file "$src_agents_abs" "$dest_agents_abs" "$DRY_RUN"
}

# Sync RULES as a directory, a merged file, or an index inlined into AGENTS,
# per the tool's rules options.
_sync_rules_step() {
    local tool_name="$1" display="$2"
    local dest_agents_abs="$_ST_DEST_AGENTS" dest_rules_abs="$_ST_DEST_RULES"

    local src_agents_abs src_rules_abs
    src_agents_abs=$(_resolve_tool_src "$tool_name" agents "$SOURCE_AGENTS" "$display")
    src_rules_abs=$(_resolve_tool_src "$tool_name" rules "$SOURCE_RULES" "$display")

    local rule_ext rule_header rule_scoped_header append_imports_flag rule_include rule_exclude
    rule_ext=$(get_tool_value "$tool_name" "targets.rules.extension")
    rule_header=$(get_tool_value "$tool_name" "targets.rules.header")
    rule_scoped_header=$(get_tool_value "$tool_name" "targets.rules.scoped_header")
    append_imports_flag=$(get_tool_value "$tool_name" "targets.rules.append_imports")
    rule_include=$(get_tool_filter "$tool_name" "targets.rules.include")
    rule_exclude=$(get_tool_filter "$tool_name" "targets.rules.exclude")

    local merge_to_file inline_into_agents
    merge_to_file=$(get_tool_value "$tool_name" "targets.rules.merge_to_file")
    inline_into_agents=$(get_tool_value "$tool_name" "targets.rules.inline_into_agents")

    if [[ "$inline_into_agents" == "true" ]] && [[ -n "$dest_agents_abs" ]]; then
        if [[ "$DRY_RUN" != "true" ]]; then
            _inline_rules_into_agents "$src_rules_abs" "$dest_agents_abs" "$rule_include" "$rule_exclude"
        else
            log_step "Would append rule references to ${dest_agents_abs##*/} (dry-run)"
        fi
    elif [[ -n "$dest_rules_abs" ]]; then
        if [[ "$merge_to_file" == "true" ]]; then
            local prepend_agents_flag agents_for_prepend=""
            prepend_agents_flag=$(get_tool_value "$tool_name" "targets.rules.prepend_agents")
            if [[ "$prepend_agents_flag" == "true" ]] && [[ -f "$src_agents_abs" ]]; then
                agents_for_prepend="$src_agents_abs"
            fi
            merge_rules_to_file "$src_rules_abs" "$dest_rules_abs" "$DRY_RUN" "$rule_include" "$rule_exclude" "$agents_for_prepend"
        else
            sync_rules "$src_rules_abs" "$dest_rules_abs" "$rule_ext" "$rule_header" "$DRY_RUN" "$rule_include" "$rule_exclude" "$rule_scoped_header"

            if [[ "$append_imports_flag" == "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
                if [[ -n "$dest_agents_abs" ]]; then
                    append_imports "$dest_agents_abs" "$dest_rules_abs"
                    log_step "Appended @rules imports to ${dest_agents_abs##*/}"
                else
                    log_warning "Skipping append_imports for $display because targets.agents.dest is missing"
                fi
            fi
        fi
    fi

    _recopy_nested_agents "$src_agents_abs" "$dest_agents_abs" "$dest_rules_abs"
}

# Sync SKILLS as a directory, or inline an index when the tool has no native
# skills surface.
_sync_skills_step() {
    local tool_name="$1" display="$2"
    local dest_skills_abs="$_ST_DEST_SKILLS" dest_agents_abs="$_ST_DEST_AGENTS" dest_rules_abs="$_ST_DEST_RULES"

    local src_skills_abs
    src_skills_abs=$(_resolve_tool_src "$tool_name" skills "$SOURCE_SKILLS" "$display")

    local skills_include skills_exclude
    skills_include=$(get_tool_filter "$tool_name" "targets.skills.include")
    skills_exclude=$(get_tool_filter "$tool_name" "targets.skills.exclude")

    local inline_skills merge_to_file commands_as_skills
    inline_skills=$(get_tool_value "$tool_name" "targets.skills.inline_into_agents")
    merge_to_file=$(get_tool_value "$tool_name" "targets.rules.merge_to_file")
    commands_as_skills=$(get_tool_value "$tool_name" "targets.commands.as_skills")

    if [[ -n "$dest_skills_abs" ]]; then
        # Generated command-* skills are owned by the COMMANDS step below — tell
        # sync_dir to leave them in place rather than sweep them as extraneous.
        local skills_exclude_effective="$skills_exclude"
        if [[ "$commands_as_skills" == "true" ]]; then
            if [[ -n "$skills_exclude_effective" ]]; then
                skills_exclude_effective="$skills_exclude_effective command-*"
            else
                skills_exclude_effective="command-*"
            fi
        fi
        sync_dir "$src_skills_abs" "$dest_skills_abs" "$DRY_RUN" "$skills_include" "$skills_exclude_effective"
    elif [[ "$inline_skills" == "true" ]] && [[ -d "$src_skills_abs" ]]; then
        local skills_target_file="$dest_agents_abs"
        if [[ -z "$skills_target_file" ]] && [[ "$merge_to_file" == "true" ]] && [[ -f "$dest_rules_abs" ]]; then
            skills_target_file="$dest_rules_abs"
        fi
        if [[ -n "$skills_target_file" ]] && [[ "$DRY_RUN" != "true" ]]; then
            _inline_skills_into_file "$src_skills_abs" "$skills_target_file" "$skills_include" "$skills_exclude"
        elif [[ "$DRY_RUN" == "true" ]]; then
            log_step "Would append skill index (dry-run)"
        fi
    fi
}

# Sync COMMANDS to a native commands dir, or fall back to generated skills /
# an inlined index for tools without one.
_sync_commands_step() {
    local tool_name="$1" display="$2"
    local dest_commands_abs="$_ST_DEST_COMMANDS" dest_skills_abs="$_ST_DEST_SKILLS"
    local dest_agents_abs="$_ST_DEST_AGENTS" dest_rules_abs="$_ST_DEST_RULES"

    [[ -n "${SOURCE_COMMANDS:-}" ]] || return 0

    local dest_cmd_ext dest_cmd_format cmd_include cmd_exclude
    local commands_as_skills commands_inline_into_agents merge_to_file
    dest_cmd_ext=$(get_tool_value "$tool_name" "targets.commands.extension")
    dest_cmd_format=$(get_tool_value "$tool_name" "targets.commands.format")
    cmd_include=$(get_tool_filter "$tool_name" "targets.commands.include")
    cmd_exclude=$(get_tool_filter "$tool_name" "targets.commands.exclude")
    commands_as_skills=$(get_tool_value "$tool_name" "targets.commands.as_skills")
    commands_inline_into_agents=$(get_tool_value "$tool_name" "targets.commands.inline_into_agents")
    merge_to_file=$(get_tool_value "$tool_name" "targets.rules.merge_to_file")

    local src_commands_abs
    src_commands_abs=$(resolve_source_path "$SOURCE_COMMANDS" "source.commands for $display")
    [[ -d "$src_commands_abs" ]] || return 0

    if [[ -n "$dest_commands_abs" ]]; then
        if [[ "$dest_cmd_format" == "toml" ]]; then
            sync_commands_as_toml "$src_commands_abs" "$dest_commands_abs" "$DRY_RUN"
        else
            sync_rules "$src_commands_abs" "$dest_commands_abs" "$dest_cmd_ext" "" "$DRY_RUN" "" ""
        fi
    elif [[ "$commands_as_skills" == "true" ]] && [[ -n "$dest_skills_abs" ]]; then
        log_info "$display has no native commands surface — generating skills (command-*) instead"
        sync_commands_as_skills "$src_commands_abs" "$dest_skills_abs" "$DRY_RUN" "$cmd_include" "$cmd_exclude"
    elif [[ "$commands_inline_into_agents" == "true" ]]; then
        local commands_target_file="$dest_agents_abs"
        if [[ -z "$commands_target_file" ]] && [[ "$merge_to_file" == "true" ]] && [[ -f "$dest_rules_abs" ]]; then
            commands_target_file="$dest_rules_abs"
        fi
        if [[ -n "$commands_target_file" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log_step "Would append command index (dry-run)"
            else
                log_info "$display has no native commands surface — appending command index to ${commands_target_file##*/}"
                inline_commands_to_file "$src_commands_abs" "$commands_target_file" "$cmd_include" "$cmd_exclude"
            fi
        fi
    fi
}

# Sync SUBAGENTS in the tool's native format (markdown, TOML, or Amazon Q JSON).
_sync_subagents_step() {
    local tool_name="$1" display="$2"
    local dest_subagents_abs="$_ST_DEST_SUBAGENTS"
    [[ -n "$dest_subagents_abs" ]] && [[ -n "${SOURCE_SUBAGENTS:-}" ]] || return 0

    local src_subagents_abs
    src_subagents_abs=$(resolve_source_path "$SOURCE_SUBAGENTS" "source.subagents for $display")
    [[ -d "$src_subagents_abs" ]] || return 0

    local dest_sa_ext dest_sa_format
    dest_sa_ext=$(get_tool_value "$tool_name" "targets.subagents.extension")
    dest_sa_format=$(get_tool_value "$tool_name" "targets.subagents.format")
    case "$dest_sa_format" in
        toml)         sync_agents_as_toml "$src_subagents_abs" "$dest_subagents_abs" "$DRY_RUN" ;;
        amazonq_json) sync_agents_as_amazonq_json "$src_subagents_abs" "$dest_subagents_abs" "$DRY_RUN" ;;
        *)            sync_rules "$src_subagents_abs" "$dest_subagents_abs" "$dest_sa_ext" "" "$DRY_RUN" "" "" ;;
    esac
}

# Copy the SETTINGS, MCP, and HOOKS payloads — each per-tool override falling
# back to the shared/base source via resolve_payload_source.
_sync_payloads_step() {
    local tool_name="$1" display="$2"
    local dest_settings_abs="$_ST_DEST_SETTINGS" dest_mcp_abs="$_ST_DEST_MCP" dest_hooks_abs="$_ST_DEST_HOOKS"

    if [[ -n "$dest_settings_abs" ]]; then
        local src_settings_abs
        src_settings_abs=$(resolve_payload_source "$tool_name" "settings")
        if [[ -n "$src_settings_abs" ]] && [[ -f "$src_settings_abs" ]]; then
            copy_file "$src_settings_abs" "$dest_settings_abs" "$DRY_RUN"
        fi
    fi

    if [[ -n "$dest_mcp_abs" ]]; then
        local src_mcp_abs
        src_mcp_abs=$(resolve_payload_source "$tool_name" "mcp")
        if [[ -n "$src_mcp_abs" ]] && [[ -f "$src_mcp_abs" ]]; then
            local mcp_label
            mcp_label=$(describe_payload_source "$src_mcp_abs" "$tool_name" "mcp")
            copy_file "$src_mcp_abs" "$dest_mcp_abs" "$DRY_RUN"
            [[ -n "$mcp_label" ]] && log_step "mcp source: $mcp_label"
        fi
    fi

    if [[ -n "$dest_hooks_abs" ]]; then
        local src_hooks_abs
        src_hooks_abs=$(resolve_payload_source "$tool_name" "hooks")
        if [[ -n "$src_hooks_abs" ]] && [[ -f "$src_hooks_abs" ]]; then
            copy_file "$src_hooks_abs" "$dest_hooks_abs" "$DRY_RUN"
        fi
    fi
}

# Sync a single tool. Assumes the tool is enabled and tool_resolver globals are ready.
sync_tool() {
    local tool_name="$1" display
    display=$(tool_display_name "$tool_name")

    if ! should_sync_tool "$tool_name"; then
        log_info "Skipping $display (filtered by CLI)"
        ((SKIPPED_COUNT++)) || true
        return 0
    fi

    _resolve_tool_dests "$tool_name"

    log_info "Syncing $display..."

    _sync_agents_step "$tool_name" "$display"
    _sync_rules_step "$tool_name" "$display"
    _sync_skills_step "$tool_name" "$display"
    _sync_commands_step "$tool_name" "$display"
    _sync_subagents_step "$tool_name" "$display"
    _sync_payloads_step "$tool_name" "$display"

    local post_sync_cmd
    post_sync_cmd=$(get_tool_value "$tool_name" "post_sync")
    if [[ "$DRY_RUN" != "true" ]]; then
        if ! run_post_sync_hook "$display" "$post_sync_cmd"; then
            log_error "Sync failed because post-sync hook failed for $display"
            return 1
        fi
    fi

    log_success "$display complete"
    ((SYNCED_COUNT++)) || true
}

# Cleanup outputs of a tool that is not enabled (when DEFAULT_CLEANUP=true).
cleanup_tool() {
    local tool_name="$1"
    local display
    display=$(tool_display_name "$tool_name")

    [[ "$DEFAULT_CLEANUP" != "true" ]] && {
        log_info "Skipping $display (disabled, cleanup off)"
        ((SKIPPED_COUNT++)) || true
        return 0
    }

    local cleaned=false
    local key raw abs
    for key in "${AGENTSYNC_TARGET_KEYS[@]}"; do
        raw=$(get_tool_value "$tool_name" "targets.$key.dest")
        [[ -z "$raw" ]] && continue
        abs=$(resolve_dest_path "$raw" "targets.$key.dest for $display") || continue
        [[ -z "$abs" ]] && continue
        if ! is_path_protected "$abs"; then
            if cleanup_path "$abs" "$DRY_RUN"; then
                cleaned=true
            fi
        fi
    done

    if [[ "$cleaned" == "true" ]]; then
        log_info "Cleaned up $display (disabled)"
    else
        log_info "Skipping $display (disabled)"
    fi
    ((SKIPPED_COUNT++)) || true
}

# Verify the global config exists, locate the project config, and apply its
# defaults / post-sync / gitignore settings into the run's globals.
_load_run_config() {
    local global_config="$SCRIPT_DIR/config.yaml"
    if [[ ! -f "$global_config" ]]; then
        log_error "Global config not found: $global_config"
        exit 1
    fi

    resolve_project_config_path
    [[ -n "$PROJECT_CONFIG_PATH" ]] || return 0

    local cfg_default_enabled cfg_default_cleanup cfg_allow_post_sync cfg_skip_post_sync
    cfg_default_enabled=$(parse_yaml_value "$PROJECT_CONFIG_PATH" "defaults.enabled")
    cfg_default_cleanup=$(parse_yaml_value "$PROJECT_CONFIG_PATH" "defaults.cleanup")
    cfg_allow_post_sync=$(parse_yaml_value "$PROJECT_CONFIG_PATH" "post_sync.allow")
    cfg_skip_post_sync=$(parse_yaml_value "$PROJECT_CONFIG_PATH" "post_sync.skip")

    # shellcheck disable=SC2034
    [[ -n "$cfg_default_enabled" ]] && DEFAULT_ENABLED="$cfg_default_enabled"
    [[ -n "$cfg_default_cleanup" ]] && DEFAULT_CLEANUP="$cfg_default_cleanup"

    if [[ -z "${AGENTSYNC_ALLOW_POST_SYNC:-}" ]] && [[ "$cfg_allow_post_sync" == "true" ]]; then
        ALLOW_POST_SYNC="true"
    fi
    if [[ -z "${AGENTSYNC_SKIP_POST_SYNC:-}" ]] && [[ "$cfg_skip_post_sync" == "true" ]]; then
        SKIP_POST_SYNC="true"
    fi

    local cfg_update_gitignore
    cfg_update_gitignore=$(parse_yaml_value "$PROJECT_CONFIG_PATH" "gitignore.update")
    if [[ "$cfg_update_gitignore" == "false" ]]; then
        UPDATE_GITIGNORE="false"
    fi
}

# Echo the first existing source candidate for <subpath>, preferring the
# .ai/src/ layout over a flat .ai/ one. <kind> is `file` or `dir`. Empty if none.
_detect_source() {
    local kind="$1" subpath="$2"
    local nested=".ai/src/$subpath" flat=".ai/$subpath"
    if [[ "$kind" == "file" ]]; then
        [[ -f "$REPO_ROOT/$nested" ]] && { echo "$nested"; return 0; }
        [[ -f "$REPO_ROOT/$flat" ]] && { echo "$flat"; return 0; }
    else
        [[ -d "$REPO_ROOT/$nested" ]] && { echo "$nested"; return 0; }
        [[ -d "$REPO_ROOT/$flat" ]] && { echo "$flat"; return 0; }
    fi
    echo ""
}

# Resolve SOURCE_* paths: global-config defaults, then local .ai layout
# auto-detection, then project agent_sync.yaml overrides. Exits if the resolved
# AGENTS source is missing.
_resolve_sources() {
    local global_config="$SCRIPT_DIR/config.yaml"
    SOURCE_AGENTS=$(parse_yaml_value "$global_config" "source.agents")
    SOURCE_RULES=$(parse_yaml_value "$global_config" "source.rules")
    SOURCE_SKILLS=$(parse_yaml_value "$global_config" "source.skills")
    # shellcheck disable=SC2034
    SOURCE_TOOLS=$(parse_yaml_value "$global_config" "source.tools")

    local detected
    detected=$(_detect_source file AGENTS.md); [[ -n "$detected" ]] && SOURCE_AGENTS="$detected"
    detected=$(_detect_source dir rules);      [[ -n "$detected" ]] && SOURCE_RULES="$detected"
    detected=$(_detect_source dir skills);     [[ -n "$detected" ]] && SOURCE_SKILLS="$detected"
    # shellcheck disable=SC2034
    detected=$(_detect_source dir tools);      [[ -n "$detected" ]] && SOURCE_TOOLS="$detected"

    SOURCE_COMMANDS=""
    detected=$(_detect_source dir commands);   [[ -n "$detected" ]] && SOURCE_COMMANDS="$detected"
    SOURCE_SUBAGENTS=""
    detected=$(_detect_source dir agents);     [[ -n "$detected" ]] && SOURCE_SUBAGENTS="$detected"

    local override_agents override_rules override_skills override_tools override_commands override_subagents
    override_agents=$(resolve_source_override "agents")
    override_rules=$(resolve_source_override "rules")
    override_skills=$(resolve_source_override "skills")
    override_tools=$(resolve_source_override "tools")
    override_commands=$(resolve_source_override "commands")
    override_subagents=$(resolve_source_override "subagents")

    [[ -n "$override_agents" ]] && SOURCE_AGENTS="$override_agents"
    [[ -n "$override_rules" ]] && SOURCE_RULES="$override_rules"
    [[ -n "$override_skills" ]] && SOURCE_SKILLS="$override_skills"
    # shellcheck disable=SC2034
    [[ -n "$override_tools" ]] && SOURCE_TOOLS="$override_tools"
    [[ -n "$override_commands" ]] && SOURCE_COMMANDS="$override_commands"
    [[ -n "$override_subagents" ]] && SOURCE_SUBAGENTS="$override_subagents"

    local source_agents_abs
    source_agents_abs=$(resolve_source_path "$SOURCE_AGENTS" "source.agents")
    if [[ ! -f "$source_agents_abs" ]]; then
        log_error "Source agents file not found: $source_agents_abs"
        log_error "Run 'agentsync init' or set source.agents in agent_sync.yaml"
        exit 1
    fi
}

# Cheap staleness probe for --if-stale: true (0) when generated outputs may be
# stale — the manifest is missing, or any source input has a newer mtime than it.
# mtime + O(stat) only; deliberately not authoritative (use `check` for that).
# Reliable for the local-edit case but not after a pull (git resets mtimes on
# checkout), which is why the post-merge/checkout hooks run a full sync instead.
# Must run after _resolve_sources so SOURCE_* and PROJECT_CONFIG_PATH are set.
_sync_is_stale() {
    local manifest
    manifest=$(manifest_path)
    [[ -f "$manifest" ]] || return 0

    local src="$REPO_ROOT/.ai/src"
    local -a roots=()
    [[ -d "$src" ]] && roots+=("$src")
    [[ -d "$REPO_ROOT/.ai/profiles" ]] && roots+=("$REPO_ROOT/.ai/profiles")
    [[ -n "$PROJECT_CONFIG_PATH" && -f "$PROJECT_CONFIG_PATH" ]] && roots+=("$PROJECT_CONFIG_PATH")

    # Honor source.* overrides that point outside .ai/src.
    local rel abs
    for rel in "$SOURCE_AGENTS" "$SOURCE_RULES" "$SOURCE_SKILLS" "$SOURCE_COMMANDS" "$SOURCE_SUBAGENTS"; do
        [[ -n "$rel" ]] || continue
        if [[ "$rel" == /* ]]; then abs="$rel"; else abs="$REPO_ROOT/$rel"; fi
        [[ "$abs" == "$src" || "$abs" == "$src"/* ]] && continue
        [[ -e "$abs" ]] && roots+=("$abs")
    done

    [[ ${#roots[@]} -gt 0 ]] || return 0

    local newer
    newer=$(find "${roots[@]}" -newer "$manifest" -print 2>/dev/null | head -n 1 || true)
    [[ -n "$newer" ]]
}

# Append a tool's resolved dest paths to ENABLED_DEST_PATHS (cleanup protection)
# and GENERATED_GITIGNORE_PATHS (gitignore payload). Directory-type targets get a
# trailing slash so .gitignore matches the whole tree.
_collect_tool_dests() {
    local tool_name="$1"
    local key raw abs rel
    for key in "${AGENTSYNC_TARGET_KEYS[@]}"; do
        raw=$(get_tool_value "$tool_name" "targets.$key.dest")
        [[ -z "$raw" ]] && continue
        abs=$(resolve_dest_path "$raw" "targets.$key.dest for $tool_name") || continue
        ENABLED_DEST_PATHS+=("$abs")
        rel=$(to_repo_relative_path "$abs")
        case "$key" in
            rules|skills|commands|subagents) GENERATED_GITIGNORE_PATHS+=("$rel/") ;;
            *) GENERATED_GITIGNORE_PATHS+=("$rel") ;;
        esac
    done
}

# Refuse to overwrite destination files edited since the last sync, unless
# --force. Skipped on dry-run. Exits non-zero when drift is found without --force.
_check_drift_or_exit() {
    [[ "$DRY_RUN" != "true" ]] || return 0
    manifest_check_drift
    [[ ${#SYNC_DRIFT_DETECTED[@]} -gt 0 ]] || return 0

    local rel
    if [[ "$FORCE_SYNC" == "true" ]]; then
        log_warning "Overwriting ${#SYNC_DRIFT_DETECTED[@]} file(s) with manual edits (--force):"
        for rel in "${SYNC_DRIFT_DETECTED[@]}"; do
            echo "      $rel" >&2
        done
        return 0
    fi

    log_error "Manual edits detected in ${#SYNC_DRIFT_DETECTED[@]} destination file(s) since last sync:"
    for rel in "${SYNC_DRIFT_DETECTED[@]}"; do
        echo "      $rel" >&2
    done
    echo "" >&2
    echo "  These files would be silently overwritten. Choose one:" >&2
    echo "    • Move your edits into .ai/src/, then re-run sync" >&2
    echo "    • If a tool wrote here out of band, run 'agentsync adopt <file>' to pull it into .ai/src/" >&2
    echo "    • Re-run with --force to discard the edits and rewrite from source" >&2
    echo "" >&2
    exit 1
}

_print_banner() {
    log_separator
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Starting AgentSync Config Sync (DRY RUN)..."
    else
        log_info "Starting AgentSync Config Sync..."
    fi
    log_separator
    echo ""
}

# Snapshot the personal/base SOURCE_* (post-shared-overlay) so each profile pass
# can restore them before layering its own overlay, and resolve the base src dir
# profiles fill from. The overlay rewrite is conditional, so the snapshot can't
# be recomputed cheaply later.
_snapshot_base_sources() {
    BASE_SOURCE_AGENTS="$SOURCE_AGENTS"
    BASE_SOURCE_RULES="$SOURCE_RULES"
    BASE_SOURCE_SKILLS="$SOURCE_SKILLS"
    BASE_SOURCE_COMMANDS="$SOURCE_COMMANDS"
    BASE_SOURCE_SUBAGENTS="$SOURCE_SUBAGENTS"

    PROFILE_BASE_SRC="$REPO_ROOT/.ai/src"
    if [[ -n "${SHARED_OVERLAY_DIR:-}" ]] && [[ -d "$SHARED_OVERLAY_DIR/src" ]]; then
        PROFILE_BASE_SRC="$SHARED_OVERLAY_DIR/src"
    fi
}

# PROFILES_TO_SYNC holds the --profile name, else every active profile. Exits if
# the base catalog is empty.
_build_tool_catalog() {
    PROFILES_TO_SYNC=()
    local _p
    if [[ -n "$SELECTED_PROFILE" ]]; then
        PROFILES_TO_SYNC=("$SELECTED_PROFILE")
    else
        while IFS= read -r _p; do
            [[ -z "$_p" ]] && continue
            profile_is_active "$_p" && PROFILES_TO_SYNC+=("$_p")
        done < <(list_profiles)
    fi

    ALL_TOOLS=()
    local t
    while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        ALL_TOOLS+=("$t")
    done < <(list_all_tools)

    if [[ ${#ALL_TOOLS[@]} -eq 0 ]]; then
        log_error "No tools found in base catalog ($(tool_resolver_base_dir))"
        log_error "AgentSync installation may be corrupted — try 'agentsync update'"
        exit 1
    fi
}

# Collect dest paths from enabled personal tools and from EVERY profile tool
# (active or not) into ENABLED_DEST_PATHS + GENERATED_GITIGNORE_PATHS. Profile
# tools are always collected so .gitignore stays stable across --profile
# selections and cleanup never sweeps a dormant profile's output.
_collect_protected_dests() {
    local t
    for t in "${ALL_TOOLS[@]}"; do
        is_tool_enabled "$t" || continue
        is_profile_tool "$t" && continue
        _collect_tool_dests "$t"
    done

    local _pt
    while IFS= read -r _pt; do
        [[ -z "$_pt" ]] && continue
        _collect_tool_dests "$_pt"
    done < <(list_profile_tools)
}

# Sync enabled personal tools and clean up disabled ones. Profile variant tools
# are owned by the profile pass — skipped here.
_run_personal_pass() {
    local t
    for t in "${ALL_TOOLS[@]}"; do
        is_profile_tool "$t" && continue
        ((TOTAL_COUNT++)) || true
        if is_tool_enabled "$t"; then
            sync_tool "$t"
        else
            cleanup_tool "$t"
        fi
        echo ""
    done
}

# Sync each selected/active profile's variant tools under a per-profile source
# overlay (profile extras win, base fills the rest).
_run_profile_passes() {
    local _p t
    for _p in "${PROFILES_TO_SYNC[@]+"${PROFILES_TO_SYNC[@]}"}"; do
        local _profile_has_tools=false
        while IFS= read -r t; do
            [[ -z "$t" ]] && continue
            _profile_has_tools=true
            break
        done < <(profile_tools "$_p")
        [[ "$_profile_has_tools" != "true" ]] && continue

        log_separator
        log_info "Profile: $_p"

        SOURCE_AGENTS="$BASE_SOURCE_AGENTS"
        SOURCE_RULES="$BASE_SOURCE_RULES"
        SOURCE_SKILLS="$BASE_SOURCE_SKILLS"
        SOURCE_COMMANDS="$BASE_SOURCE_COMMANDS"
        SOURCE_SUBAGENTS="$BASE_SOURCE_SUBAGENTS"
        profile_setup_overlay "$_p" "$PROFILE_BASE_SRC" || true

        while IFS= read -r t; do
            [[ -z "$t" ]] && continue
            ((TOTAL_COUNT++)) || true
            sync_tool "$t"
            echo ""
        done < <(profile_tools "$_p")

        profile_cleanup_overlay
    done
}

_finalize_run() {
    if [[ "$DRY_RUN" != "true" ]] && [[ "$UPDATE_GITIGNORE" == "true" ]]; then
        log_separator
        log_info "Updating .gitignore..."
        local generated_paths_payload=""
        if [[ ${#GENERATED_GITIGNORE_PATHS[@]} -gt 0 ]]; then
            generated_paths_payload=$(printf '%s\n' "${GENERATED_GITIGNORE_PATHS[@]}")
        fi
        update_gitignore "$REPO_ROOT/.gitignore" "$generated_paths_payload"
    fi

    [[ "$DRY_RUN" != "true" ]] && manifest_write

    log_separator
    if [[ $SYNC_PRESERVED_COUNT -gt 0 ]]; then
        log_warning "Preserved $SYNC_PRESERVED_COUNT user-added file(s) not in .ai/src/ — move them into .ai/src/ to manage them, or re-run with --force to prune."
    fi
    local summary="Synced $SYNCED_COUNT/$TOTAL_COUNT tools"
    [[ $SKIPPED_COUNT -gt 0 ]] && summary="$summary ($SKIPPED_COUNT skipped)"
    [[ "$DRY_RUN" == "true" ]] && summary="$summary (dry-run)"
    log_done "$summary"
    log_separator
}

# Main entry point
main() {
    parse_args "$@"

    _load_run_config
    _resolve_sources

    # --if-stale short-circuit: skip the run, silently, when no source input is
    # newer than the manifest. Silence on the fresh path is load-bearing — the
    # shell-init hook calls this on every cd and must stay quiet when nothing
    # changed; output appears only when a real sync runs.
    if [[ "$IF_STALE" == "true" ]] && ! _sync_is_stale; then
        return 0
    fi

    _print_banner

    # `shared:` overlay — must run AFTER child SOURCE_* resolution so child files
    # take precedence, and BEFORE any tool sync reads them. Torn down by the EXIT
    # trap below.
    shared_setup_overlay
    trap 'shared_cleanup_overlay; profile_cleanup_overlay' EXIT

    _snapshot_base_sources
    _build_tool_catalog
    warm_enabled_tools_cache
    _collect_protected_dests

    # Load the manifest (even on dry-run) so the sweep helpers tell sync-generated
    # outputs from user-added files; SYNC_MANIFEST_ACTIVE gates that protection.
    manifest_load
    # Read by sync_may_prune in file_ops.sh / rule_operations.sh.
    # shellcheck disable=SC2034
    SYNC_MANIFEST_ACTIVE="true"

    _check_drift_or_exit
    _run_personal_pass
    _run_profile_passes
    _finalize_run
}

main "$@"
