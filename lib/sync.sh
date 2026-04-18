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

# Global variables
DRY_RUN="false"
ONLY_TOOLS=""
SKIP_TOOLS=""
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
  --dry-run         Show what would be copied without making changes
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
            --dry-run)
                DRY_RUN="true"
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
    rule_include=$(get_tool_value "$tool_name" "targets.rules.include")
    rule_exclude=$(get_tool_value "$tool_name" "targets.rules.exclude")

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
    skills_include=$(get_tool_value "$tool_name" "targets.skills.include")
    skills_exclude=$(get_tool_value "$tool_name" "targets.skills.exclude")

    local inline_skills
    inline_skills=$(get_tool_value "$tool_name" "targets.skills.inline_into_agents")

    if [[ -n "$dest_skills_abs" ]]; then
        sync_dir "$src_skills_abs" "$dest_skills_abs" "$DRY_RUN" "$skills_include" "$skills_exclude"
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
                log_step "Appended skill index to $(basename "$skills_target_file")"
            fi
        elif [[ "$DRY_RUN" == "true" ]]; then
            log_step "Would append skill index (dry-run)"
        fi
    fi

    # 4. COMMANDS
    local dest_cmd_ext dest_cmd_format
    dest_cmd_ext=$(get_tool_value "$tool_name" "targets.commands.extension")
    dest_cmd_format=$(get_tool_value "$tool_name" "targets.commands.format")
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

    # 6. SETTINGS
    if [[ -n "$dest_settings_abs" ]]; then
        local src_settings
        src_settings=$(get_tool_value "$tool_name" "targets.settings.source")
        if [[ -n "$src_settings" ]]; then
            local src_settings_abs
            src_settings_abs=$(resolve_source_path "$src_settings" "targets.settings.source for $display")
            if [[ -f "$src_settings_abs" ]]; then
                copy_file "$src_settings_abs" "$dest_settings_abs" "$DRY_RUN"
            fi
        fi
    fi

    # 7. MCP
    if [[ -n "$dest_mcp_abs" ]]; then
        local src_mcp
        src_mcp=$(get_tool_value "$tool_name" "targets.mcp.source")
        if [[ -n "$src_mcp" ]]; then
            local src_mcp_abs
            src_mcp_abs=$(resolve_source_path "$src_mcp" "targets.mcp.source for $display")
            if [[ -f "$src_mcp_abs" ]]; then
                copy_file "$src_mcp_abs" "$dest_mcp_abs" "$DRY_RUN"
            fi
        fi
    fi

    # 8. HOOKS
    if [[ -n "$dest_hooks_abs" ]]; then
        local src_hooks
        src_hooks=$(get_tool_value "$tool_name" "targets.hooks.source")
        if [[ -n "$src_hooks" ]]; then
            local src_hooks_abs
            src_hooks_abs=$(resolve_source_path "$src_hooks" "targets.hooks.source for $display")
            if [[ -f "$src_hooks_abs" ]]; then
                copy_file "$src_hooks_abs" "$dest_hooks_abs" "$DRY_RUN"
            fi
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
    local -a generated_paths=()
    for t in "${all_tools[@]}"; do
        if ! is_tool_enabled "$t"; then
            continue
        fi
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

    # Second pass: sync enabled tools, cleanup disabled ones.
    for t in "${all_tools[@]}"; do
        ((TOTAL_COUNT++)) || true
        if is_tool_enabled "$t"; then
            sync_tool "$t"
        else
            cleanup_tool "$t"
        fi
        echo ""
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
