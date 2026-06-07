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
ONLY_TOOLS=""
SKIP_TOOLS=""
SELECTED_PROFILE=""
SKIP_POST_SYNC="${AGENTSYNC_SKIP_POST_SYNC:-false}"
ALLOW_POST_SYNC="${AGENTSYNC_ALLOW_POST_SYNC:-false}"
SYNCED_COUNT=0
SKIPPED_COUNT=0
TOTAL_COUNT=0
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

# Resolve every dest path for a tool (effective values via tool_resolver).
# Sets the given named variables in the caller's scope.
# Usage: _resolve_tool_dests <tool_name> <out_prefix>
# Produces: <prefix>_agents, <prefix>_rules, ..., each as absolute path or empty.
_resolve_tool_dests() {
    local tool_name="$1"
    local prefix="$2"
    local display
    display=$(tool_display_name "$tool_name")

    local raw abs
    local key
    for key in agents rules skills commands subagents settings mcp hooks; do
        raw=$(get_tool_value "$tool_name" "targets.$key.dest")
        abs=""
        if [[ -n "$raw" ]]; then
            abs=$(resolve_dest_path "$raw" "targets.$key.dest for $display")
        fi
        printf -v "${prefix}_${key}" '%s' "$abs"
    done
}

# Sync a single tool. Assumes the tool is enabled and tool_resolver globals are ready.
sync_tool() {
    local tool_name="$1"
    local display
    display=$(tool_display_name "$tool_name")

    if ! should_sync_tool "$tool_name"; then
        log_info "Skipping $display (filtered by CLI)"
        ((SKIPPED_COUNT++)) || true
        return 0
    fi

    local dest_agents dest_rules dest_skills dest_commands
    local dest_subagents dest_settings dest_mcp dest_hooks
    _resolve_tool_dests "$tool_name" "dest"
    # Shellcheck: these are populated via `printf -v` inside _resolve_tool_dests.
    # shellcheck disable=SC2154
    local dest_agents_abs="$dest_agents"
    # shellcheck disable=SC2154
    local dest_rules_abs="$dest_rules"
    # shellcheck disable=SC2154
    local dest_skills_abs="$dest_skills"
    # shellcheck disable=SC2154
    local dest_commands_abs="$dest_commands"
    # shellcheck disable=SC2154
    local dest_subagents_abs="$dest_subagents"
    # shellcheck disable=SC2154
    local dest_settings_abs="$dest_settings"
    # shellcheck disable=SC2154
    local dest_mcp_abs="$dest_mcp"
    # shellcheck disable=SC2154
    local dest_hooks_abs="$dest_hooks"

    log_info "Syncing $display..."

    # 1. AGENTS
    local override_agents src_agents
    override_agents=$(get_tool_value "$tool_name" "targets.agents.source")
    src_agents="${override_agents:-$SOURCE_AGENTS}"
    local src_agents_abs
    src_agents_abs=$(resolve_source_path "$src_agents" "targets.agents.source for $display")

    if [[ -n "$dest_agents_abs" ]]; then
        copy_file "$src_agents_abs" "$dest_agents_abs" "$DRY_RUN"
    fi

    # 2. RULES
    local override_rules src_rules
    override_rules=$(get_tool_value "$tool_name" "targets.rules.source")
    src_rules="${override_rules:-$SOURCE_RULES}"
    local src_rules_abs
    src_rules_abs=$(resolve_source_path "$src_rules" "targets.rules.source for $display")

    local rule_ext rule_header append_imports_flag rule_include rule_exclude
    rule_ext=$(get_tool_value "$tool_name" "targets.rules.extension")
    rule_header=$(get_tool_value "$tool_name" "targets.rules.header")
    append_imports_flag=$(get_tool_value "$tool_name" "targets.rules.append_imports")
    rule_include=$(get_tool_filter "$tool_name" "targets.rules.include")
    rule_exclude=$(get_tool_filter "$tool_name" "targets.rules.exclude")

    local merge_to_file inline_into_agents
    merge_to_file=$(get_tool_value "$tool_name" "targets.rules.merge_to_file")
    inline_into_agents=$(get_tool_value "$tool_name" "targets.rules.inline_into_agents")

    if [[ "$inline_into_agents" == "true" ]] && [[ -n "$dest_agents_abs" ]]; then
        if [[ -d "$src_rules_abs" ]] && [[ "$DRY_RUN" != "true" ]]; then
            {
                echo ""
                echo ""
                echo "## Rules"
                echo ""
                echo "The following rule files define project constraints. Read them before making changes:"
                echo ""
                for rule_file in "$src_rules_abs"/*.md; do
                    [[ -f "$rule_file" ]] || continue
                    local basename
                    basename=$(basename "$rule_file")
                    if matches_filter "$basename" "$rule_include" "$rule_exclude"; then
                        echo "- \`$basename\` — $(head -1 "$rule_file" | sed 's/^[#]* *//')"
                    fi
                done
                echo ""
                echo "Find all rules in \`.ai/src/rules/\`."
            } >> "$dest_agents_abs"
            manifest_record_write "$dest_agents_abs"
            log_step "Appended rule references to $(basename "$dest_agents_abs")"
        elif [[ "$DRY_RUN" == "true" ]]; then
            log_step "Would append rule references to $(basename "$dest_agents_abs") (dry-run)"
        fi
    elif [[ -n "$dest_rules_abs" ]]; then
        if [[ "$merge_to_file" == "true" ]]; then
            local prepend_agents_flag
            prepend_agents_flag=$(get_tool_value "$tool_name" "targets.rules.prepend_agents")
            local agents_for_prepend=""
            if [[ "$prepend_agents_flag" == "true" ]] && [[ -f "$src_agents_abs" ]]; then
                agents_for_prepend="$src_agents_abs"
            fi
            merge_rules_to_file "$src_rules_abs" "$dest_rules_abs" "$DRY_RUN" "$rule_include" "$rule_exclude" "$agents_for_prepend"
        else
            sync_rules "$src_rules_abs" "$dest_rules_abs" "$rule_ext" "$rule_header" "$DRY_RUN" "$rule_include" "$rule_exclude"

            if [[ "$append_imports_flag" == "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
                if [[ -n "$dest_agents_abs" ]]; then
                    append_imports "$dest_agents_abs" "$dest_rules_abs"
                    log_step "Appended @rules imports to $(basename "$dest_agents_abs")"
                else
                    log_warning "Skipping append_imports for $display because targets.agents.dest is missing"
                fi
            fi
        fi
    fi

    if [[ -n "$dest_agents_abs" ]] && [[ -n "$dest_rules_abs" ]] && [[ "$dest_agents_abs" == "$dest_rules_abs"/* ]]; then
        if [[ "$DRY_RUN" != "true" ]]; then
            copy_file "$src_agents_abs" "$dest_agents_abs" "false" 2>/dev/null || true
        fi
    fi

    # 3. SKILLS
    local override_skills src_skills
    override_skills=$(get_tool_value "$tool_name" "targets.skills.source")
    src_skills="${override_skills:-$SOURCE_SKILLS}"
    local src_skills_abs
    src_skills_abs=$(resolve_source_path "$src_skills" "targets.skills.source for $display")

    local skills_include skills_exclude
    skills_include=$(get_tool_filter "$tool_name" "targets.skills.include")
    skills_exclude=$(get_tool_filter "$tool_name" "targets.skills.exclude")

    local inline_skills
    inline_skills=$(get_tool_value "$tool_name" "targets.skills.inline_into_agents")

    local commands_as_skills
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
            local skill_entries=""
            for skill_dir in "$src_skills_abs"/*/; do
                [[ -d "$skill_dir" ]] || continue
                local skill_name skill_desc=""
                skill_name=$(basename "$skill_dir")
                if matches_filter "$skill_name" "$skills_include" "$skills_exclude"; then
                    local skill_file="$skill_dir/SKILL.md"
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
                fi
            done
            if [[ -n "$skill_entries" ]]; then
                {
                    echo ""
                    echo "## Skills"
                    echo ""
                    echo "The following skills provide step-by-step workflows. Find them in \`.ai/src/skills/\`:"
                    echo ""
                    printf '%s' "$skill_entries"
                } >> "$skills_target_file"
                manifest_record_write "$skills_target_file"
                log_step "Appended skill index to $(basename "$skills_target_file")"
            fi
        elif [[ "$DRY_RUN" == "true" ]]; then
            log_step "Would append skill index (dry-run)"
        fi
    fi

    # 4. COMMANDS
    local dest_cmd_ext dest_cmd_format cmd_include cmd_exclude commands_inline_into_agents
    dest_cmd_ext=$(get_tool_value "$tool_name" "targets.commands.extension")
    dest_cmd_format=$(get_tool_value "$tool_name" "targets.commands.format")
    cmd_include=$(get_tool_filter "$tool_name" "targets.commands.include")
    cmd_exclude=$(get_tool_filter "$tool_name" "targets.commands.exclude")
    commands_inline_into_agents=$(get_tool_value "$tool_name" "targets.commands.inline_into_agents")
    if [[ -n "$dest_commands_abs" ]] && [[ -n "${SOURCE_COMMANDS:-}" ]]; then
        local src_commands_abs
        src_commands_abs=$(resolve_source_path "$SOURCE_COMMANDS" "source.commands for $display")
        if [[ -d "$src_commands_abs" ]]; then
            if [[ "$dest_cmd_format" == "toml" ]]; then
                sync_commands_as_toml "$src_commands_abs" "$dest_commands_abs" "$DRY_RUN"
            else
                sync_rules "$src_commands_abs" "$dest_commands_abs" "$dest_cmd_ext" "" "$DRY_RUN" "" ""
            fi
        fi
    elif [[ "$commands_as_skills" == "true" ]] && [[ -n "$dest_skills_abs" ]] && [[ -n "${SOURCE_COMMANDS:-}" ]]; then
        local src_commands_abs
        src_commands_abs=$(resolve_source_path "$SOURCE_COMMANDS" "source.commands for $display")
        if [[ -d "$src_commands_abs" ]]; then
            log_info "$display has no native commands surface — generating skills (command-*) instead"
            sync_commands_as_skills "$src_commands_abs" "$dest_skills_abs" "$DRY_RUN" "$cmd_include" "$cmd_exclude"
        fi
    elif [[ "$commands_inline_into_agents" == "true" ]] && [[ -n "${SOURCE_COMMANDS:-}" ]]; then
        local src_commands_abs commands_target_file
        src_commands_abs=$(resolve_source_path "$SOURCE_COMMANDS" "source.commands for $display")
        commands_target_file="$dest_agents_abs"
        if [[ -z "$commands_target_file" ]] && [[ "$merge_to_file" == "true" ]] && [[ -f "$dest_rules_abs" ]]; then
            commands_target_file="$dest_rules_abs"
        fi
        if [[ -d "$src_commands_abs" ]] && [[ -n "$commands_target_file" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log_step "Would append command index (dry-run)"
            else
                log_info "$display has no native commands surface — appending command index to $(basename "$commands_target_file")"
                inline_commands_to_file "$src_commands_abs" "$commands_target_file" "$cmd_include" "$cmd_exclude"
            fi
        fi
    fi

    # 5. SUBAGENTS
    local dest_sa_ext dest_sa_format
    dest_sa_ext=$(get_tool_value "$tool_name" "targets.subagents.extension")
    dest_sa_format=$(get_tool_value "$tool_name" "targets.subagents.format")
    if [[ -n "$dest_subagents_abs" ]] && [[ -n "${SOURCE_SUBAGENTS:-}" ]]; then
        local src_subagents_abs
        src_subagents_abs=$(resolve_source_path "$SOURCE_SUBAGENTS" "source.subagents for $display")
        if [[ -d "$src_subagents_abs" ]]; then
            case "$dest_sa_format" in
                toml)
                    sync_agents_as_toml "$src_subagents_abs" "$dest_subagents_abs" "$DRY_RUN"
                    ;;
                amazonq_json)
                    sync_agents_as_amazonq_json "$src_subagents_abs" "$dest_subagents_abs" "$DRY_RUN"
                    ;;
                *)
                    sync_rules "$src_subagents_abs" "$dest_subagents_abs" "$dest_sa_ext" "" "$DRY_RUN" "" ""
                    ;;
            esac
        fi
    fi

    # 6. SETTINGS  — override → base fallback via resolve_payload_source
    if [[ -n "$dest_settings_abs" ]]; then
        local src_settings_abs
        src_settings_abs=$(resolve_payload_source "$tool_name" "settings")
        if [[ -n "$src_settings_abs" ]] && [[ -f "$src_settings_abs" ]]; then
            copy_file "$src_settings_abs" "$dest_settings_abs" "$DRY_RUN"
        fi
    fi

    # 7. MCP  — per-tool override → shared .ai/src/mcp.json → base fallback
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

    # 8. HOOKS  — override → base fallback
    if [[ -n "$dest_hooks_abs" ]]; then
        local src_hooks_abs
        src_hooks_abs=$(resolve_payload_source "$tool_name" "hooks")
        if [[ -n "$src_hooks_abs" ]] && [[ -f "$src_hooks_abs" ]]; then
            copy_file "$src_hooks_abs" "$dest_hooks_abs" "$DRY_RUN"
        fi
    fi

    # 9. POST_SYNC
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
    for key in agents rules skills commands subagents settings mcp hooks; do
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

# Main entry point
main() {
    parse_args "$@"

    log_separator
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Starting AgentSync Config Sync (DRY RUN)..."
    else
        log_info "Starting AgentSync Config Sync..."
    fi
    log_separator
    echo ""

    local global_config="$SCRIPT_DIR/config.yaml"
    if [[ ! -f "$global_config" ]]; then
        log_error "Global config not found: $global_config"
        exit 1
    fi

    resolve_project_config_path

    if [[ -n "$PROJECT_CONFIG_PATH" ]]; then
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
    fi

    # 1. Global defaults
    SOURCE_AGENTS=$(parse_yaml_value "$global_config" "source.agents")
    SOURCE_RULES=$(parse_yaml_value "$global_config" "source.rules")
    SOURCE_SKILLS=$(parse_yaml_value "$global_config" "source.skills")
    SOURCE_TOOLS=$(parse_yaml_value "$global_config" "source.tools")

    # 2. Auto-detect local directories
    if [[ -f "$REPO_ROOT/.ai/src/AGENTS.md" ]]; then
        SOURCE_AGENTS=".ai/src/AGENTS.md"
    elif [[ -f "$REPO_ROOT/.ai/AGENTS.md" ]]; then
        SOURCE_AGENTS=".ai/AGENTS.md"
    fi

    if [[ -d "$REPO_ROOT/.ai/src/rules" ]]; then
        SOURCE_RULES=".ai/src/rules"
    elif [[ -d "$REPO_ROOT/.ai/rules" ]]; then
        SOURCE_RULES=".ai/rules"
    fi

    if [[ -d "$REPO_ROOT/.ai/src/skills" ]]; then
        SOURCE_SKILLS=".ai/src/skills"
    elif [[ -d "$REPO_ROOT/.ai/skills" ]]; then
        SOURCE_SKILLS=".ai/skills"
    fi

    if [[ -d "$REPO_ROOT/.ai/src/tools" ]]; then
        SOURCE_TOOLS=".ai/src/tools"
    elif [[ -d "$REPO_ROOT/.ai/tools" ]]; then
        SOURCE_TOOLS=".ai/tools"
    fi

    SOURCE_COMMANDS=""
    if [[ -d "$REPO_ROOT/.ai/src/commands" ]]; then
        SOURCE_COMMANDS=".ai/src/commands"
    elif [[ -d "$REPO_ROOT/.ai/commands" ]]; then
        SOURCE_COMMANDS=".ai/commands"
    fi

    SOURCE_SUBAGENTS=""
    if [[ -d "$REPO_ROOT/.ai/src/agents" ]]; then
        SOURCE_SUBAGENTS=".ai/src/agents"
    elif [[ -d "$REPO_ROOT/.ai/agents" ]]; then
        SOURCE_SUBAGENTS=".ai/agents"
    fi

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

    # `shared:` overlay — must run AFTER child SOURCE_* resolution so child
    # files take precedence, and BEFORE any tool sync reads them. The shadow
    # tree is torn down by the EXIT trap installed below.
    shared_setup_overlay
    trap 'shared_cleanup_overlay; profile_cleanup_overlay' EXIT

    # Snapshot the personal/base SOURCE_* (post-shared-overlay) so each profile
    # pass can restore them before layering its own overlay. The overlay
    # rewrite is conditional, so these can't be recomputed cheaply later.
    local BASE_SOURCE_AGENTS="$SOURCE_AGENTS"
    local BASE_SOURCE_RULES="$SOURCE_RULES"
    local BASE_SOURCE_SKILLS="$SOURCE_SKILLS"
    local BASE_SOURCE_COMMANDS="$SOURCE_COMMANDS"
    local BASE_SOURCE_SUBAGENTS="$SOURCE_SUBAGENTS"

    # Directory that holds the base content profiles fill from — the shared
    # overlay's shadow tree when `shared:` is active, else the raw .ai/src/.
    local PROFILE_BASE_SRC="$REPO_ROOT/.ai/src"
    if [[ -n "${SHARED_OVERLAY_DIR:-}" ]] && [[ -d "$SHARED_OVERLAY_DIR/src" ]]; then
        PROFILE_BASE_SRC="$SHARED_OVERLAY_DIR/src"
    fi

    # Which profiles to sync this run: the named one with --profile, else every
    # profile marked active. (Personal tools always sync regardless.)
    local -a profiles_to_sync=()
    local _p
    if [[ -n "$SELECTED_PROFILE" ]]; then
        profiles_to_sync=("$SELECTED_PROFILE")
    else
        while IFS= read -r _p; do
            [[ -z "$_p" ]] && continue
            profile_is_active "$_p" && profiles_to_sync+=("$_p")
        done < <(list_profiles)
    fi

    # Build catalog of tools to process: union of base + any user override files.
    local -a all_tools=()
    local t
    while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        all_tools+=("$t")
    done < <(list_all_tools)

    if [[ ${#all_tools[@]} -eq 0 ]]; then
        log_error "No tools found in base catalog ($(tool_resolver_base_dir))"
        log_error "AgentSync installation may be corrupted — try 'agentsync update'"
        exit 1
    fi

    # First pass: collect paths from enabled tools (for gitignore + cleanup safety).
    # Profile variant tools are handled in their own collection loop below.
    local -a generated_paths=()
    for t in "${all_tools[@]}"; do
        if ! is_tool_enabled "$t"; then
            continue
        fi
        is_profile_tool "$t" && continue
        local key raw abs rel
        for key in agents rules skills commands subagents settings mcp hooks; do
            raw=$(get_tool_value "$t" "targets.$key.dest")
            [[ -z "$raw" ]] && continue
            abs=$(resolve_dest_path "$raw" "targets.$key.dest for $t") || continue
            ENABLED_DEST_PATHS+=("$abs")
            rel=$(to_repo_relative_path "$abs")
            case "$key" in
                rules|skills|commands|subagents)
                    generated_paths+=("$rel/")
                    ;;
                *)
                    generated_paths+=("$rel")
                    ;;
            esac
        done
    done

    # Collect dests for EVERY profile tool (active or not) into the protected +
    # gitignored set, so .gitignore stays stable across --profile selections and
    # cleanup never sweeps a dormant profile's output.
    local _pt
    while IFS= read -r _pt; do
        [[ -z "$_pt" ]] && continue
        local key raw abs rel
        for key in agents rules skills commands subagents settings mcp hooks; do
            raw=$(get_tool_value "$_pt" "targets.$key.dest")
            [[ -z "$raw" ]] && continue
            abs=$(resolve_dest_path "$raw" "targets.$key.dest for $_pt") || continue
            ENABLED_DEST_PATHS+=("$abs")
            rel=$(to_repo_relative_path "$abs")
            case "$key" in
                rules|skills|commands|subagents)
                    generated_paths+=("$rel/")
                    ;;
                *)
                    generated_paths+=("$rel")
                    ;;
            esac
        done
    done < <(list_profile_tools)

    # Drift check: refuse to overwrite destination files edited since the last sync.
    # Skipped on dry-run (preview-only) and bypassed by --force.
    if [[ "$DRY_RUN" != "true" ]]; then
        manifest_load
        manifest_check_drift
        if [[ ${#SYNC_DRIFT_DETECTED[@]} -gt 0 ]]; then
            if [[ "$FORCE_SYNC" == "true" ]]; then
                log_warning "Overwriting ${#SYNC_DRIFT_DETECTED[@]} file(s) with manual edits (--force):"
                local rel
                for rel in "${SYNC_DRIFT_DETECTED[@]}"; do
                    echo "      $rel" >&2
                done
            else
                log_error "Manual edits detected in ${#SYNC_DRIFT_DETECTED[@]} destination file(s) since last sync:"
                local rel
                for rel in "${SYNC_DRIFT_DETECTED[@]}"; do
                    echo "      $rel" >&2
                done
                echo "" >&2
                echo "  These files would be silently overwritten. Choose one:" >&2
                echo "    • Move your edits into .ai/src/, then re-run sync" >&2
                echo "    • Re-run with --force to discard the edits and rewrite from source" >&2
                echo "" >&2
                exit 1
            fi
        fi
    fi

    # Second pass: sync enabled personal tools, cleanup disabled ones. Profile
    # variant tools are owned by the profile pass — never synced or cleaned here.
    for t in "${all_tools[@]}"; do
        is_profile_tool "$t" && continue
        ((TOTAL_COUNT++)) || true
        if is_tool_enabled "$t"; then
            sync_tool "$t"
        else
            cleanup_tool "$t"
        fi
        echo ""
    done

    # Profile passes: each selected/active profile syncs its variant tools with
    # a per-profile source overlay (profile extras win, base fills the rest).
    for _p in "${profiles_to_sync[@]+"${profiles_to_sync[@]}"}"; do
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

    if [[ "$DRY_RUN" != "true" ]] && [[ "$UPDATE_GITIGNORE" == "true" ]]; then
        log_separator
        log_info "Updating .gitignore..."
        local generated_paths_payload=""
        if [[ ${#generated_paths[@]} -gt 0 ]]; then
            generated_paths_payload=$(printf '%s\n' "${generated_paths[@]}")
        fi
        update_gitignore "$REPO_ROOT/.gitignore" "$generated_paths_payload"
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        manifest_write
    fi

    log_separator
    local summary="Synced $SYNCED_COUNT/$TOTAL_COUNT tools"
    if [[ $SKIPPED_COUNT -gt 0 ]]; then
        summary="$summary ($SKIPPED_COUNT skipped)"
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        summary="$summary (dry-run)"
    fi
    log_done "$summary"
    log_separator
}

main "$@"
